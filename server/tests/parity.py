"""Runs a shared parity fixture (``HW/Shared/parity-fixtures``) through the real server services.

Hosts and participants authenticate with development principals and join through a real
invitation (claiming their seats), so the run exercises publishing, joining, authorization,
revision checks, idempotency, and the engine — not just the pure domain functions.
"""

from __future__ import annotations

import hashlib
import json
import uuid
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from squareup.auth.identity import Principal
from squareup.config import Config
from squareup.domain.errors import DomainError
from squareup.services.context import ServiceContext
from squareup.services.invitations import InvitationService
from squareup.services.rooms import RoomService
from squareup.storage.blobs import MemoryBlobStore
from squareup.storage.memory import MemoryStore

FIXTURES = Path(__file__).resolve().parents[2] / "Shared" / "parity-fixtures"


def fixture_uuid(fixture: str, key: str) -> str:
    """Same derivation as the Swift runner (see the fixtures README)."""
    h = hashlib.sha256(f"{fixture}:{key}".encode()).hexdigest()
    return str(uuid.UUID(f"{h[0:8]}-{h[8:12]}-4{h[13:16]}-8{h[17:20]}-{h[20:32]}"))


def load(name: str) -> dict[str, Any]:
    data: dict[str, Any] = json.loads((FIXTURES / f"{name}.json").read_text())
    return data


def fixture_names() -> list[str]:
    return sorted(path.stem for path in FIXTURES.glob("*.json"))


class Runner:
    def __init__(self, name: str) -> None:
        self.name = name
        self.fixture = load(name)
        self.ids: dict[str, str] = {}
        self.keys: dict[str, str] = {}
        ctx = ServiceContext(
            Config(environment="test", allow_dev_auth=True),
            MemoryStore(),
            MemoryBlobStore(),
            None,
            clock=lambda: datetime(2026, 9, 25, 12, tzinfo=UTC),
        )
        self.rooms = RoomService(ctx)
        self.invitations = InvitationService(ctx, self.rooms)

    def uuid(self, key: str) -> str:
        if key not in self.ids:
            value = fixture_uuid(self.name, key)
            self.ids[key] = value
            self.keys[value] = key
        return self.ids[key]

    def principal(self, key: str) -> Principal:
        return Principal("user", f"dev-{key}", recoverable=True, email_verified=True)

    def _allocation(self, raw: dict[str, Any]) -> dict[str, Any]:
        kind = raw["kind"]
        wire: dict[str, Any] = {"kind": kind}
        if kind == "equal":
            wire["members"] = None if raw.get("members") is None else [self.uuid(k) for k in raw["members"]]
        if kind == "shares":
            wire["weights"] = [{"participantId": self.uuid(k), "weight": w} for k, w in raw["weights"]]
        if kind == "exact":
            wire["amounts"] = [{"participantId": self.uuid(k), "amount": a} for k, a in raw["amounts"]]
        return wire

    def publish(self) -> str:
        fx = self.fixture
        receipt = fx["receipt"]
        wire_receipt = {
            "merchant": receipt["merchant"],
            "date": receipt["date"],
            "currency": receipt["currency"],
            "total": receipt["total"],
            "items": [
                {
                    "id": self.uuid(i["key"]),
                    "name": i["name"],
                    "lineTotal": i["lineTotal"],
                    "quantity": i.get("quantity"),
                    "unitPrice": i.get("unitPrice"),
                    "isRefund": i.get("isRefund", False),
                }
                for i in receipt["items"]
            ],
            "charges": [
                {
                    "id": self.uuid(c["key"]),
                    "kind": c["kind"],
                    "label": c["label"],
                    "amount": c["amount"],
                    "allocation": self._allocation(c["allocation"]),
                }
                for c in receipt["charges"]
            ],
        }
        participants = fx["participants"]
        host = participants[0]
        room_id = self.uuid("room")
        self.rooms.publish(
            self.principal(host),
            {
                "roomId": room_id,
                "hostParticipantId": self.uuid(host),
                "payerId": self.uuid(fx["payer"]),
                "participants": [{"id": self.uuid(p), "displayName": p.title()} for p in participants],
                "receipt": wire_receipt,
            },
        )
        invitation = self.invitations.create(self.principal(host), room_id, {})
        for key in participants[1:]:
            self.invitations.join(invitation["token"], self.principal(key), {"displayName": key.title(), "seatId": self.uuid(key)})
        return room_id

    def payload(self, command: str, raw: dict[str, Any], step: dict[str, Any]) -> dict[str, Any]:
        if command in ("claim",):
            return {"itemId": self.uuid(raw["item"]), "request": raw["request"]}
        if command == "unclaim":
            return {"itemId": self.uuid(raw["item"])}
        if command == "claimUnits":
            return {"itemId": self.uuid(raw["item"]), "units": raw["units"]}
        if command == "setItemSplit":
            split = raw["split"]
            wire: dict[str, Any]
            if split["kind"] == "equal":
                wire = {"kind": "equal", "members": [self.uuid(k) for k in split["members"]]}
            elif split["kind"] == "shares":
                wire = {"kind": "shares", "weights": [{"participantId": self.uuid(k), "weight": w} for k, w in split["weights"]]}
            elif split["kind"] == "units":
                wire = {"kind": "units", "units": [{"participantId": self.uuid(k), "units": n} for k, n in split["units"]]}
            else:
                wire = {"kind": "exact", "amounts": [{"participantId": self.uuid(k), "amount": a} for k, a in split["amounts"]]}
            return {"itemId": self.uuid(raw["item"]), "split": wire}
        if command == "dispute":
            payload: dict[str, Any] = {"target": {"kind": raw["target"]["kind"], "id": self.uuid(raw["target"]["key"])}}
            if "note" in raw:
                payload["note"] = raw["note"]
            if "disputeKey" in step:
                payload["disputeId"] = self.uuid(step["disputeKey"])
            return payload
        if command == "resolveDispute":
            payload = {"disputeId": self.uuid(raw["dispute"]), "status": raw["status"]}
            if "note" in raw:
                payload["note"] = raw["note"]
            return payload
        if command == "setChargeAllocation":
            return {"chargeId": self.uuid(raw["charge"]), "allocation": self._allocation(raw["allocation"])}
        if command == "removeParticipant":
            return {"participantId": self.uuid(raw["participant"])}
        return dict(raw)

    def run(self) -> tuple[list[dict[str, Any]], dict[str, Any]]:
        room_id = self.publish()
        outcomes: list[dict[str, Any]] = []
        previous_revision: int | None = None
        for index, step in enumerate(self.fixture["steps"]):
            current = self.rooms.load(room_id).revision
            expected = previous_revision if step.get("expectedRevision") == "stale" else current
            envelope = {
                "commandId": str(uuid.uuid4()),
                "idempotencyKey": f"step-{index:06d}",
                "expectedRevision": expected,
                "type": step["command"],
                "payload": self.payload(step["command"], step["payload"], step),
            }
            try:
                result = self.rooms.command(
                    self.principal(step["actor"]), room_id, envelope, "finalize" if step["command"] == "finalize" else None
                )
                outcomes.append({"applied": result["applied"]})
                if result["applied"]:
                    previous_revision = current
            except DomainError as error:
                outcomes.append({"error": error.code})
        return outcomes, self.normalize(self.rooms.load(room_id))

    def normalize(self, room: Any) -> dict[str, Any]:
        from squareup.domain.allocation import allocate
        from squareup.domain.readiness import readiness_issues

        allocation = allocate(room)
        key = self.keys.get

        def shares(entries: list[tuple[str, int]]) -> dict[str, int]:
            return {str(key(pid, pid)): amount for pid, amount in entries}

        readiness = []
        for issue in readiness_issues(room, allocation):
            kind = issue["kind"]
            if kind == "receipt":
                readiness.append(f"receipt:{issue['issue']['kind']}")
                continue
            ref = issue.get("itemId") or issue.get("chargeId") or issue.get("disputeId") or issue.get("participantId")
            readiness.append(kind if ref is None else f"{kind}:{key(ref, ref)}")
        return {
            "state": room.state,
            "remaining": allocation.remaining,
            "participants": {
                str(key(p.participant_id, p.participant_id)): {
                    "items": p.items,
                    "tax": p.tax,
                    "tip": p.tip,
                    "fees": p.fees,
                    "discounts": p.discounts,
                    "adjustments": p.adjustments,
                    "total": p.total,
                }
                for p in allocation.participants
            },
            "items": {
                str(key(i.item_id, i.item_id)): {
                    "status": i.status,
                    "shares": shares(i.shares),
                    "rounding": sorted(str(key(pid, pid)) for pid, _ in i.rounding),
                }
                for i in allocation.items
            },
            "charges": {
                str(key(c.charge_id, c.charge_id)): {
                    "status": c.status,
                    "shares": shares(c.shares),
                    "rounding": sorted(str(key(pid, pid)) for pid, _ in c.rounding),
                }
                for c in allocation.charges
            },
            "readiness": readiness,
            "finalized": room.finalization is not None,
        }
