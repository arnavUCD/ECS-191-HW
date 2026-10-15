"""Publishing a local group, adopting a Live Receipt Room, and concurrency (milestone 7 §8, §9.2, §5.3)."""

from __future__ import annotations

import threading
import uuid
from typing import Any

from squareup.storage.base import GROUP_MEMBERSHIP, GROUP_PUBLICATION, SHARED_GROUP

from .conftest import Env, receipt
from .conftest import command as room_command
from .conftest import join as room_join
from .group_kit import accept, account, add_expense, command, expense, invite, profile, snapshot, two_person_group

RILEY, MAYA, DEV = (str(uuid.UUID(int=index)) for index in (101, 102, 103))


def local_group(env: Env, **overrides: Any) -> dict[str, Any]:
    """A local group the way the app uploads it: stable IDs, history, tombstones, and a settlement."""
    group_id = env.id("local-group")
    dinner = expense(RILEY, 9000, [(RILEY, 3000), (MAYA, 3000), (DEV, 3000)], method="equal", title="Dinner", expense_id=env.id("dinner"))
    gas = expense(MAYA, 4000, [(RILEY, 2000), (MAYA, 2000)], method="equal", title="Gas", expense_id=env.id("gas"))
    receipt = expense(DEV, 1500, [(RILEY, 500), (DEV, 1000)], method="itemized", title="Tacos", expense_id=env.id("tacos"))
    deleted = expense(RILEY, 100, [(RILEY, 100)], title="Mistake", expense_id=env.id("mistake"))
    meta = {"createdBy": RILEY, "createdAt": "2026-09-20T10:00:00Z", "revision": 1}
    body: dict[str, Any] = {
        "publicationId": env.id("publication"),
        "publisherMemberId": RILEY,
        "group": {
            "id": group_id,
            "name": "Coastal Weekend Trip",
            "symbol": "beach.umbrella.fill",
            "currency": "USD",
            "simplifiesDebts": True,
            "createdAt": "2026-09-19T09:00:00Z",
        },
        "members": [
            {"id": RILEY, "displayName": "Riley (this iPhone)"},
            {"id": MAYA, "displayName": "Maya"},
            {"id": DEV, "displayName": "Dev"},
        ],
        "expenses": [
            {**dinner, **meta},
            {**gas, **meta, "createdBy": MAYA, "revision": 2, "updatedAt": "2026-09-21T10:00:00Z", "updatedBy": MAYA},
            {**receipt, **meta, "createdBy": DEV},
            {**deleted, **meta, "deletedAt": "2026-09-21T11:00:00Z", "deletedBy": RILEY},
        ],
        "settlements": [
            {
                "id": env.id("paid"),
                "fromId": DEV,
                "toId": RILEY,
                "amount": 1000,
                "date": "2026-09-22T10:00:00Z",
                "recordedBy": DEV,
                "provider": "zelle",
            }
        ],
        "events": [
            {"kind": "groupCreated", "actorMemberId": RILEY, "at": "2026-09-19T09:00:00Z", "data": {"name": "Coastal Weekend Trip"}},
            {
                "kind": "expenseCreated",
                "actorMemberId": RILEY,
                "at": "2026-09-20T10:00:00Z",
                "data": {"expenseId": env.id("dinner"), "title": "Dinner", "total": 9000},
            },
            {
                "kind": "paymentStarted",
                "actorMemberId": DEV,
                "at": "2026-09-22T09:00:00Z",
                "data": {"attemptId": str(uuid.uuid4()), "note": "private"},
            },
        ],
    }
    for key, value in overrides.items():
        body[key] = value
    return body


def publish(env: Env, body: dict[str, Any], who: str = "riley") -> Any:
    profile(env, who, "Riley")
    return env.client.post("/v1/groups/publications", json=body, headers=account(who))


def test_publishing_keeps_ids_history_and_balances(env: Env) -> None:
    response = publish(env, local_group(env))
    assert response.status_code == 201, response.json
    snap = response.json["snapshot"]
    assert snap["group"]["id"] == env.id("local-group") and snap["viewer"] == {"memberId": RILEY, "isOwner": True}
    statuses = {m["id"]: (m["displayName"], m["status"]) for m in snap["members"]}
    assert statuses == {RILEY: ("Riley", "active"), MAYA: ("Maya", "pending"), DEV: ("Dev", "pending")}
    assert {e["id"] for e in snap["expenses"]} == {env.id("dinner"), env.id("gas"), env.id("tacos"), env.id("mistake")}
    tacos = next(e for e in snap["expenses"] if e["id"] == env.id("tacos"))
    assert tacos["receipt"] is None and tacos["receiptOmitted"] is True
    # Dinner: Maya and Dev owe Riley 30 each. Gas: Riley owes Maya 20. Tacos: Riley owes Dev 5. Dev paid Riley 10.
    assert snap["balances"]["confirmedNets"] == {RILEY: 6000 - 2000 - 500 - 1000, MAYA: -3000 + 2000, DEV: -3000 + 500 + 1000}
    kinds = [event["kind"] for event in snap["events"]]
    assert kinds == ["groupCreated", "expenseCreated", "paymentStarted", "groupPublished"]
    assert "note" not in snap["events"][2]["data"]
    assert [e["sequence"] for e in snap["events"]] == [1, 2, 3, 4]


def test_a_retry_returns_the_original_result_and_never_duplicates(env: Env) -> None:
    body = local_group(env)
    first = publish(env, body)
    second = publish(env, body)
    assert first.status_code == 201 and second.status_code == 200 and second.json["created"] is False
    assert second.json["snapshot"]["revision"] == first.json["snapshot"]["revision"]
    assert env.store.count(SHARED_GROUP) == 1 and env.store.count(GROUP_PUBLICATION) == 1
    changed = local_group(env)
    changed["group"]["name"] = "Different"
    assert publish(env, changed).json["error"]["code"] == "idempotency_key_reused"


def test_an_invalid_snapshot_writes_nothing(env: Env) -> None:
    body = local_group(env)
    body["expenses"][1]["allocations"][0]["amount"] = 1999  # no longer reconciles
    response = publish(env, body)
    assert response.status_code == 422 and response.json["error"]["reason"] == "allocationsDoNotReconcile"
    assert env.store.count(SHARED_GROUP) == 0 and env.store.count(GROUP_MEMBERSHIP) == 0 and env.store.count(GROUP_PUBLICATION) == 0
    # The same publication ID works once the snapshot is fixed.
    assert publish(env, local_group(env)).status_code == 201


def test_legacy_organization_data_and_open_payments_are_refused(env: Env) -> None:
    organization = local_group(env)
    organization["group"]["kind"] = "organization"
    assert publish(env, organization).json["error"]["reason"] == "legacyOrganization"
    funded = local_group(env)
    funded["expenses"][0]["organizationFunding"] = {"requested": 100}
    assert publish(env, funded).json["error"]["reason"] == "legacyOrganization"
    open_payment = local_group(env, openPayments=[{"id": str(uuid.uuid4())}])
    assert publish(env, open_payment).status_code == 400
    assert env.store.count(SHARED_GROUP) == 0


def test_publisher_must_be_an_active_member_and_ids_unique(env: Env) -> None:
    missing = local_group(env, publisherMemberId=str(uuid.uuid4()))
    assert publish(env, missing).json["error"]["reason"] == "publisherMissing"
    duplicate = local_group(env)
    duplicate["expenses"].append(duplicate["expenses"][0])
    assert publish(env, duplicate).json["error"]["reason"] == "duplicateExpense"


def test_another_account_cannot_publish_the_same_group(env: Env) -> None:
    assert publish(env, local_group(env)).status_code == 201
    copy = local_group(env, publicationId=str(uuid.uuid4()))
    response = publish(env, copy, who="maya")
    assert response.status_code == 409 and response.json["error"]["code"] == "entity_exists"


def test_seat_invitations_bind_an_account_without_changing_history(env: Env) -> None:
    publish(env, local_group(env))
    group_id = env.id("local-group")
    seat_invitation = invite(env, "riley", group_id, seatMemberId=MAYA)
    replaced = invite(env, "riley", group_id, seatMemberId=MAYA)
    assert env.client.get(f"/v1/group-invitations/{seat_invitation['code']}").json["error"]["code"] == "invitation_revoked"
    joined = accept(env, replaced["code"], "maya-account", "Maya Chen")
    assert joined.status_code == 201, joined.json
    snap = joined.json["snapshot"]
    assert snap["viewer"]["memberId"] == MAYA, "the account took Maya's seat; her history is hers"
    assert {m["id"]: m["status"] for m in snap["members"]}[MAYA] == "active"
    assert snap["balances"]["confirmedNets"][MAYA] == -1000


def test_a_joined_seat_cannot_be_invited_again(env: Env) -> None:
    publish(env, local_group(env))
    group_id = env.id("local-group")
    accept(env, invite(env, "riley", group_id, seatMemberId=MAYA)["code"], "maya-account")
    response = env.client.post(f"/v1/groups/{group_id}/invitations", json={"seatMemberId": MAYA}, headers=account("riley"))
    assert response.json["error"]["code"] == "seat_unavailable"


# MARK: - Live Receipt Room adoption


def _room_group(env: Env) -> tuple[str, str]:
    """A shared group whose members share a server room: the room's seats are the group's members,
    and Riley's account hosts it."""
    riley, maya = two_person_group(env)
    body = {
        "roomId": env.id("room"),
        "hostParticipantId": riley,
        "payerId": riley,
        "participants": [{"id": riley, "displayName": "Riley"}, {"id": maya, "displayName": "Maya"}],
        "receipt": receipt(env),
        "claims": [
            {"itemId": env.id("fries"), "participantId": riley, "mode": {"kind": "full"}},
            {"itemId": env.id("pizza"), "participantId": maya, "mode": {"kind": "full"}},
        ],
    }
    response = env.client.post("/v1/receipt-rooms", json=body, headers=account("riley"))
    assert response.status_code == 201, response.json
    return riley, maya


def _room_host_headers() -> dict[str, str]:
    return account("riley")


def _finalize_room(env: Env) -> Any:
    room_id = env.id("room")
    revision = env.client.get(f"/v1/receipt-rooms/{room_id}", headers=_room_host_headers()).json["room"]["revision"]
    ready = room_command(env, _room_host_headers(), "transition", {"move": "requestFinalReview"}, revision=revision)
    assert ready.status_code == 200, ready.json
    return room_command(env, _room_host_headers(), "finalize", {}, revision=ready.json["revision"], path="finalize")


def _room_invitation(env: Env) -> str:
    response = env.client.post(f"/v1/receipt-rooms/{env.id('room')}/invitations", json={}, headers=_room_host_headers())
    assert response.status_code == 201, response.json
    return str(response.json["invitation"]["token"])


def test_a_finalized_room_is_adopted_exactly_once(env: Env) -> None:
    riley, maya = _room_group(env)
    room_id = env.id("room")
    early = command(env, "riley", "adoptRoom", {"roomId": room_id})
    assert early.json["error"]["code"] in ("room_not_adoptable", "room_not_found")
    finalized = _finalize_room(env)
    assert finalized.status_code == 200, finalized.json
    assert command(env, "maya", "adoptRoom", {"roomId": room_id}).json["error"]["code"] == "room_not_found", "only the host adopts"
    for _ in range(2):
        adopted = command(env, "riley", "adoptRoom", {"roomId": room_id})
        assert adopted.status_code == 200, adopted.json
    snap = snapshot(env, "maya")
    receipts = [e for e in snap["expenses"] if e["id"] == room_id]
    assert len(receipts) == 1 and receipts[0]["splitMethod"] == "itemized" and receipts[0]["total"] == 2165
    allocations = {s["memberId"]: s["amount"] for s in receipts[0]["allocations"]}
    assert sum(allocations.values()) == 2165 and set(allocations) == {riley, maya}
    assert receipts[0]["receipt"]["items"][0]["shares"][0]["memberId"] in (riley, maya)
    assert [e["kind"] for e in snap["events"]].count("receiptRoomAdopted") == 1


def test_guests_must_be_matched_before_adoption(env: Env) -> None:
    riley, maya = _room_group(env)
    room_id = env.id("room")
    guest = room_join(env, _room_invitation(env), "Sam")
    guest_id = guest["participantId"]
    guest_headers = {"Authorization": f"Guest {guest['credential']}"}
    claim = room_command(env, guest_headers, "claim", {"itemId": env.id("fries"), "request": "share"})
    assert claim.status_code == 200, claim.json
    assert _finalize_room(env).status_code == 200
    unmatched = command(env, "riley", "adoptRoom", {"roomId": room_id})
    assert unmatched.json["error"]["code"] == "guests_not_matched"
    matched = command(env, "riley", "adoptRoom", {"roomId": room_id, "guestMembers": {guest_id: maya}})
    assert matched.status_code == 200, matched.json
    allocations = {s["memberId"]: s["amount"] for e in snapshot(env, "riley")["expenses"] for s in e["allocations"]}
    assert set(allocations) == {riley, maya}


# MARK: - Concurrency


def test_concurrent_confirmations_create_one_settlement(env: Env) -> None:
    riley, maya = two_person_group(env)
    add_expense(env, "riley", expense(riley, 6000, [(riley, 3000), (maya, 3000)], method="equal"))
    attempt = str(uuid.uuid4())
    command(env, "maya", "startPayment", {"attemptId": attempt, "recipientId": riley, "amount": 3000, "provider": "cash"})
    command(env, "maya", "advancePayment", {"attemptId": attempt, "action": "reportSent"})
    statuses: list[int] = []

    def confirm() -> None:
        client = env.app.test_client()
        body = {
            "commandId": str(uuid.uuid4()),
            "idempotencyKey": uuid.uuid4().hex,
            "expectedRevision": 0,
            "type": "advancePayment",
            "payload": {"attemptId": attempt, "action": "confirm"},
        }
        statuses.append(client.post(f"/v1/groups/{env.id('group')}/commands", json=body, headers=account("riley")).status_code)

    threads = [threading.Thread(target=confirm) for _ in range(6)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    assert set(statuses) <= {200, 503}
    snap = snapshot(env, "riley")
    assert len(snap["settlements"]) == 1 and [e["kind"] for e in snap["events"]].count("paymentConfirmed") == 1


def test_concurrent_strict_commands_on_one_revision_apply_once(env: Env) -> None:
    two_person_group(env)
    revision = snapshot(env, "riley")["revision"]
    statuses: list[int] = []

    def rename(name: str) -> None:
        client = env.app.test_client()
        body = {
            "commandId": str(uuid.uuid4()),
            "idempotencyKey": uuid.uuid4().hex,
            "expectedRevision": revision,
            "type": "updateGroup",
            "payload": {"name": name, "symbol": "car.fill", "currency": "USD"},
        }
        statuses.append(client.post(f"/v1/groups/{env.id('group')}/commands", json=body, headers=account("riley")).status_code)

    threads = [threading.Thread(target=rename, args=(f"Name {index}",)) for index in range(5)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    assert statuses.count(200) == 1 and set(statuses) - {200} <= {409, 503}
    assert snapshot(env, "riley")["revision"] == revision + 1
