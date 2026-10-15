"""Receipt split (October 2026): unit claims, the review rule, temporary rooms ("Split with people
now": short codes, guests, payments, closure, retention), and receipts posted into shared groups
for asynchronous allocation ("Add to a group")."""

from __future__ import annotations

import uuid
from typing import Any

from squareup.domain.allocation import allocate
from squareup.domain.room import Claim, ClaimMode, Item, Participant, Receipt, Room
from squareup.storage.base import ASSET, GROUP_RECEIPT, GUEST, INVITATION, ROOM, ROOM_CODE
from tests.conftest import HOST, Env, guest_headers
from tests.group_kit import account, add_expense, create_group, expense, join, member_id, profile, snapshot
from tests.group_kit import command as group_command

ROOM_ROUTE = "/v1/receipt-rooms"


# MARK: - Unit claims (pure allocation)


def _room(items: list[Item], claims: list[Claim], people: tuple[str, ...] = ("a", "b", "c")) -> Room:
    receipt = Receipt("M", "2026-09-24", "USD", items, [], sum(item.line_total for item in items))
    participants = [Participant(pid, pid.upper(), "host" if index == 0 else "member", "t") for index, pid in enumerate(people)]
    return Room("r", "uid", people[0], people[0], "open", receipt, participants, claims)


def test_unit_claims_divide_by_quantity_and_leave_the_rest_unassigned() -> None:
    beers = Item("beer", "Beer", 1800, quantity=3, unit_price=600)
    partial = allocate(_room([beers], [Claim("beer", "a", ClaimMode("units", units=2))]))
    item = partial.item("beer")
    assert item is not None and item.status == "partial" and item.shares == [("a", 1200)] and item.remaining == 600
    full = allocate(_room([beers], [Claim("beer", "a", ClaimMode("units", units=2)), Claim("beer", "b", ClaimMode("units", units=1))]))
    item = full.item("beer")
    assert item is not None and item.status == "allocated" and item.shares == [("a", 1200), ("b", 600)]
    # Exact cents: 1000 over 3 units is 333.33…; the leftover cent goes by largest remainder.
    odd = Item("wings", "Wings", 1000, quantity=3)
    split = allocate(_room([odd], [Claim("wings", "a", ClaimMode("units", units=1)), Claim("wings", "b", ClaimMode("units", units=2))]))
    item = split.item("wings")
    assert item is not None and sum(amount for _, amount in item.shares) == 1000 and item.shares == [("a", 333), ("b", 667)]


def test_unit_claims_refuse_mixed_modes_unknown_quantity_and_too_many() -> None:
    beers = Item("beer", "Beer", 1800, quantity=3)
    mixed = allocate(_room([beers], [Claim("beer", "a", ClaimMode("units", units=1)), Claim("beer", "b", ClaimMode("equalShare"))]))
    assert (mixed.item("beer") or Any).reason == "mixedModes"
    unknown = allocate(_room([Item("x", "X", 500)], [Claim("x", "a", ClaimMode("units", units=1))]))
    assert (unknown.item("x") or Any).reason == "noQuantity"
    over = allocate(_room([beers], [Claim("beer", "a", ClaimMode("units", units=2)), Claim("beer", "b", ClaimMode("units", units=2))]))
    item = over.item("beer")
    assert item is not None and item.reason == "unitsExceed" and item.reason_amount == 1


# MARK: - Temporary rooms


def _receipt(env: Env) -> dict[str, Any]:
    return {
        "merchant": "Driftwood Kitchen",
        "date": "2026-09-24",
        "currency": "USD",
        "total": 3000,
        "items": [
            {"id": env.id("beer"), "name": "Beer", "lineTotal": 1800, "quantity": 3, "unitPrice": 600},
            {"id": env.id("fries"), "name": "Fries", "lineTotal": 900},
        ],
        "charges": [{"id": env.id("tax"), "kind": "tax", "label": "Tax", "amount": 300}],
    }


def _temporary(env: Env, **extra: Any) -> dict[str, Any]:
    body = {
        "kind": "temporary",
        "roomId": env.id("room"),
        "hostParticipantId": env.id("host"),
        "payerId": env.id("host"),
        "participants": [{"id": env.id("host"), "displayName": "Riley"}],
        "receipt": _receipt(env),
        **extra,
    }
    response = env.client.post(ROOM_ROUTE, json=body, headers=HOST)
    assert response.status_code in (200, 201), response.json
    room: dict[str, Any] = response.json["room"]
    return room


def _invite(env: Env, **options: Any) -> dict[str, Any]:
    response = env.client.post(f"{ROOM_ROUTE}/{env.id('room')}/invitations", json=options, headers=HOST)
    assert response.status_code == 201, response.json
    invitation: dict[str, Any] = response.json["invitation"]
    return invitation


def _join_code(env: Env, code: str, name: str, headers: dict[str, str] | None = None) -> Any:
    return env.client.post("/v1/receipt-room-codes/join", json={"code": code, "displayName": name}, headers=headers or {})


def _send(env: Env, headers: dict[str, str], kind: str, payload: dict[str, Any], *, key: str | None = None, path: str = "commands") -> Any:
    revision = env.client.get(f"{ROOM_ROUTE}/{env.id('room')}", headers=headers).json["room"]["revision"]
    body = {
        "commandId": str(uuid.uuid4()),
        "idempotencyKey": key or uuid.uuid4().hex,
        "expectedRevision": revision,
        "type": kind,
        "payload": payload,
    }
    return env.client.post(f"{ROOM_ROUTE}/{env.id('room')}/{path}", json=body, headers=headers)


def _guests(env: Env) -> tuple[dict[str, str], str, dict[str, str], str]:
    invitation = _invite(env)
    maya = _join_code(env, invitation["code"], "Maya")
    dev = _join_code(env, invitation["code"].lower().replace("-", " "), "Dev")
    assert maya.status_code == 201 and dev.status_code == 201
    return (
        guest_headers(maya.json["credential"]),
        maya.json["participantId"],
        guest_headers(dev.json["credential"]),
        dev.json["participantId"],
    )


def _claim_everything(env: Env, maya: dict[str, str], dev: dict[str, str]) -> None:
    assert _send(env, maya, "claimUnits", {"itemId": env.id("beer"), "units": 2}).status_code == 200
    assert _send(env, dev, "claimUnits", {"itemId": env.id("beer"), "units": 1}).status_code == 200
    assert _send(env, dev, "claim", {"itemId": env.id("fries"), "request": "mine"}).status_code == 200


def _finalize(env: Env, acknowledge: list[str] | None = None) -> Any:
    assert _send(env, HOST, "transition", {"move": "requestFinalReview"}).status_code == 200
    payload = {} if acknowledge is None else {"acknowledgeUnreviewed": acknowledge}
    return _send(env, HOST, "finalize", payload, path="finalize")


def test_temporary_room_starts_with_only_its_host_who_paid(env: Env) -> None:
    room = _temporary(env)
    assert room["kind"] == "temporary" and room["participantOrder"] == [env.id("host")] and room["expiresAt"]
    two = env.client.post(
        ROOM_ROUTE,
        json={
            "kind": "temporary",
            "roomId": env.id("other"),
            "hostParticipantId": env.id("h2"),
            "payerId": env.id("x"),
            "participants": [{"id": env.id("h2"), "displayName": "R"}, {"id": env.id("x"), "displayName": "X"}],
            "receipt": _receipt(env),
        },
        headers=HOST,
    )
    assert two.status_code == 400 and two.json["error"]["code"] == "invalid_payload"
    unverified = env.client.post(ROOM_ROUTE, json={"kind": "temporary"}, headers={"Authorization": "Bearer unverified-x"})
    assert unverified.status_code == 403 and unverified.json["error"]["code"] == "email_not_verified"


def test_short_codes_join_preview_and_never_reveal_the_room_before_joining(env: Env) -> None:
    _temporary(env)
    invitation = _invite(env)
    code = invitation["code"]
    assert len(code) == 14 and code.count("-") == 2 and invitation["url"].startswith("https://squareup.example/r/")
    preview = env.client.post("/v1/receipt-room-codes/preview", json={"code": code})
    assert preview.status_code == 200
    body = preview.json["invitation"]
    assert body["kind"] == "temporary" and body["merchant"] == "Driftwood Kitchen" and body["host"]["displayName"] == "Riley"
    assert "items" not in body and "claims" not in body and body["openSeats"] == []
    for wrong in ("0000-0000-0000", "nonsense", "", "Z" * 200):
        reply = env.client.post("/v1/receipt-room-codes/preview", json={"code": wrong})
        assert reply.status_code == 404 and reply.json["error"]["code"] == "invitation_invalid"
    # Neither the code nor the token is stored, only hashes.
    stored = [record for _, record in env.store.query(ROOM_CODE, "roomId", env.id("room"))]
    assert stored and all(code.replace("-", "") not in str(record) and invitation["token"] not in str(record) for record in stored)


def test_guests_join_by_code_restore_on_rejoin_and_stay_isolated(env: Env) -> None:
    _temporary(env)
    invitation = _invite(env)
    first = _join_code(env, invitation["code"], "Maya")
    assert first.status_code == 201 and first.json["credential"]
    maya = guest_headers(first.json["credential"])
    again = _join_code(env, invitation["code"], "Maya", headers=maya)
    assert again.status_code == 200 and again.json["restored"] and again.json["participantId"] == first.json["participantId"]
    # A guest credential never reaches groups, receipt intelligence, accounts, or another room.
    assert env.client.get("/v1/groups", headers=maya).status_code in (401, 403)
    assert env.client.get("/v1/account", headers=maya).status_code in (401, 403)
    assert env.client.post("/v1/receipt-intelligence/parse", json={}, headers=maya).status_code in (401, 403)
    assert env.client.get(f"{ROOM_ROUTE}/{env.id('elsewhere')}", headers=maya).status_code == 404
    # Payment details aren't shown before anything is owed.
    reveal = env.client.get(f"{ROOM_ROUTE}/{env.id('room')}/payment-destinations", headers=maya)
    assert reveal.status_code == 403 and reveal.json["error"]["code"] == "reveal_not_allowed"


def test_multiple_invitations_revocation_and_single_use(env: Env) -> None:
    _temporary(env)
    one = _invite(env, maxGuests=1)
    other = _invite(env)
    assert one["code"] != other["code"]
    assert _join_code(env, one["code"], "A").status_code == 201
    full = _join_code(env, one["code"], "B")
    assert full.status_code == 409 and full.json["error"]["code"] == "invitation_full"
    revoked = env.client.delete(f"{ROOM_ROUTE}/{env.id('room')}/invitations/{other['invitationId']}", headers=HOST)
    assert revoked.status_code == 200
    gone = _join_code(env, other["code"], "C")
    assert gone.status_code == 410 and gone.json["error"]["code"] == "invitation_revoked"
    link = env.client.post(f"/v1/receipt-room-invitations/{other['token']}/join", json={"displayName": "C"})
    assert link.status_code == 410


def test_unit_claims_never_overwrite_someone_elses(env: Env) -> None:
    _temporary(env)
    maya, maya_id, dev, dev_id = _guests(env)
    assert _send(env, maya, "claimUnits", {"itemId": env.id("beer"), "units": 2}).status_code == 200
    too_many = _send(env, dev, "claimUnits", {"itemId": env.id("beer"), "units": 2})
    assert (
        too_many.status_code == 409 and too_many.json["error"]["code"] == "units_unavailable" and too_many.json["error"]["available"] == 1
    )
    assert too_many.json["room"]["claims"][0]["participantId"] == maya_id  # the current room comes back
    assert _send(env, dev, "claimUnits", {"itemId": env.id("beer"), "units": 1}).status_code == 200
    share = _send(env, dev, "claim", {"itemId": env.id("beer"), "request": "share"})
    assert share.status_code == 200 and share.json["applied"] is False  # already holding units
    room = env.client.get(f"{ROOM_ROUTE}/{env.id('room')}", headers=dev).json["room"]
    beer = next(item for item in room["allocation"]["items"] if item["itemId"] == env.id("beer"))
    assert beer["status"] == "allocated" and {s["participantId"]: s["amount"] for s in beer["shares"]} == {maya_id: 1200, dev_id: 600}
    no_quantity = _send(env, maya, "claimUnits", {"itemId": env.id("fries"), "units": 1})
    assert no_quantity.status_code == 422 and no_quantity.json["error"]["code"] == "item_quantity_unknown"
    # Setting units to zero removes only your own claim.
    assert _send(env, maya, "claimUnits", {"itemId": env.id("beer"), "units": 0}).status_code == 200


def test_unclaimed_items_block_finalization(env: Env) -> None:
    _temporary(env)
    maya, _, _, _ = _guests(env)
    assert _send(env, maya, "claimUnits", {"itemId": env.id("beer"), "units": 2}).status_code == 200
    blocked = _send(env, HOST, "transition", {"move": "requestFinalReview"})
    assert blocked.status_code == 409 and blocked.json["error"]["code"] == "not_ready_to_finalize"
    kinds = {issue["kind"] for issue in blocked.json["error"]["issues"]}
    assert {"partiallyAssignedItem", "unclaimedItem"} <= kinds


def test_finalizing_unreviewed_shares_needs_the_hosts_acknowledgement(env: Env) -> None:
    _temporary(env)
    maya, maya_id, dev, dev_id = _guests(env)
    _claim_everything(env, maya, dev)
    assert _send(env, maya, "markReviewed", {}).status_code == 200
    room = env.client.get(f"{ROOM_ROUTE}/{env.id('room')}", headers=HOST).json["room"]
    assert room["unreviewed"] == [dev_id]
    refused = _finalize(env)
    assert refused.status_code == 409 and refused.json["error"]["code"] == "unreviewed_shares"
    assert refused.json["error"]["participantIds"] == [dev_id]
    finalized = _send(env, HOST, "finalize", {"acknowledgeUnreviewed": [dev_id]}, path="finalize")
    assert finalized.status_code == 200, finalized.json
    final = finalized.json["room"]
    assert final["state"] == "finalized" and final["finalization"]["hostResolved"] == [dev_id]
    # Tax follows item subtotals: 300 × 1200/2700 = 133.33 for Maya, 166.67 for Dev, to the cent.
    totals = {p["participantId"]: p["total"] for p in final["finalization"]["participants"]}
    assert sum(totals.values()) == 3000 and totals[maya_id] == 1200 + 133 and totals[dev_id] == 600 + 900 + 167
    again = _send(env, HOST, "finalize", {"acknowledgeUnreviewed": [dev_id]}, path="finalize")
    assert again.status_code == 200 and again.json["applied"] is False


def test_a_review_lapses_when_the_share_changes(env: Env) -> None:
    _temporary(env)
    maya, maya_id, dev, _ = _guests(env)
    assert _send(env, maya, "claim", {"itemId": env.id("fries"), "request": "mine"}).status_code == 200
    assert _send(env, maya, "markReviewed", {}).status_code == 200
    assert maya_id not in env.client.get(f"{ROOM_ROUTE}/{env.id('room')}", headers=HOST).json["room"]["unreviewed"]
    assert _send(env, dev, "claim", {"itemId": env.id("fries"), "request": "share"}).status_code == 200
    assert maya_id in env.client.get(f"{ROOM_ROUTE}/{env.id('room')}", headers=HOST).json["room"]["unreviewed"]


def test_payments_report_confirm_and_close_when_everyone_is_square(env: Env) -> None:
    profile(env, "host-uid")
    destination = str(uuid.uuid4())
    saved = env.client.put(
        f"/v1/account/destinations/{destination}",
        json={"provider": "venmo", "value": {"kind": "username", "value": "riley-c"}, "isEnabled": True, "isPreferred": True},
        headers=HOST,
    )
    assert saved.status_code == 200, saved.json
    _temporary(env, paymentDestinationIds=[destination])
    maya, maya_id, dev, dev_id = _guests(env)
    _claim_everything(env, maya, dev)
    assert _finalize(env, [maya_id, dev_id]).status_code == 200
    room = env.client.get(f"{ROOM_ROUTE}/{env.id('room')}", headers=HOST).json["room"]
    assert {p["participantId"]: p["state"] for p in room["payments"]} == {maya_id: "owed", dev_id: "owed"}
    assert room["closedAt"] is None
    # Each guest sees only their own payment, and the payer's chosen method only while they owe.
    mine = env.client.get(f"{ROOM_ROUTE}/{env.id('room')}", headers=maya).json["room"]["payments"]
    assert [p["participantId"] for p in mine] == [maya_id]
    reveal = env.client.get(f"{ROOM_ROUTE}/{env.id('room')}/payment-destinations", headers=maya)
    assert reveal.status_code == 200 and [d["provider"] for d in reveal.json["destinations"]] == ["venmo"]
    assert reveal.headers["Cache-Control"] == "private, no-store" and reveal.json["recipient"]["displayName"] == "Riley"
    # Report (twice is once), only the recipient confirms.
    key = uuid.uuid4().hex
    assert _send(env, maya, "reportPayment", {"provider": "venmo", "destinationId": destination}, key=key).status_code == 200
    assert _send(env, maya, "reportPayment", {"provider": "venmo"}).json["applied"] is False
    forged = _send(env, dev, "confirmPayment", {"participantId": maya_id})
    assert forged.status_code == 403
    assert _send(env, HOST, "confirmPayment", {"participantId": maya_id}).status_code == 200
    gone = env.client.get(f"{ROOM_ROUTE}/{env.id('room')}/payment-destinations", headers=maya)
    assert gone.status_code == 403
    # Rejected → owed again; reporting again then confirming squares the room and closes it.
    assert _send(env, dev, "reportPayment", {"provider": "cash"}).status_code == 200
    assert _send(env, HOST, "rejectPayment", {"participantId": dev_id, "reason": "Not yet"}).status_code == 200
    dev_view = env.client.get(f"{ROOM_ROUTE}/{env.id('room')}", headers=dev).json["room"]
    assert dev_view["payments"][0]["state"] == "owed" and dev_view["payments"][0]["attempts"][-1]["state"] == "rejected"
    assert _send(env, dev, "reportPayment", {"provider": "cash"}).status_code == 200
    assert _send(env, dev, "disputePayment", {"participantId": dev_id}).status_code == 200
    closed = _send(env, HOST, "confirmPayment", {"participantId": dev_id})
    assert closed.status_code == 200
    final = closed.json["room"]
    assert final["closedAt"] and final["endReason"] == "allSquare"
    late = _send(env, maya, "reportPayment", {"provider": "cash"})
    assert late.status_code == 409 and late.json["error"]["code"] == "room_closed"


def test_payments_are_only_for_finalized_temporary_rooms(env: Env) -> None:
    _temporary(env)
    maya, _, _, _ = _guests(env)
    early = _send(env, maya, "reportPayment", {"provider": "cash"})
    assert early.status_code == 409 and early.json["error"]["code"] == "not_allowed_in_state"


def test_a_cancelled_room_ends_and_takes_nobody_new(env: Env) -> None:
    _temporary(env)
    invitation = _invite(env)
    cancelled = _send(env, HOST, "cancel", {})
    assert cancelled.status_code == 200 and cancelled.json["room"]["endReason"] == "cancelled"
    refused = _join_code(env, invitation["code"], "Late")
    assert refused.status_code in (409, 410)


def test_expiry_closes_the_room_and_retention_deletes_everything(env: Env) -> None:
    _temporary(env)
    maya, _, _, _ = _guests(env)
    env.blobs.put(f"rooms/{env.id('room')}/x.jpg", b"jpeg", "image/jpeg")
    env.store.run_in_transaction(
        lambda t: t.put(
            ASSET, env.id("asset"), {"roomId": env.id("room"), "objectName": f"rooms/{env.id('room')}/x.jpg"}, {"roomId": env.id("room")}
        )
    )
    env.clock.advance(hours=73)
    expired = _send(env, maya, "claim", {"itemId": env.id("fries"), "request": "mine"})
    assert expired.status_code == 410 and expired.json["error"]["code"] == "room_expired"
    view = env.client.get(f"{ROOM_ROUTE}/{env.id('room')}", headers=maya).json["room"]
    assert view["endReason"] == "expired"  # a read-only summary, before cleanup ran
    cleanup = env.client.get("/tasks/cleanup").json["removed"]
    assert cleanup["temporaryRoomsClosed"] == 1
    env.clock.advance(days=31)
    assert env.client.get("/tasks/cleanup").json["removed"]["temporaryRoomsDeleted"] == 1
    assert env.store.get(ROOM, env.id("room")) is None
    for kind in (INVITATION, ROOM_CODE, GUEST, ASSET):
        assert env.store.query(kind, "roomId", env.id("room")) == []
    assert env.blobs.get(f"rooms/{env.id('room')}/x.jpg") is None


def test_a_summary_is_hidden_after_retention_even_before_cleanup(env: Env) -> None:
    _temporary(env)
    _maya, _, _, _ = _guests(env)
    assert _send(env, HOST, "cancel", {}).status_code == 200
    assert env.client.get(f"{ROOM_ROUTE}/{env.id('room')}", headers=HOST).status_code == 200
    env.clock.advance(days=31)
    assert env.client.get(f"{ROOM_ROUTE}/{env.id('room')}", headers=HOST).status_code == 404


def test_group_rooms_keep_their_previous_behaviour(env: Env) -> None:
    """Rooms published from a group (milestone 4) don't need reviews and never expire."""
    from tests.conftest import publish

    publish(env)
    assert _send(env, HOST, "claim", {"itemId": env.id("fries"), "request": "mine"}).status_code == 200
    assert _send(env, HOST, "claim", {"itemId": env.id("pizza"), "request": "mine"}).status_code == 200
    assert _send(env, HOST, "setPayerAcceptsFullReceipt", {"accepts": True}).status_code == 200
    assert _send(env, HOST, "transition", {"move": "requestFinalReview"}).status_code == 200
    assert _send(env, HOST, "finalize", {}, path="finalize").status_code == 200
    env.clock.advance(days=400)
    assert env.client.get(f"{ROOM_ROUTE}/{env.id('room')}", headers=HOST).json["room"]["kind"] == "group"


# MARK: - Group receipts


def _group(env: Env) -> tuple[str, str, str]:
    """Riley owns a group Maya and Dev joined. Returns their member IDs."""
    create_group(env, "riley")
    join(env, "maya")
    dev_snapshot = join(env, "dev")
    return member_id(dev_snapshot, "Riley"), member_id(dev_snapshot, "Maya"), dev_snapshot["viewer"]["memberId"]


def _post(env: Env, people: list[str], who: str = "riley", **extra: Any) -> Any:
    return group_command(
        env, who, "postReceipt", {"receiptId": env.id("receipt"), "receipt": _receipt(env), "participantIds": people, **extra}
    )


def _receipt_view(env: Env, who: str) -> dict[str, Any]:
    response = env.client.get(f"/v1/groups/{env.id('group')}/receipts/{env.id('receipt')}", headers=account(who))
    assert response.status_code == 200, response.json
    view: dict[str, Any] = response.json["receipt"]
    return view


def _act(env: Env, who: str, kind: str, payload: dict[str, Any], *, revision: int | None = None) -> Any:
    if revision is None:
        revision = _receipt_view(env, who)["revision"]
    return group_command(
        env, who, "receiptCommand", {"receiptId": env.id("receipt"), "type": kind, "payload": payload, "expectedRevision": revision}
    )


def test_posting_needs_selected_active_members_and_a_reconciled_receipt(env: Env) -> None:
    riley, maya, dev = _group(env)
    outsider = _post(env, [riley, str(uuid.uuid4())])
    assert outsider.status_code == 422 and outsider.json["error"]["code"] == "inactive_participant"
    bad = group_command(
        env, "riley", "postReceipt", {"receiptId": env.id("receipt"), "receipt": {**_receipt(env), "total": 1}, "participantIds": [maya]}
    )
    assert bad.status_code == 422 and bad.json["error"]["code"] == "receipt_not_ready"
    posted = _post(env, [maya, dev])
    assert posted.status_code == 200, posted.json
    view = posted.json["receipt"]
    assert view["state"] == "open" and view["participantIds"] == [riley, maya, dev] and view["room"]["kind"] == "groupReceipt"
    # Posting again is harmless; nobody else can reuse the identifier.
    assert _post(env, [maya, dev]).json["applied"] is False
    assert _post(env, [maya], who="maya").status_code == 409


def test_pending_receipts_never_touch_balances_and_reach_members_by_normal_sync(env: Env) -> None:
    _riley, maya, _dev = _group(env)
    before = snapshot(env, "maya")
    _post(env, [maya])
    after = snapshot(env, "maya")
    assert after["balances"] == before["balances"]
    mine = next(r for r in after["receipts"] if r["id"] == env.id("receipt"))
    assert mine["viewerIsParticipant"] and mine["room"]["viewer"] == {"participantId": maya, "isHost": False}
    # Dev wasn't selected: an indicator only — no items, claims, or controls.
    theirs = next(r for r in snapshot(env, "dev")["receipts"] if r["id"] == env.id("receipt"))
    assert theirs["viewerIsParticipant"] is False and theirs["room"] is None and theirs["merchant"] == "Driftwood Kitchen"
    changes = env.client.get(f"/v1/groups/{env.id('group')}/changes?after={before['cursor']}", headers=account("maya")).json["changes"]
    assert [r["id"] for r in changes["receipts"]] == [env.id("receipt")]
    listing = env.client.get("/v1/groups", headers=account("maya")).json["groups"][0]
    assert listing["openReceipts"] == 1 and listing["receiptsNeedingYou"] == 1


def test_only_selected_members_can_claim_or_change_it(env: Env) -> None:
    _riley, maya, _dev = _group(env)
    _post(env, [maya])
    revision = _receipt_view(env, "maya")["revision"]
    stranger = _act(env, "dev", "claim", {"itemId": env.id("fries"), "request": "mine"}, revision=revision)
    assert stranger.status_code == 403 and stranger.json["error"]["code"] == "not_a_participant"
    assert (
        env.client.get(f"/v1/groups/{env.id('group')}/receipts/{env.id('receipt')}", headers=account("dev")).json["receipt"]["room"] is None
    )
    host_only = _act(env, "maya", "resolveDispute", {"disputeId": str(uuid.uuid4()), "status": "resolved"})
    assert host_only.status_code == 403 and host_only.json["error"]["code"] == "host_only"
    outsider = env.client.get(f"/v1/groups/{env.id('group')}/receipts/{env.id('receipt')}", headers=account("eve"))
    assert outsider.status_code == 404
    unverified = env.client.get(f"/v1/groups/{env.id('group')}", headers={"Authorization": "Bearer unverified-maya"})
    assert unverified.status_code == 403 and unverified.json["error"]["code"] == "email_not_verified"


def test_members_claim_asynchronously_and_stale_changes_come_back_with_the_latest(env: Env) -> None:
    _riley, maya, dev = _group(env)
    _post(env, [maya, dev])
    start = _receipt_view(env, "maya")["revision"]
    assert _act(env, "maya", "claimUnits", {"itemId": env.id("beer"), "units": 2}, revision=start).status_code == 200
    stale = _act(env, "dev", "claim", {"itemId": env.id("fries"), "request": "mine"}, revision=start)
    assert stale.status_code == 409 and stale.json["error"]["code"] == "receipt_conflict"
    assert stale.json["room"]["revision"] == start + 1  # the receipt as it is now, for the person to retry
    assert _act(env, "dev", "claim", {"itemId": env.id("fries"), "request": "mine"}).status_code == 200
    assert _act(env, "dev", "claimUnits", {"itemId": env.id("beer"), "units": 1}).status_code == 200
    view = _receipt_view(env, "riley")["room"]
    assert view["allocation"]["isComplete"] is True and set(view["unreviewed"]) == {maya, dev}


def test_finalizing_creates_exactly_one_expense_with_host_resolved_shares(env: Env) -> None:
    riley, maya, dev = _group(env)
    _post(env, [maya, dev])
    _act(env, "maya", "claimUnits", {"itemId": env.id("beer"), "units": 2})
    _act(env, "dev", "claimUnits", {"itemId": env.id("beer"), "units": 1})
    _act(env, "dev", "claim", {"itemId": env.id("fries"), "request": "mine"})
    _act(env, "maya", "markReviewed", {})
    assert _act(env, "riley", "transition", {"move": "requestFinalReview"}).status_code == 200
    revision = _receipt_view(env, "riley")["revision"]

    def finalize(
        who: str = "riley", acknowledge: list[str] | None = None, key: str | None = None, group_revision: int | None = None
    ) -> Any:
        payload = {"receiptId": env.id("receipt"), "expectedRevision": revision, "acknowledgeUnreviewed": acknowledge or []}
        return group_command(env, who, "finalizeReceipt", payload, key=key, revision=group_revision)

    assert finalize("maya", [dev]).status_code == 403
    refused = finalize()
    assert refused.status_code == 409 and refused.json["error"]["code"] == "unreviewed_shares"
    assert refused.json["error"]["participantIds"] == [dev] and refused.json["room"]["state"] == "readyToFinalize"
    key = uuid.uuid4().hex
    group_revision = snapshot(env, "riley")["revision"]
    first = finalize(acknowledge=[dev], key=key, group_revision=group_revision)
    assert first.status_code == 200, first.json
    assert first.json["result"]["expenseId"] == env.id("receipt")
    replay = finalize(acknowledge=[dev], key=key, group_revision=group_revision)  # the same request again
    second = finalize(acknowledge=[dev])  # a new request from another device
    assert replay.json["replayed"] is True and second.json["applied"] is False
    group = snapshot(env, "maya")
    receipts = [e for e in group["expenses"] if e["id"] == env.id("receipt")]
    assert len(receipts) == 1
    expense_record = receipts[0]
    assert expense_record["splitMethod"] == "itemized" and expense_record["payments"] == [{"memberId": riley, "amount": 3000}]
    assert {a["memberId"]: a["amount"] for a in expense_record["allocations"]} == {maya: 1333, dev: 1667}
    assert expense_record["receipt"]["hostResolved"] == [dev]
    nets = group["balances"]["confirmedNets"]
    assert nets[riley] == 3000 and nets[maya] == -1333 and nets[dev] == -1667
    assert next(r for r in group["receipts"] if r["id"] == env.id("receipt"))["state"] == "finalized"


def test_cancelling_creates_no_expense(env: Env) -> None:
    _riley, maya, _dev = _group(env)
    _post(env, [maya])
    before = snapshot(env, "riley")
    assert group_command(env, "maya", "cancelReceipt", {"receiptId": env.id("receipt")}).status_code == 403
    assert group_command(env, "riley", "cancelReceipt", {"receiptId": env.id("receipt")}).status_code == 200
    after = snapshot(env, "riley")
    assert after["expenses"] == before["expenses"] and after["balances"] == before["balances"]
    assert next(r for r in after["receipts"] if r["id"] == env.id("receipt"))["state"] == "cancelled"
    assert _act(env, "maya", "claim", {"itemId": env.id("fries"), "request": "mine"}).status_code == 409


def test_a_late_joiner_is_not_added_to_an_earlier_receipt(env: Env) -> None:
    _riley, maya, dev = _group(env)
    _post(env, [maya, dev])
    priya_snapshot = join(env, "priya")
    priya = priya_snapshot["viewer"]["memberId"]
    mine = next(r for r in priya_snapshot["receipts"] if r["id"] == env.id("receipt"))
    assert priya not in mine["participantIds"] and mine["room"] is None
    refused = _act(env, "priya", "claim", {"itemId": env.id("fries"), "request": "mine"}, revision=1)
    assert refused.status_code == 403


def test_members_on_an_open_receipt_cant_leave_or_be_removed(env: Env) -> None:
    _riley, maya, _dev = _group(env)
    _post(env, [maya])
    left = group_command(env, "maya", "leaveGroup", {})
    assert left.status_code == 409 and left.json["error"]["code"] == "member_has_open_receipt"
    removed = group_command(env, "riley", "removeMember", {"memberId": maya})
    assert removed.status_code == 409 and removed.json["error"]["code"] == "member_has_open_receipt"
    assert group_command(env, "dev", "leaveGroup", {}).status_code == 200  # not on the receipt
    archived = group_command(env, "riley", "archiveGroup", {})
    assert archived.status_code == 409 and archived.json["error"]["code"] == "group_has_open_receipts"


def test_existing_group_features_still_work_next_to_receipts(env: Env) -> None:
    riley, maya, dev = _group(env)
    _post(env, [maya])
    added = add_expense(env, "maya", expense(maya, 900, [(riley, 300), (maya, 300), (dev, 300)]))
    assert added.status_code == 200
    assert snapshot(env, "riley")["balances"]["confirmedNets"][maya] == 600
    record = env.store.get(GROUP_RECEIPT, f"{env.id('group')}:{env.id('receipt')}")
    assert record is not None and record["kind"] == "groupReceipt" and record["groupId"] == env.id("group")
    # A group receipt is never reachable through room routes, invitations, or guest credentials.
    assert env.client.get(f"{ROOM_ROUTE}/{env.id('receipt')}", headers=account("riley")).status_code == 404
    assert env.client.post(f"{ROOM_ROUTE}/{env.id('receipt')}/invitations", json={}, headers=account("riley")).status_code == 404
