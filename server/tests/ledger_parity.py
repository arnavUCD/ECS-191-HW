"""Runs a shared-ledger parity fixture (``HW/Shared/parity-fixtures/ledger``) through the real API.

Every member with an account signs in with a development principal, creates a profile with the
fixture's member ID, and joins through a real invitation; members without accounts are pending
seats. Every step goes through the HTTP API (authorization, idempotency, revisions, the command
engine), and after each step the runner records the server-derived balances. The Swift runner
(``LedgerParityTests``) replays the same steps through ``LedgerEngine`` and must match exactly.
"""

from __future__ import annotations

import json
import uuid
from pathlib import Path
from typing import Any

from squareup import create_app
from squareup.config import Config
from squareup.ledger.rules import recompute_split, split_equal
from squareup.storage.blobs import MemoryBlobStore
from squareup.storage.memory import MemoryStore

from .parity import fixture_uuid

LEDGER_FIXTURES = Path(__file__).resolve().parents[2] / "Shared" / "parity-fixtures" / "ledger"


def ledger_fixture_names() -> list[str]:
    return sorted(path.stem for path in LEDGER_FIXTURES.glob("*.json"))


class LedgerRunner:
    def __init__(self, name: str) -> None:
        self.name = name
        self.fixture: dict[str, Any] = json.loads((LEDGER_FIXTURES / f"{name}.json").read_text())
        limits = dict.fromkeys(
            (
                "account",
                "group-read",
                "group-command",
                "group-publish",
                "group-invite",
                "group-invite-preview",
                "group-invite-accept",
                "publish",
                "command",
                "join",
            ),
            (100_000, 60),
        )
        config = Config(environment="test", allow_dev_auth=True, rate_limits=limits)
        self.app = create_app(config, store=MemoryStore(), blobs=MemoryBlobStore())
        self.client = self.app.test_client()
        self.group_id = self.uuid("group")
        self.expenses: dict[str, dict[str, Any]] = {}

    def uuid(self, key: str) -> str:
        return fixture_uuid(self.name, key)

    @staticmethod
    def headers(member: str) -> dict[str, str]:
        return {"Authorization": f"Dev {member}"}

    def members(self) -> list[str]:
        return list(self.fixture["members"])

    def accounts(self) -> list[str]:
        return list(self.fixture.get("accounts", self.fixture["members"]))

    def setup(self) -> None:
        owner, *others = self.members()
        for member in self.accounts():
            response = self.client.put(
                "/v1/account/profile", json={"displayName": member.title(), "memberId": self.uuid(member)}, headers=self.headers(member)
            )
            assert response.status_code == 200, response.json
        created = self.client.post(
            "/v1/groups",
            json={
                "groupId": self.group_id,
                "name": self.name,
                "currency": self.fixture["currency"],
                "simplifiesDebts": self.fixture.get("simplify", True),
            },
            headers=self.headers(owner),
        )
        assert created.status_code == 201, created.json
        for member in others:
            if member in self.accounts():
                invitation = self.client.post(f"/v1/groups/{self.group_id}/invitations", json={}, headers=self.headers(owner)).json[
                    "invitation"
                ]
                joined = self.client.post(f"/v1/group-invitations/{invitation['code']}/accept", json={}, headers=self.headers(member))
                assert joined.status_code == 201, joined.json
            else:
                seat = self.command(owner, "addSeat", {"memberId": self.uuid(member), "displayName": member.title()})
                assert seat.status_code == 200, seat.json

    def revision(self, member: str) -> int:
        return int(self.client.get(f"/v1/groups/{self.group_id}", headers=self.headers(member)).json["snapshot"]["revision"])

    def command(self, actor: str, kind: str, payload: dict[str, Any], key: str | None = None) -> Any:
        body = {
            "commandId": str(uuid.uuid4()),
            "idempotencyKey": key or uuid.uuid4().hex,
            "expectedRevision": self.revision(actor),
            "type": kind,
            "payload": payload,
        }
        return self.client.post(f"/v1/groups/{self.group_id}/commands", json=body, headers=self.headers(actor))

    def expense_payload(self, step: dict[str, Any]) -> dict[str, Any]:
        raw = step["expense"]
        total = raw["total"]
        payments = [{"memberId": self.uuid(member), "amount": amount} for member, amount in raw["payments"]]
        split = raw["split"]
        method = split["method"]
        wire_split: dict[str, Any] | None = None
        if method == "equal":
            participants = [self.uuid(member) for member in split["participants"]]
            allocations = split_equal(total, participants)
            wire_split = {"method": "equal", "participants": participants}
        elif method == "shares":
            wire_split = {"method": "shares", "weights": [{"memberId": self.uuid(m), "weight": w} for m, w in split["weights"]]}
            allocations = recompute_split(total, wire_split)
        elif method == "percentage":
            from decimal import Decimal

            wire_split = {
                "method": "percentage",
                "percentages": [{"memberId": self.uuid(m), "percent": p} for m, p in split["percentages"]],
            }
            allocations = recompute_split(
                total,
                {
                    "method": "percentage",
                    "percentages": [{"memberId": self.uuid(m), "percent": Decimal(p)} for m, p in split["percentages"]],
                },
            )
        else:  # exact, itemized: the amounts are given
            allocations = [(self.uuid(member), amount) for member, amount in split["amounts"]]
        expense = {
            "id": self.uuid(step["key"]),
            "title": raw.get("title", step["key"]),
            "date": "2026-09-24T19:30:00Z",
            "total": total,
            "category": "food",
            "splitMethod": method,
            "payments": payments,
            "allocations": [{"memberId": member, "amount": amount} for member, amount in allocations],
        }
        payload: dict[str, Any] = {"expense": expense}
        if wire_split is not None:
            payload["split"] = wire_split
        if method == "itemized":
            payload["receipt"] = {
                "merchant": expense["title"],
                "date": expense["date"],
                "total": total,
                "items": [],
                "charges": [],
                "participants": [
                    {"memberId": member, "items": amount, "tax": 0, "tip": 0, "fees": 0, "discounts": 0, "adjustments": 0, "total": amount}
                    for member, amount in allocations
                    if amount != 0
                ],
                "rounding": [],
            }
        return payload

    def run_step(self, step: dict[str, Any]) -> Any:
        actor = step["actor"]
        command = step["command"]
        if command in ("addExpense", "updateExpense"):
            payload = self.expense_payload(step)
            if command == "updateExpense":
                payload["expenseId"] = self.uuid(step["key"])
            return self.command(actor, command, payload)
        if command in ("deleteExpense", "restoreExpense"):
            return self.command(actor, command, {"expenseId": self.uuid(step["key"])})
        if command == "setSimplification":
            return self.command(actor, command, {"enabled": step["enabled"]})
        if command == "startPayment":
            payload = {
                "attemptId": self.uuid(step["attempt"]),
                "recipientId": self.uuid(step["recipient"]),
                "amount": step["amount"],
                "provider": step.get("provider", "cash"),
            }
            return self.command(actor, command, payload)
        if command == "advancePayment":
            key = step.get("idempotencyKey")
            payload = {"attemptId": self.uuid(step["attempt"]), "action": step["action"]}
            response = self.command(actor, command, payload, key=key)
            if step.get("repeat"):
                response = self.command(actor, command, payload)
            return response
        raise AssertionError(f"Unknown fixture command {command}")

    def balances(self) -> dict[str, Any]:
        """Server-derived balances, with member IDs replaced by fixture keys."""
        owner = self.members()[0]
        snapshot = self.client.get(f"/v1/groups/{self.group_id}", headers=self.headers(owner)).json["snapshot"]
        key_for = {self.uuid(member): member for member in self.members()}
        balances = snapshot["balances"]
        return {
            "confirmedNets": {key_for[member]: units for member, units in balances["confirmedNets"].items()},
            "availableNets": {key_for[member]: units for member, units in balances["availableNets"].items()},
            "payments": [[key_for[p["payerId"]], key_for[p["recipientId"]], p["amount"]] for p in balances["payments"]],
            "directPaymentCount": balances["directPaymentCount"],
            "simplifiedPaymentCount": balances["simplifiedPaymentCount"],
            "settlements": sorted([key_for[s["fromId"]], key_for[s["toId"]], s["amount"]] for s in snapshot["settlements"]),
            "expenses": sorted(
                [
                    next(k for k in self.fixture_keys() if self.uuid(k) == e["id"]),
                    e["revision"],
                    e["deletedAt"] is not None,
                    sorted([key_for[a["memberId"]], a["amount"]] for a in e["allocations"]),
                ]
                for e in snapshot["expenses"]
            ),
        }

    def fixture_keys(self) -> list[str]:
        return [step["key"] for step in self.fixture["steps"] if "key" in step]

    def run(self) -> list[dict[str, Any]]:
        self.setup()
        results = []
        for step in self.fixture["steps"]:
            response = self.run_step(step)
            ok = response.status_code == 200
            outcome = ("applied" if response.json["applied"] else "noop") if ok else response.json["error"]["code"]
            results.append({"outcome": outcome, "balances": self.balances()})
        return results
