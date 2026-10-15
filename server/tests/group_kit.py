"""Helpers for shared-group tests (milestone 7)."""

from __future__ import annotations

import uuid
from typing import Any

from .conftest import Env


def account(who: str) -> dict[str, str]:
    """An email/password Firebase account (recoverable)."""
    return {"Authorization": f"Bearer valid-{who}"}


def anonymous(who: str) -> dict[str, str]:
    return {"Authorization": f"Bearer anon-{who}"}


def profile(env: Env, who: str, name: str | None = None) -> dict[str, Any]:
    response = env.client.put("/v1/account/profile", json={"displayName": name or who.title(), "locale": "en_US"}, headers=account(who))
    assert response.status_code == 200, response.json
    result: dict[str, Any] = response.json["profile"]
    return result


def create_group(env: Env, who: str = "riley", name: str = "Coastal Weekend", **extra: Any) -> dict[str, Any]:
    profile(env, who)
    group_id = extra.pop("groupId", None) or env.id("group")
    body = {"groupId": group_id, "name": name, "symbol": "beach.umbrella.fill", "currency": "USD", **extra}
    response = env.client.post("/v1/groups", json=body, headers=account(who))
    assert response.status_code in (200, 201), response.json
    snapshot: dict[str, Any] = response.json["snapshot"]
    return snapshot


def snapshot(env: Env, who: str, group_id: str | None = None) -> dict[str, Any]:
    response = env.client.get(f"/v1/groups/{group_id or env.id('group')}", headers=account(who))
    assert response.status_code == 200, response.json
    result: dict[str, Any] = response.json["snapshot"]
    return result


def invite(env: Env, who: str = "riley", group_id: str | None = None, **body: Any) -> dict[str, Any]:
    response = env.client.post(f"/v1/groups/{group_id or env.id('group')}/invitations", json=body, headers=account(who))
    assert response.status_code == 201, response.json
    invitation: dict[str, Any] = response.json["invitation"]
    return invitation


def accept(env: Env, code: str, who: str, name: str | None = None) -> Any:
    profile(env, who, name)
    return env.client.post(f"/v1/group-invitations/{code}/accept", json={"displayName": name or who.title()}, headers=account(who))


def join(env: Env, who: str, owner: str = "riley", group_id: str | None = None, **invite_body: Any) -> dict[str, Any]:
    """Owner invites; ``who`` accepts. Returns the joiner's snapshot."""
    invitation = invite(env, owner, group_id, **invite_body)
    response = accept(env, invitation["code"], who)
    assert response.status_code in (200, 201), response.json
    result: dict[str, Any] = response.json["snapshot"]
    return result


def member_id(snap: dict[str, Any], name: str) -> str:
    return str(next(member["id"] for member in snap["members"] if member["displayName"] == name))


def command(
    env: Env,
    who: str,
    kind: str,
    payload: dict[str, Any],
    *,
    group_id: str | None = None,
    revision: int | None = None,
    key: str | None = None,
    known_cursor: int | None = None,
) -> Any:
    group_id = group_id or env.id("group")
    if revision is None:
        reply = env.client.get(f"/v1/groups/{group_id}", headers=account(who))
        revision = reply.json["snapshot"]["revision"] if reply.status_code == 200 else 0
    body: dict[str, Any] = {
        "commandId": str(uuid.uuid4()),
        "idempotencyKey": key or uuid.uuid4().hex,
        "expectedRevision": revision,
        "type": kind,
        "payload": payload,
    }
    if known_cursor is not None:
        body["knownCursor"] = known_cursor
    return env.client.post(f"/v1/groups/{group_id}/commands", json=body, headers=account(who))


def expense(
    payer: str | list[tuple[str, int]],
    total: int,
    shares: list[tuple[str, int]],
    *,
    method: str = "exact",
    title: str = "Groceries",
    expense_id: str | None = None,
) -> dict[str, Any]:
    payments = [(payer, total)] if isinstance(payer, str) else payer
    return {
        "id": expense_id or str(uuid.uuid4()),
        "title": title,
        "date": "2026-09-24T19:30:00Z",
        "total": total,
        "currency": "USD",
        "category": "groceries",
        "splitMethod": method,
        "payments": [{"memberId": member, "amount": amount} for member, amount in payments],
        "allocations": [{"memberId": member, "amount": amount} for member, amount in shares],
    }


def add_expense(env: Env, who: str, body: dict[str, Any], split: dict[str, Any] | None = None, **options: Any) -> Any:
    payload: dict[str, Any] = {"expense": body}
    if split is not None:
        payload["split"] = split
    return command(env, who, "addExpense", payload, **options)


def two_person_group(env: Env) -> tuple[str, str]:
    """Riley owns a group Maya joined. Returns (riley's member ID, maya's member ID)."""
    create_group(env, "riley")
    maya_snapshot = join(env, "maya")
    return member_id(maya_snapshot, "Riley"), maya_snapshot["viewer"]["memberId"]
