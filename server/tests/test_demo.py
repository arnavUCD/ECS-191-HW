"""Demo workspaces ("Enter Demo"): one isolated, server-backed workspace of fictional data per device."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime
from typing import Any

from squareup.auth.identity import token_hash
from squareup.config import Config
from squareup.intelligence.provider import FakeProvider
from squareup.storage.base import ACCOUNT, ACCOUNT_DIRECTORY, DEMO_SESSION, GROUP_MEMBERSHIP, GROUP_RECEIPT, RATE, ROOM, SHARED_GROUP

from .conftest import Env, build, guest_headers
from .group_kit import account, create_group, expense, invite
from .intelligence_kit import ACCOUNT as AI_ACCOUNT
from .intelligence_kit import PARSE, output, request_body, text


def _start(env: Env) -> dict[str, Any]:
    response = env.client.post("/v1/demo/sessions")
    assert response.status_code == 201, response.json
    session: dict[str, Any] = response.json["session"]
    return session


def _headers(session: dict[str, Any]) -> dict[str, str]:
    return {"Authorization": f"Demo {session['token']}"}


def _groups(env: Env, session: dict[str, Any]) -> dict[str, dict[str, Any]]:
    response = env.client.get("/v1/groups", headers=_headers(session))
    assert response.status_code == 200, response.json
    return {summary["group"]["name"]: summary for summary in response.json["groups"]}


def _snapshot(env: Env, session: dict[str, Any], group_id: str) -> dict[str, Any]:
    response = env.client.get(f"/v1/groups/{group_id}", headers=_headers(session))
    assert response.status_code == 200, response.json
    snapshot: dict[str, Any] = response.json["snapshot"]
    return snapshot


def _send(env: Env, session: dict[str, Any], group_id: str, kind: str, payload: dict[str, Any]) -> Any:
    snapshot = _snapshot(env, session, group_id)
    body = {
        "commandId": str(uuid.uuid4()),
        "idempotencyKey": uuid.uuid4().hex,
        "expectedRevision": snapshot["revision"],
        "type": kind,
        "payload": payload,
    }
    return env.client.post(f"/v1/groups/{group_id}/commands", json=body, headers=_headers(session))


def test_entering_the_demo_seeds_a_complete_workspace(env: Env) -> None:
    session = _start(env)
    assert session["userId"].startswith("demo-") and len(session["token"]) >= 40
    me = env.client.get("/v1/account", headers=_headers(session)).json["account"]
    assert me["demo"] is True and me["profile"]["displayName"] == "Avery Lee"
    # The store keeps only a digest of the credential.
    assert env.store.get(DEMO_SESSION, session["token"]) is None

    groups = _groups(env, session)
    assert list(groups) == ["Apartment 4B", "Friday Dinner Crew", "Tahoe Ski Weekend"]
    assert all("fictional" in summary["group"]["details"] for summary in groups.values())
    # Kept simple: nothing is waiting for the demo person.
    assert all(g["awaitingYourConfirmation"] == 0 and g["openReceipts"] == 0 for g in groups.values())

    apartment = _snapshot(env, session, groups["Apartment 4B"]["group"]["id"])
    me_id = apartment["viewer"]["memberId"]
    assert apartment["viewer"]["isOwner"] is True
    assert [m["displayName"] for m in apartment["members"]] == ["Avery Lee", "Maya Chen", "Jordan Brooks", "Priya Natarajan"]
    assert all(m["status"] == "active" for m in apartment["members"])
    assert len([e for e in apartment["expenses"] if not e["deletedAt"]]) == 5
    confirmed = [s for s in apartment["settlements"] if s["toId"] == me_id and s["confirmedAt"]]
    assert len(confirmed) == 1 and confirmed[0]["provider"] == "venmo"
    assert not [a for a in apartment["attempts"] if a["state"] in ("reportedSent", "disputed")]
    # Balances come from the server's own rules and always net to zero.
    assert sum(apartment["balances"]["confirmedNets"].values()) == 0

    # Weeks of history, in order, all in the past.
    events = apartment["events"]
    assert len(events) > 10 and [e["at"] for e in events] == sorted(e["at"] for e in events)
    assert events[-1]["at"] < env.clock.now.strftime("%Y-%m-%dT%H:%M:%S.%fZ")
    assert {"groupCreated", "memberJoined", "expenseCreated", "paymentConfirmed"} <= {e["kind"] for e in events}
    assert _snapshot(env, session, groups["Tahoe Ski Weekend"]["group"]["id"])["receipts"] == []


def test_each_device_gets_its_own_demo(env: Env) -> None:
    first, second = _start(env), _start(env)
    assert first["userId"] != second["userId"] and first["token"] != second["token"]
    first_groups, second_groups = _groups(env, first), _groups(env, second)
    first_ids = {summary["group"]["id"] for summary in first_groups.values()}
    assert first_ids.isdisjoint(summary["group"]["id"] for summary in second_groups.values())
    other = next(iter(first_ids))
    assert env.client.get(f"/v1/groups/{other}", headers=_headers(second)).status_code == 404
    # A real account sees nothing of either.
    create_group(env, "riley")
    assert env.client.get(f"/v1/groups/{other}", headers=account("riley")).status_code == 404
    assert [g["group"]["name"] for g in env.client.get("/v1/groups", headers=account("riley")).json["groups"]] == ["Coastal Weekend"]


def test_the_demo_works_like_the_real_app(env: Env) -> None:
    session = _start(env)
    groups = _groups(env, session)
    apartment_id = groups["Apartment 4B"]["group"]["id"]
    snapshot = _snapshot(env, session, apartment_id)
    me = snapshot["viewer"]["memberId"]
    # Paying someone you owe (Friday Dinner) goes through the real payment flow.
    dinner_id = groups["Friday Dinner Crew"]["group"]["id"]
    dinner = _snapshot(env, session, dinner_id)
    [to_maya] = [p for p in dinner["balances"]["payments"] if p["payerId"] == me and p["amount"] == 5_200]
    started = _send(
        env,
        session,
        dinner_id,
        "startPayment",
        {"attemptId": str(uuid.uuid4()), "recipientId": to_maya["recipientId"], "amount": 5_200, "provider": "cash"},
    )
    assert started.status_code == 200, started.json
    maya = next(m["id"] for m in snapshot["members"] if m["displayName"] == "Maya Chen")
    added = _send(env, session, apartment_id, "addExpense", {"expense": expense(me, 2_000, [(me, 1_000), (maya, 1_000)], title="Movie")})
    assert added.status_code == 200, added.json
    # A new shared group of its own is part of the demo too.
    created = env.client.post(
        "/v1/groups",
        json={"groupId": str(uuid.uuid4()), "name": "Book club", "symbol": "book.fill", "currency": "USD"},
        headers=_headers(session),
    )
    assert created.status_code == 201 and env.store.get(SHARED_GROUP, created.json["snapshot"]["group"]["id"])["demo"] is True
    renamed = env.client.put("/v1/account/profile", json={"displayName": "Avery L."}, headers=_headers(session))
    assert renamed.status_code == 200


def test_the_demo_never_reaches_real_people_or_their_groups(env: Env) -> None:
    session = _start(env)
    group_id = _groups(env, session)["Apartment 4B"]["group"]["id"]
    headers = _headers(session)

    def refused(response: Any) -> None:
        assert response.status_code == 403 and response.json["error"]["code"] == "demo_restricted", response.json

    create_group(env, "riley")  # a real account, findable as riley@example.com
    env.client.get("/v1/account", headers=account("riley"))
    refused(env.client.post(f"/v1/groups/{group_id}/people/lookup", json={"email": "riley@example.com"}, headers=headers))
    refused(env.client.post(f"/v1/groups/{group_id}/direct-invitations", json={"email": "riley@example.com"}, headers=headers))
    refused(env.client.post(f"/v1/groups/{group_id}/invitations", json={}, headers=headers))
    # Joining a real group with a real invitation is refused, and the group doesn't change.
    code = invite(env, "riley")["code"]
    refused(env.client.post(f"/v1/group-invitations/{code}/accept", json={"displayName": "Avery"}, headers=headers))
    real = env.client.get(f"/v1/groups/{env.id('group')}", headers=account("riley")).json["snapshot"]
    assert [m["displayName"] for m in real["members"]] == ["Riley"]
    # A demo account is never findable by a real one: it has no directory entry at all.
    assert env.store.count(ACCOUNT_DIRECTORY) == 1  # riley's
    found = env.client.post(f"/v1/groups/{env.id('group')}/people/lookup", json={"email": "avery@example.com"}, headers=account("riley"))
    assert found.status_code == 200 and found.json["match"] is None


def test_reset_restores_only_this_demo_to_its_seed(env: Env) -> None:
    session, neighbour = _start(env), _start(env)
    before = _groups(env, session)
    neighbour_before = _groups(env, neighbour)
    apartment_id = before["Apartment 4B"]["group"]["id"]
    me = _snapshot(env, session, apartment_id)["viewer"]["memberId"]
    _send(env, session, apartment_id, "addExpense", {"expense": expense(me, 1_500, [(me, 1_500)], title="Plants")})
    env.client.put("/v1/account/profile", json={"displayName": "Someone else"}, headers=_headers(session))
    create_group(env, "riley")
    real_before = env.client.get(f"/v1/groups/{env.id('group')}", headers=account("riley")).json["snapshot"]

    reset = env.client.post("/v1/demo/reset", headers=_headers(session))
    assert reset.status_code == 200, reset.json
    assert reset.json["profile"]["displayName"] == "Avery Lee" and reset.json["profile"]["memberId"] == me
    after = _groups(env, session)
    assert list(after) == list(before)
    assert {g["group"]["id"] for g in after.values()}.isdisjoint(g["group"]["id"] for g in before.values())
    assert env.client.get(f"/v1/groups/{apartment_id}", headers=_headers(session)).status_code == 404
    fresh = _snapshot(env, session, after["Apartment 4B"]["group"]["id"])
    assert "Plants" not in [e["title"] for e in fresh["expenses"]] and fresh["viewer"]["memberId"] == me
    # Nobody else's data moved: the other demo, and the real group.
    assert _groups(env, neighbour) == neighbour_before
    assert env.client.get(f"/v1/groups/{env.id('group')}", headers=account("riley")).json["snapshot"]["revision"] == real_before["revision"]
    # Reset is for demo accounts only.
    assert env.client.post("/v1/demo/reset", headers=account("riley")).status_code == 401


def test_leaving_deletes_the_workspace_and_ends_the_credential(env: Env) -> None:
    create_group(env, "riley")
    real_groups = env.store.count(SHARED_GROUP)
    session = _start(env)
    assert env.store.count(SHARED_GROUP) == real_groups + 3
    assert env.client.delete("/v1/demo/session", headers=_headers(session)).status_code == 200
    ended = env.client.get("/v1/account", headers=_headers(session))
    assert ended.status_code == 401 and ended.json["error"]["code"] == "unauthenticated" and "demo" in ended.json["error"]["message"]
    assert env.store.count(SHARED_GROUP) == real_groups
    assert env.store.count(GROUP_RECEIPT) == 0 and env.store.count(DEMO_SESSION) == 0
    assert env.store.get(ACCOUNT, session["userId"]) is None
    assert not env.store.query(GROUP_MEMBERSHIP, "uid", session["userId"])


def test_a_demo_ends_after_a_week_and_cleanup_deletes_it(env: Env) -> None:
    session = _start(env)
    env.clock.advance(days=7, minutes=1)
    assert env.client.get("/v1/groups", headers=_headers(session)).status_code == 401
    removed = env.client.get("/tasks/cleanup", headers={"X-Appengine-Cron": "true"}).json["removed"]
    assert removed["demoWorkspaces"] == 1
    assert env.store.count(SHARED_GROUP) == 0 and env.store.get(ACCOUNT, session["userId"]) is None


def test_a_class_can_enter_at_once_and_the_demo_can_be_turned_off(env: Env) -> None:
    for _ in range(12):  # one network, no limit
        _start(env)
    off = build(demo_enabled=False)
    response = off.client.post("/v1/demo/sessions")
    assert response.status_code == 503 and response.json["error"]["code"] == "demo_unavailable"
    assert off.client.get("/v1/account", headers={"Authorization": "Demo not-a-real-credential"}).status_code == 401


def _quota_key(scope: str, client: str, now: datetime, window: int = 86_400) -> str:
    return token_hash(f"{scope}|{client}|{int(now.timestamp()) // window}")


def test_demo_receipt_scans_use_the_ai_pipeline_without_touching_any_limit() -> None:
    provider = FakeProvider(lambda _: text(output()))
    env = build(intelligence_provider=provider)
    session = _start(env)
    for _ in range(12):  # past every real per-minute and per-day limit
        scanned = env.client.post(PARSE, json=request_body(), headers=_headers(session))
        assert scanned.status_code == 200, scanned.json
    assert scanned.json["proposal"]["items"] and scanned.json["provider"] == provider.name
    now = env.clock.now.astimezone(UTC)
    assert env.store.get(RATE, _quota_key("intelligence-global", "global", now)) is None
    # A real account's scan still counts, exactly as before.
    assert env.client.post(PARSE, json=request_body(texts=["Other receipt"]), headers=AI_ACCOUNT).status_code == 200
    assert env.store.get(RATE, _quota_key("intelligence-global", "global", now))["count"] == 1


def test_a_demo_hosts_live_rooms_that_real_accounts_cant_join(env: Env) -> None:
    session = _start(env)
    host = _headers(session)
    room_id, host_id = str(uuid.uuid4()), str(uuid.uuid4())
    receipt = {
        "merchant": "Sample Bistro",
        "date": "2026-09-24",
        "currency": "USD",
        "total": 3000,
        "items": [
            {"id": str(uuid.uuid4()), "name": "Pasta", "lineTotal": 1800},
            {"id": str(uuid.uuid4()), "name": "Salad", "lineTotal": 900},
        ],
        "charges": [{"id": str(uuid.uuid4()), "kind": "tax", "label": "Tax", "amount": 300}],
    }
    body = {
        "kind": "temporary",
        "roomId": room_id,
        "hostParticipantId": host_id,
        "payerId": host_id,
        "participants": [{"id": host_id, "displayName": "Avery"}],
        "receipt": receipt,
    }
    published = env.client.post("/v1/receipt-rooms", json=body, headers=host)
    assert published.status_code in (200, 201), published.json
    invitation = env.client.post(f"/v1/receipt-rooms/{room_id}/invitations", json={}, headers=host).json["invitation"]
    # People at the table join as guests (or from their own demo); a real account can't.
    guest = env.client.post("/v1/receipt-room-codes/join", json={"code": invitation["code"], "displayName": "Maya"})
    assert guest.status_code == 201, guest.json
    assert env.client.get(f"/v1/receipt-rooms/{room_id}", headers=guest_headers(guest.json["credential"])).status_code == 200
    neighbour = _start(env)
    other_demo = env.client.post(
        "/v1/receipt-room-codes/join", json={"code": invitation["code"], "displayName": "Sam"}, headers=_headers(neighbour)
    )
    assert other_demo.status_code == 201, other_demo.json
    real = env.client.post(
        "/v1/receipt-room-codes/join", json={"code": invitation["code"], "displayName": "Riley"}, headers=account("riley")
    )
    assert real.status_code == 403 and real.json["error"]["code"] == "demo_restricted"
    # And a demo can't join a real person's room with its account.
    real_room, real_host = str(uuid.uuid4()), str(uuid.uuid4())
    real_body = {
        **body,
        "roomId": real_room,
        "hostParticipantId": real_host,
        "payerId": real_host,
        "participants": [{"id": real_host, "displayName": "Riley"}],
    }
    assert env.client.post("/v1/receipt-rooms", json=real_body, headers=account("riley")).status_code in (200, 201)
    real_code = env.client.post(f"/v1/receipt-rooms/{real_room}/invitations", json={}, headers=account("riley")).json["invitation"]["code"]
    crossing = env.client.post("/v1/receipt-room-codes/join", json={"code": real_code, "displayName": "Avery"}, headers=host)
    assert crossing.status_code == 403 and crossing.json["error"]["code"] == "demo_restricted"
    # Leaving the demo takes its rooms with it; the real room stays.
    env.client.delete("/v1/demo/session", headers=host)
    assert env.store.get(ROOM, room_id) is None and env.store.get(ROOM, real_room) is not None


def test_demo_scans_have_their_own_daily_budget_and_real_limits_are_unchanged() -> None:
    provider = FakeProvider(lambda _: text(output()))
    limits = {**Config().rate_limits, "intelligence-demo-daily": (2, 86_400), "intelligence-demo-global": (3, 86_400)}
    env = build(intelligence_provider=provider, rate_limits=limits)
    first, second = _start(env), _start(env)

    def scan(session: dict[str, Any], label: str) -> Any:
        return env.client.post(PARSE, json=request_body(texts=[label]), headers=_headers(session))

    assert scan(first, "one").status_code == 200 and scan(first, "two").status_code == 200
    used_up = scan(first, "three")  # this workspace's budget
    assert used_up.status_code == 429 and used_up.json["error"]["code"] == "ai_demo_limit"
    assert "demo" in used_up.json["error"]["message"]
    assert scan(second, "four").status_code == 200
    all_demos = scan(second, "five")  # every demo's budget together
    assert all_demos.status_code == 429 and all_demos.json["error"]["code"] == "ai_demo_limit"
    assert len(provider.calls) == 3  # refused scans never reach the provider
    # Real accounts keep their own limits, untouched by the demos.
    assert env.client.post(PARSE, json=request_body(texts=["real"]), headers=AI_ACCOUNT).status_code == 200
    now = env.clock.now.astimezone(UTC)
    assert env.store.get(RATE, _quota_key("intelligence-global", "global", now))["count"] == 1
