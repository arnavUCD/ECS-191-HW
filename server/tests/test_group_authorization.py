"""The shared-group permission matrix (milestone 7 §3.2, §13.1) and input limits (§6.6, §13.3).

Owner, member, non-member, invitation holder (before accepting), and room guest, against every
group read and write. A non-member learns nothing — not even that the group exists.
"""

from __future__ import annotations

import uuid
from typing import Any

import pytest

from .conftest import Env, receipt
from .group_kit import account, add_expense, create_group, expense, invite, join, profile, snapshot


def _setup(env: Env) -> dict[str, Any]:
    create_group(env, "owner")
    member_snapshot = join(env, "member", owner="owner")
    owner_id = next(m["id"] for m in member_snapshot["members"] if m["displayName"] == "Owner")
    member_id = member_snapshot["viewer"]["memberId"]
    body = expense(owner_id, 1000, [(owner_id, 500), (member_id, 500)], method="equal")
    assert add_expense(env, "owner", body).status_code == 200
    profile(env, "outsider")
    holder_invitation = invite(env, "owner")
    profile(env, "holder")
    # A room guest: a room-scoped credential from a Live Receipt Room the owner hosts.
    room = {
        "roomId": env.id("room"),
        "hostParticipantId": owner_id,
        "payerId": owner_id,
        "participants": [{"id": owner_id, "displayName": "Owner"}],
        "receipt": receipt(env),
    }
    assert env.client.post("/v1/receipt-rooms", json=room, headers=account("owner")).status_code == 201
    token = env.client.post(f"/v1/receipt-rooms/{env.id('room')}/invitations", json={}, headers=account("owner")).json["invitation"][
        "token"
    ]
    guest = env.client.post(f"/v1/receipt-room-invitations/{token}/join", json={"displayName": "Sam"}).json
    return {
        "owner_id": owner_id,
        "member_id": member_id,
        "expense_id": body["id"],
        "holder_code": holder_invitation["code"],
        "guest": {"Authorization": f"Guest {guest['credential']}"},
    }


def headers_for(who: str, ctx: dict[str, Any]) -> dict[str, str]:
    return ctx["guest"] if who == "guest" else account(who)


@pytest.mark.parametrize(
    ("who", "can_read"),
    [("owner", True), ("member", True), ("outsider", False), ("holder", False), ("guest", False)],
)
def test_reading_a_group(env: Env, who: str, can_read: bool) -> None:
    ctx = _setup(env)
    headers = headers_for(who, ctx)
    group = env.id("group")
    reads = [
        env.client.get(f"/v1/groups/{group}", headers=headers),
        env.client.get(f"/v1/groups/{group}/changes?after=0", headers=headers),
        env.client.get(f"/v1/groups/{group}/expenses/{ctx['expense_id']}/revisions", headers=headers),
    ]
    for response in reads:
        if can_read:
            assert response.status_code == 200, response.json
        else:
            assert response.status_code in (401, 403, 404)
            assert "Owner" not in response.get_data(as_text=True), "nothing about the group leaks"


@pytest.mark.parametrize(
    ("who", "kind", "allowed"),
    [
        ("owner", "updateGroup", True),
        ("member", "updateGroup", False),
        ("owner", "setSimplification", True),
        ("member", "setSimplification", False),
        ("member", "addExpense", True),
        ("outsider", "addExpense", False),
        ("holder", "addExpense", False),
        ("guest", "addExpense", False),
        ("member", "deleteOwnersExpense", False),
        ("owner", "deleteOwnersExpense", True),
        ("member", "addSeat", False),
        ("owner", "addSeat", True),
        ("member", "transferOwnership", False),
        ("member", "archiveGroup", False),
    ],
)
def test_writing_to_a_group(env: Env, who: str, kind: str, allowed: bool) -> None:
    ctx = _setup(env)
    headers = headers_for(who, ctx)
    group = env.id("group")
    revision = snapshot(env, "owner")["revision"]
    payloads: dict[str, tuple[str, dict[str, Any]]] = {
        "updateGroup": ("updateGroup", {"name": "Renamed", "symbol": "car.fill", "currency": "USD"}),
        "setSimplification": ("setSimplification", {"enabled": False}),
        "addExpense": (
            "addExpense",
            {"expense": expense(ctx["member_id"], 200, [(ctx["member_id"], 100), (ctx["owner_id"], 100)], method="equal")},
        ),
        "deleteOwnersExpense": ("deleteExpense", {"expenseId": ctx["expense_id"]}),
        "addSeat": ("addSeat", {"memberId": str(uuid.uuid4()), "displayName": "Dev"}),
        "transferOwnership": ("transferOwnership", {"memberId": ctx["member_id"]}),
        "archiveGroup": ("archiveGroup", {}),
    }
    command_type, payload = payloads[kind]
    body = {
        "commandId": str(uuid.uuid4()),
        "idempotencyKey": uuid.uuid4().hex,
        "expectedRevision": revision,
        "type": command_type,
        "payload": payload,
    }
    response = env.client.post(f"/v1/groups/{group}/commands", json=body, headers=headers)
    if allowed:
        assert response.status_code == 200, response.json
        assert response.json["applied"] is True
    else:
        assert response.status_code in (401, 403, 404), response.json
    assert snapshot(env, "owner")["revision"] == revision + (1 if allowed else 0), "a refused command changes nothing"


def test_only_the_owner_manages_invitations_and_guests_never_open_invitations(env: Env) -> None:
    ctx = _setup(env)
    group = env.id("group")
    assert env.client.post(f"/v1/groups/{group}/invitations", json={}, headers=account("member")).json["error"]["code"] == "owner_only"
    assert env.client.get(f"/v1/groups/{group}/invitations", headers=account("member")).json["error"]["code"] == "owner_only"
    guest_accept = env.client.post(f"/v1/group-invitations/{ctx['holder_code']}/accept", json={}, headers=ctx["guest"])
    assert guest_accept.status_code in (401, 403)


def test_malformed_and_oversized_requests_are_refused_without_changes(env: Env) -> None:
    create_group(env, "owner")
    group = env.id("group")
    revision = snapshot(env, "owner")["revision"]
    bad_bodies: list[Any] = [
        [],
        {"commandId": "not-a-uuid", "idempotencyKey": "k" * 10, "expectedRevision": revision, "type": "addExpense", "payload": {}},
        {"commandId": str(uuid.uuid4()), "idempotencyKey": "short", "expectedRevision": revision, "type": "addExpense", "payload": {}},
        {
            "commandId": str(uuid.uuid4()),
            "idempotencyKey": uuid.uuid4().hex,
            "expectedRevision": revision,
            "type": "launchRockets",
            "payload": {},
        },
        {
            "commandId": str(uuid.uuid4()),
            "idempotencyKey": uuid.uuid4().hex,
            "expectedRevision": revision,
            "type": "addExpense",
            "payload": {
                "expense": {
                    "id": str(uuid.uuid4()),
                    "title": "x" * 500,
                    "date": "2026-10-01T00:00:00Z",
                    "total": 1,
                    "category": "food",
                    "splitMethod": "exact",
                    "payments": [],
                    "allocations": [],
                }
            },
        },
        {
            "commandId": str(uuid.uuid4()),
            "idempotencyKey": uuid.uuid4().hex,
            "expectedRevision": revision,
            "type": "addExpense",
            "payload": {
                "expense": {
                    "id": str(uuid.uuid4()),
                    "title": "Big",
                    "date": "2026-10-01T00:00:00Z",
                    "total": 10**15,
                    "category": "food",
                    "splitMethod": "exact",
                    "payments": [],
                    "allocations": [],
                }
            },
        },
    ]
    for body in bad_bodies:
        response = env.client.post(f"/v1/groups/{group}/commands", json=body, headers=account("owner"))
        assert response.status_code in (400, 422), (body, response.json)
    too_big = env.client.post(
        f"/v1/groups/{group}/commands", data="x" * (300 * 1024), headers={**account("owner"), "Content-Type": "application/json"}
    )
    assert too_big.status_code == 413
    huge_publication = env.client.post(
        "/v1/groups/publications", data="x" * (1100 * 1024), headers={**account("owner"), "Content-Type": "application/json"}
    )
    assert huge_publication.status_code == 413
    assert snapshot(env, "owner")["revision"] == revision


def test_destination_reveals_are_rate_limited(env: Env) -> None:
    create_group(env, "owner")
    member = join(env, "member", owner="owner")
    owner_id = next(m["id"] for m in member["members"] if m["displayName"] == "Owner")
    statuses = [
        env.client.get(f"/v1/groups/{env.id('group')}/members/{owner_id}/destinations", headers=account("member")).status_code
        for _ in range(31)
    ]
    assert statuses[-1] == 429
