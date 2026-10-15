"""Shared P2P groups (milestone 7): accounts, groups, expenses, sync, and authorization.

Runs against the in-memory store, and against the Datastore emulator with
``SQUAREUP_TEST_STORE=datastore`` (see ``scripts/check.sh``).
"""

from __future__ import annotations

import json
import uuid

from .conftest import Env
from .group_kit import (
    accept,
    account,
    add_expense,
    anonymous,
    command,
    create_group,
    expense,
    invite,
    join,
    member_id,
    profile,
    snapshot,
    two_person_group,
)

# MARK: - Accounts and profiles


def test_shared_groups_need_a_recoverable_account(env: Env) -> None:
    for headers in ({}, anonymous("drifter"), {"Authorization": "Bearer forged"}):
        response = env.client.post("/v1/groups", json={"groupId": env.id("group"), "name": "Trip", "currency": "USD"}, headers=headers)
        assert response.status_code in (401, 403)
    response = env.client.put("/v1/account/profile", json={"displayName": "Drifter"}, headers=anonymous("drifter"))
    assert response.json["error"]["code"] == "account_required"
    # The account endpoint still answers for an anonymous account so the app can explain why.
    status = env.client.get("/v1/account", headers=anonymous("drifter")).json["account"]
    assert status == {"recoverable": False, "emailVerified": False, "phoneVerified": False, "verified": False, "profile": None}


def test_profile_is_created_once_and_keeps_its_member_id(env: Env) -> None:
    first = profile(env, "riley", "Riley Park")
    second = profile(env, "riley", "Riley P.")
    assert first["memberId"] == second["memberId"] and second["displayName"] == "Riley P."
    assert env.client.get("/v1/account", headers=account("riley")).json["account"]["profile"]["displayName"] == "Riley P."


def test_creating_a_group_needs_a_profile_first(env: Env) -> None:
    response = env.client.post(
        "/v1/groups", json={"groupId": env.id("group"), "name": "Trip", "currency": "USD"}, headers=account("nobody")
    )
    assert response.json["error"]["code"] == "profile_required"


def test_destinations_are_validated_and_one_is_preferred(env: Env) -> None:
    profile(env, "riley")
    venmo, paypal = str(uuid.uuid4()), str(uuid.uuid4())
    saved = env.client.put(
        f"/v1/account/destinations/{venmo}",
        json={"provider": "venmo", "value": {"kind": "username", "value": "riley-park"}},
        headers=account("riley"),
    ).json["profile"]["destinations"]
    assert saved[0]["isPreferred"] is True, "the first enabled method is preferred automatically"
    saved = env.client.put(
        f"/v1/account/destinations/{paypal}",
        json={"provider": "paypal", "value": {"kind": "username", "value": "rileypark"}, "isPreferred": True},
        headers=account("riley"),
    ).json["profile"]["destinations"]
    assert [d["isPreferred"] for d in saved] == [False, True]
    for bad in (
        {"provider": "venmo", "value": {"kind": "username", "value": "x"}},
        {"provider": "appleCash", "value": {"kind": "phone", "value": "5305550142"}},
        {"provider": "cashApp", "value": {"kind": "link", "value": "javascript:alert(1)"}},
        {"provider": "cashApp", "value": {"kind": "link", "value": "https://evil.example/$maya"}},
        {"provider": "zelle", "value": {"kind": "email", "value": "maya@example.com"}, "link": "http://zelle.com/x"},
        {"provider": "other", "value": {"kind": "instructions", "value": "Ask me"}},
    ):
        response = env.client.put(f"/v1/account/destinations/{uuid.uuid4()}", json=bad, headers=account("riley"))
        assert response.json["error"]["code"] == "invalid_destination", bad
    deleted = env.client.delete(f"/v1/account/destinations/{paypal}", headers=account("riley")).json["profile"]["destinations"]
    assert [d["id"] for d in deleted] == [venmo] and deleted[0]["isPreferred"] is True


# MARK: - Creating and reading


def test_create_is_idempotent_and_only_members_can_read(env: Env) -> None:
    first = create_group(env, "riley")
    again = create_group(env, "riley")
    assert first["group"]["id"] == again["group"]["id"] and again["revision"] == 1
    assert first["viewer"]["isOwner"] is True and [e["kind"] for e in first["events"]] == ["groupCreated"]
    profile(env, "stranger")
    response = env.client.get(f"/v1/groups/{env.id('group')}", headers=account("stranger"))
    assert response.status_code == 404 and response.json["error"]["code"] == "group_not_found"
    # Someone else can't take over a group ID.
    taken = env.client.post("/v1/groups", json={"groupId": env.id("group"), "name": "Mine", "currency": "USD"}, headers=account("stranger"))
    assert taken.json["error"]["code"] == "entity_exists"


def test_snapshots_never_contain_account_ids(env: Env) -> None:
    two_person_group(env)
    text = json.dumps(snapshot(env, "maya"))
    assert "riley" not in text.replace("Riley", "") and '"uid"' not in text and "maya" not in text.replace("Maya", "")


def test_listing_groups_shows_only_active_memberships(env: Env) -> None:
    two_person_group(env)
    listed = env.client.get("/v1/groups", headers=account("maya")).json["groups"]
    assert [entry["group"]["name"] for entry in listed] == ["Coastal Weekend"] and listed[0]["viewer"]["isOwner"] is False
    profile(env, "stranger")
    assert env.client.get("/v1/groups", headers=account("stranger")).json["groups"] == []


# MARK: - Invitations


def test_invitation_preview_is_safe_and_acceptance_is_single_use(env: Env) -> None:
    create_group(env, "riley")
    add = add_expense(
        env, "riley", expense(snapshot(env, "riley")["viewer"]["memberId"], 4200, [(snapshot(env, "riley")["viewer"]["memberId"], 4200)])
    )
    assert add.status_code == 200, add.json
    invitation = invite(env)
    assert invitation["url"] == f"https://squareup.example/g/{invitation['code'].replace('-', '')}"
    assert invitation["appUrl"].startswith("squp://join-group/") and len(invitation["code"]) == 24
    preview = env.client.get(f"/v1/group-invitations/{invitation['code']}").json["invitation"]
    assert set(preview) == {
        "groupName",
        "symbol",
        "currency",
        "inviterName",
        "ownerName",
        "memberCount",
        "expiresAt",
        "isSeatInvitation",
        "alreadyMember",
    }
    assert "4200" not in json.dumps(preview) and preview["inviterName"] == "Riley" and preview["memberCount"] == 1
    joined = accept(env, invitation["code"].lower().replace("-", ""), "maya")
    assert joined.status_code == 201 and joined.json["snapshot"]["viewer"]["isOwner"] is False
    again = accept(env, invitation["code"], "maya")
    assert again.status_code == 200 and again.json["joined"] is False, "accepting again is idempotent for the same account"
    stolen = accept(env, invitation["code"], "mallory")
    assert stolen.status_code == 409 and stolen.json["error"]["code"] == "invitation_used"
    assert env.client.get(f"/v1/groups/{env.id('group')}", headers=account("mallory")).status_code == 404


def test_invitation_expiry_revocation_and_malformed_codes(env: Env) -> None:
    create_group(env, "riley")
    expiring = invite(env, expiresInHours=1)
    env.clock.advance(hours=2)
    assert accept(env, expiring["code"], "maya").json["error"]["code"] == "invitation_expired"
    revoked = invite(env)
    response = env.client.delete(f"/v1/groups/{env.id('group')}/invitations/{revoked['invitationId']}", headers=account("riley"))
    assert response.json["invitation"]["revokedAt"] is not None
    assert env.client.get(f"/v1/group-invitations/{revoked['code']}").json["error"]["code"] == "invitation_revoked"
    for bad in ("short", "0" * 20, "!" * 24):
        assert env.client.get(f"/v1/group-invitations/{bad}").json["error"]["code"] == "invitation_invalid"
    listed = env.client.get(f"/v1/groups/{env.id('group')}/invitations", headers=account("riley")).json["invitations"]
    assert len(listed) == 2 and all("code" not in entry for entry in listed)


def test_only_the_owner_invites(env: Env) -> None:
    two_person_group(env)
    response = env.client.post(f"/v1/groups/{env.id('group')}/invitations", json={}, headers=account("maya"))
    assert response.json["error"]["code"] == "owner_only"


def test_already_a_member_and_archived_states(env: Env) -> None:
    two_person_group(env)
    second = invite(env)
    assert accept(env, second["code"], "maya").json["error"]["code"] == "already_member"
    preview = env.client.get(f"/v1/group-invitations/{second['code']}", headers=account("maya")).json["invitation"]
    assert preview["alreadyMember"] is True
    archived = command(env, "riley", "archiveGroup", {})
    assert archived.status_code == 200, archived.json
    assert env.client.get(f"/v1/group-invitations/{second['code']}").json["error"]["code"] == "invitation_revoked"
    blocked = add_expense(
        env, "maya", expense(member_id(snapshot(env, "maya"), "Maya"), 100, [(member_id(snapshot(env, "maya"), "Maya"), 100)])
    )
    assert blocked.json["error"]["code"] == "group_archived"


# MARK: - Expenses


def test_every_split_is_revalidated_by_the_server(env: Env) -> None:
    riley, maya = two_person_group(env)
    equal = add_expense(env, "riley", expense(riley, 1001, [(riley, 501), (maya, 500)], method="equal"))
    assert equal.status_code == 200, equal.json
    wrong_equal = add_expense(env, "riley", expense(riley, 1001, [(riley, 500), (maya, 501)], method="equal"))
    assert wrong_equal.json["error"]["code"] == "invalid_split", "the remainder cent goes to the first person"
    shares = expense(riley, 900, [(riley, 600), (maya, 300)], method="shares")
    assert add_expense(env, "riley", shares).json["error"]["code"] == "invalid_split", "shares must say how they were divided"
    ok = add_expense(
        env, "riley", shares, {"method": "shares", "weights": [{"memberId": riley, "weight": 2}, {"memberId": maya, "weight": 1}]}
    )
    assert ok.status_code == 200, ok.json
    percent = expense(riley, 1000, [(riley, 333), (maya, 667)], method="percentage")
    split = {"method": "percentage", "percentages": [{"memberId": riley, "percent": "33.3"}, {"memberId": maya, "percent": "66.7"}]}
    assert add_expense(env, "riley", percent, split).status_code == 200
    bad_percent = {"method": "percentage", "percentages": [{"memberId": riley, "percent": "33"}, {"memberId": maya, "percent": "66"}]}
    assert (
        add_expense(env, "riley", expense(riley, 1000, [(riley, 330), (maya, 670)], method="percentage"), bad_percent).json["error"]["code"]
        == "invalid_split"
    )
    two_payers = expense([(riley, 1000), (maya, 800)], 1800, [(riley, 900), (maya, 900)], method="equal")
    assert add_expense(env, "maya", two_payers).status_code == 200
    unbalanced = expense([(riley, 1000), (maya, 700)], 1800, [(riley, 900), (maya, 900)])
    assert add_expense(env, "maya", unbalanced).json["error"]["reason"] == "paymentsDoNotReconcile"
    short = expense(riley, 1800, [(riley, 900), (maya, 800)])
    assert add_expense(env, "maya", short).json["error"]["reason"] == "allocationsDoNotReconcile"
    stranger = expense(riley, 100, [(str(uuid.uuid4()), 100)])
    assert add_expense(env, "maya", stranger).json["error"]["reason"] == "participantNotInGroup"
    tiny = add_expense(env, "riley", expense(riley, 1, [(riley, 1)], method="equal"), {"method": "equal", "participants": [riley, maya]})
    assert tiny.status_code == 200, "a zero share (1¢ split two ways) is left out, as the app does"
    euros = {**expense(riley, 100, [(riley, 100)]), "currency": "EUR"}
    assert add_expense(env, "maya", euros).json["error"]["code"] == "currency_mismatch"


def test_balances_are_derived_on_the_server(env: Env) -> None:
    riley, maya = two_person_group(env)
    add_expense(env, "riley", expense(riley, 6000, [(riley, 3000), (maya, 3000)], method="equal"))
    balances = snapshot(env, "maya")["balances"]
    assert balances["confirmedNets"] == {riley: 3000, maya: -3000}
    assert balances["payments"] == [{"payerId": maya, "recipientId": riley, "amount": 3000}]


def test_edits_are_revisions_and_only_the_creator_can_edit(env: Env) -> None:
    riley, maya = two_person_group(env)
    body = expense(riley, 4000, [(riley, 2000), (maya, 2000)], method="equal")
    add_expense(env, "riley", body)
    edited = {**body, "total": 5000, "allocations": [{"memberId": riley, "amount": 2500}, {"memberId": maya, "amount": 2500}]}
    edited["payments"] = [{"memberId": riley, "amount": 5000}]
    other = command(env, "maya", "updateExpense", {"expenseId": body["id"], "expense": edited})
    assert other.json["error"]["code"] == "forbidden"
    response = command(env, "riley", "updateExpense", {"expenseId": body["id"], "expense": edited, "expectedExpenseRevision": 1})
    assert response.status_code == 200, response.json
    snap = snapshot(env, "maya")
    stored = next(e for e in snap["expenses"] if e["id"] == body["id"])
    assert stored["revision"] == 2 and stored["total"] == 5000
    event = snap["events"][-1]
    assert (
        event["kind"] == "expenseEdited"
        and event["data"]["previous"]["total"] == 4000
        and event["data"]["fields"] == ["amount", "payers", "split"]
    )
    stale = command(env, "riley", "updateExpense", {"expenseId": body["id"], "expense": body, "expectedExpenseRevision": 1})
    assert stale.status_code == 409 and stale.json["error"]["code"] == "expense_conflict" and stale.json["error"]["currentRevision"] == 2
    revisions = env.client.get(f"/v1/groups/{env.id('group')}/expenses/{body['id']}/revisions", headers=account("maya")).json["revisions"]
    assert [r["total"] for r in revisions] == [4000, 5000]


def test_delete_and_restore_follow_the_engine_rules_and_are_recorded(env: Env) -> None:
    riley, maya = two_person_group(env)
    body = expense(riley, 1000, [(riley, 500), (maya, 500)], method="equal")
    add_expense(env, "riley", body)
    assert command(env, "riley", "deleteExpense", {"expenseId": body["id"]}).status_code == 200
    assert command(env, "riley", "deleteExpense", {"expenseId": body["id"]}).json["error"]["code"] == "expense_deleted"
    assert snapshot(env, "riley")["balances"]["confirmedNets"][riley] == 0
    assert command(env, "riley", "restoreExpense", {"expenseId": body["id"]}).status_code == 200
    assert command(env, "riley", "restoreExpense", {"expenseId": body["id"]}).json["error"]["code"] == "expense_not_deleted"
    kinds = [event["kind"] for event in snapshot(env, "riley")["events"]]
    assert kinds.count("expenseDeleted") == 1 and kinds.count("expenseRestored") == 1


def test_pending_seats_can_share_expenses_but_not_act(env: Env) -> None:
    create_group(env, "riley")
    riley = snapshot(env, "riley")["viewer"]["memberId"]
    dev = str(uuid.uuid4())
    assert command(env, "riley", "addSeat", {"memberId": dev, "displayName": "Dev"}).status_code == 200
    seats = {m["displayName"]: m["status"] for m in snapshot(env, "riley")["members"]}
    assert seats == {"Riley": "active", "Dev": "pending"}
    assert add_expense(env, "riley", expense(riley, 1000, [(riley, 500), (dev, 500)], method="equal")).status_code == 200
    start = command(env, "riley", "startPayment", {"attemptId": str(uuid.uuid4()), "recipientId": dev, "amount": 100, "provider": "cash"})
    assert start.json["error"]["code"] in ("recipient_not_joined", "no_obligation")


# MARK: - Idempotency, revisions, and changes


def test_retries_replay_and_reused_keys_are_refused(env: Env) -> None:
    riley, maya = two_person_group(env)
    body = expense(riley, 1000, [(riley, 500), (maya, 500)], method="equal")
    revision = snapshot(env, "riley")["revision"]
    # A retry resends the identical envelope (same key, same expected revision).
    first = add_expense(env, "riley", body, key="retry-key-0001", revision=revision)
    second = add_expense(env, "riley", body, key="retry-key-0001", revision=revision)
    assert first.json["applied"] is True and second.json["replayed"] is True and second.json["revision"] == first.json["revision"]
    assert len(snapshot(env, "riley")["expenses"]) == 1
    different = add_expense(
        env, "riley", expense(riley, 2000, [(riley, 1000), (maya, 1000)], method="equal"), key="retry-key-0001", revision=revision
    )
    assert different.status_code == 422 and different.json["error"]["code"] == "idempotency_key_reused"


def test_revision_strict_commands_refuse_stale_revisions(env: Env) -> None:
    two_person_group(env)
    stale = command(env, "riley", "updateGroup", {"name": "Renamed", "symbol": "car.fill", "currency": "USD"}, revision=1)
    assert stale.status_code == 409 and stale.json["error"]["code"] == "revision_conflict"
    assert stale.json["error"]["currentRevision"] == snapshot(env, "riley")["revision"] and "cursor" in stale.json["error"]
    assert command(env, "riley", "updateGroup", {"name": "Renamed", "symbol": "car.fill", "currency": "USD"}).status_code == 200
    assert (
        command(env, "maya", "updateGroup", {"name": "Mine", "symbol": "car.fill", "currency": "USD"}).json["error"]["code"] == "owner_only"
    )


def test_changes_after_a_cursor_carry_only_what_changed(env: Env) -> None:
    riley, maya = two_person_group(env)
    cursor = snapshot(env, "maya")["cursor"]
    first = expense(riley, 1000, [(riley, 500), (maya, 500)], method="equal", title="Gas")
    add_expense(env, "riley", first)
    add_expense(env, "riley", expense(riley, 600, [(riley, 300), (maya, 300)], method="equal", title="Parking"))
    page = env.client.get(f"/v1/groups/{env.id('group')}/changes?after={cursor}", headers=account("maya")).json["changes"]
    assert page["cursorExpired"] is False and [e["kind"] for e in page["events"]] == ["expenseCreated", "expenseCreated"]
    assert sorted(e["title"] for e in page["expenses"]) == ["Gas", "Parking"] and page["cursor"] == cursor + 2
    assert page["balances"]["confirmedNets"][maya] == -800
    nothing = env.client.get(f"/v1/groups/{env.id('group')}/changes?after={page['cursor']}", headers=account("maya")).json["changes"]
    assert nothing["events"] == [] and nothing["expenses"] == []
    future = env.client.get(f"/v1/groups/{env.id('group')}/changes?after=999", headers=account("maya")).json["changes"]
    assert future["cursorExpired"] is True and "expenses" not in future
    for bad in ("-1", "abc", ""):
        assert env.client.get(f"/v1/groups/{env.id('group')}/changes?after={bad}", headers=account("maya")).status_code == 400
    with_changes = add_expense(env, "maya", expense(maya, 200, [(maya, 100), (riley, 100)], method="equal"), known_cursor=page["cursor"])
    assert [e["kind"] for e in with_changes.json["changes"]["events"]] == ["expenseCreated"]


def test_a_cursor_too_far_behind_requires_a_snapshot(env: Env) -> None:
    riley, maya = two_person_group(env)
    for index in range(301):
        if index % 100 == 0:
            env.clock.advance(minutes=1)  # stay under the per-minute command limit
        response = add_expense(env, "riley", expense(riley, 2, [(riley, 1), (maya, 1)], method="equal", title=f"Item {index}"))
        assert response.status_code == 200
    page = env.client.get(f"/v1/groups/{env.id('group')}/changes?after=1", headers=account("maya")).json["changes"]
    assert page["cursorExpired"] is True
    full = snapshot(env, "maya")
    assert len(full["events"]) == full["cursor"] and full["eventsComplete"] is True


# MARK: - Membership


def test_member_removal_safety_and_access_after_removal(env: Env) -> None:
    riley, maya = two_person_group(env)
    body = expense(riley, 1000, [(riley, 500), (maya, 500)], method="equal")
    add_expense(env, "riley", body)
    refused = command(env, "riley", "removeMember", {"memberId": maya})
    assert refused.json["error"]["code"] == "member_has_balance"
    assert command(env, "maya", "leaveGroup", {}).json["error"]["code"] == "member_has_balance"
    assert command(env, "riley", "leaveGroup", {}).json["error"]["code"] == "owner_must_transfer"
    command(env, "riley", "deleteExpense", {"expenseId": body["id"]})
    removed = command(env, "riley", "removeMember", {"memberId": maya})
    assert removed.status_code == 200, removed.json
    gone = env.client.get(f"/v1/groups/{env.id('group')}", headers=account("maya"))
    assert gone.status_code == 403 and gone.json["error"]["code"] == "not_a_member"
    assert env.client.get("/v1/groups", headers=account("maya")).json["groups"] == []
    # History keeps the removed person's identity.
    assert {m["displayName"]: m["status"] for m in snapshot(env, "riley")["members"]}["Maya"] == "removed"


def test_transferring_ownership_revokes_the_old_owners_invitations(env: Env) -> None:
    _, maya = two_person_group(env)
    pending = invite(env)
    transferred = command(env, "riley", "transferOwnership", {"memberId": maya})
    assert transferred.status_code == 200, transferred.json
    assert snapshot(env, "maya")["viewer"]["isOwner"] is True
    assert env.client.get(f"/v1/group-invitations/{pending['code']}").json["error"]["code"] == "invitation_revoked"
    assert command(env, "riley", "leaveGroup", {}).status_code == 200


# MARK: - Payments


def _owing_group(env: Env) -> tuple[str, str, dict[str, str]]:
    riley, maya = two_person_group(env)
    venmo = str(uuid.uuid4())
    env.client.put(
        f"/v1/account/destinations/{venmo}",
        json={"provider": "venmo", "value": {"kind": "username", "value": "riley-park"}},
        headers=account("riley"),
    )
    add_expense(env, "riley", expense(riley, 6000, [(riley, 3000), (maya, 3000)], method="equal"))
    return riley, maya, {"venmo": venmo}


def test_destinations_are_revealed_only_to_someone_who_owes(env: Env) -> None:
    riley, maya, _ = _owing_group(env)
    members = {m["displayName"]: m for m in snapshot(env, "maya")["members"]}
    assert members["Riley"]["destinationProviders"] == ["venmo"]
    assert "riley-park" not in json.dumps(snapshot(env, "maya"))
    revealed = env.client.get(f"/v1/groups/{env.id('group')}/members/{riley}/destinations", headers=account("maya"))
    assert revealed.status_code == 200 and revealed.json["destinations"][0]["value"]["value"] == "riley-park"
    assert revealed.headers["Cache-Control"] == "private, no-store"
    refused = env.client.get(f"/v1/groups/{env.id('group')}/members/{maya}/destinations", headers=account("riley"))
    assert refused.status_code == 403 and refused.json["error"]["code"] == "reveal_not_allowed"
    profile(env, "stranger")
    outsider = env.client.get(f"/v1/groups/{env.id('group')}/members/{riley}/destinations", headers=account("stranger"))
    assert outsider.status_code == 404


def test_report_then_confirm_creates_exactly_one_settlement(env: Env) -> None:
    riley, maya, destinations = _owing_group(env)
    attempt = str(uuid.uuid4())
    too_much = command(
        env,
        "maya",
        "startPayment",
        {"attemptId": attempt, "recipientId": riley, "amount": 3001, "provider": "venmo", "destinationId": destinations["venmo"]},
    )
    assert too_much.json["error"]["code"] == "exceeds_obligation" and too_much.json["error"]["owed"] == 3000
    wrong_method = command(
        env,
        "maya",
        "startPayment",
        {"attemptId": attempt, "recipientId": riley, "amount": 3000, "provider": "paypal", "destinationId": destinations["venmo"]},
    )
    assert wrong_method.json["error"]["code"] == "destination_unavailable"
    started = command(
        env,
        "maya",
        "startPayment",
        {"attemptId": attempt, "recipientId": riley, "amount": 3000, "provider": "venmo", "destinationId": destinations["venmo"]},
    )
    assert started.status_code == 200, started.json
    assert command(env, "maya", "advancePayment", {"attemptId": attempt, "action": "openHandoff"}).status_code == 200
    assert snapshot(env, "riley")["balances"]["confirmedNets"][riley] == 3000, "opening a payment app proves nothing"
    assert (
        command(env, "riley", "advancePayment", {"attemptId": attempt, "action": "confirm"}).json["error"]["code"] == "not_allowed_in_state"
    )
    reported = command(env, "maya", "advancePayment", {"attemptId": attempt, "action": "reportSent"})
    assert reported.status_code == 200
    snap = snapshot(env, "riley")
    assert (
        snap["balances"]["confirmedNets"][riley] == 3000
        and snap["balances"]["payments"] == []
        and snap["balances"]["pendingAttemptIds"] == [attempt]
    )
    assert command(env, "maya", "advancePayment", {"attemptId": attempt, "action": "confirm"}).json["error"]["code"] == "forbidden"
    revision = snapshot(env, "riley")["revision"]
    for _ in range(2):
        confirmed = command(
            env, "riley", "advancePayment", {"attemptId": attempt, "action": "confirm"}, key="confirm-key-1", revision=revision
        )
        assert confirmed.status_code == 200
    again = command(env, "riley", "advancePayment", {"attemptId": attempt, "action": "confirm"})
    assert again.json["applied"] is False and again.json["result"]["settlementId"] == attempt
    snap = snapshot(env, "maya")
    assert len(snap["settlements"]) == 1 and snap["settlements"][0]["attemptId"] == attempt
    assert snap["balances"]["confirmedNets"] == {riley: 0, maya: 0}
    kinds = [event["kind"] for event in snap["events"]]
    assert kinds.count("paymentConfirmed") == 1 and kinds.count("paymentReported") == 1


def test_rejection_makes_the_obligation_payable_again_and_dispute_keeps_it_reserved(env: Env) -> None:
    riley, maya, _ = _owing_group(env)
    first = str(uuid.uuid4())
    command(env, "maya", "startPayment", {"attemptId": first, "recipientId": riley, "amount": 3000, "provider": "cash"})
    command(env, "maya", "advancePayment", {"attemptId": first, "action": "reportSent"})
    rejected = command(env, "riley", "advancePayment", {"attemptId": first, "action": "reject", "reason": "Nothing arrived"})
    assert rejected.status_code == 200
    assert snapshot(env, "maya")["balances"]["payments"] == [{"payerId": maya, "recipientId": riley, "amount": 3000}]
    second = str(uuid.uuid4())
    command(env, "maya", "startPayment", {"attemptId": second, "recipientId": riley, "amount": 3000, "provider": "cash"})
    command(env, "maya", "advancePayment", {"attemptId": second, "action": "reportSent"})
    assert command(env, "maya", "advancePayment", {"attemptId": second, "action": "dispute", "reason": "I sent it"}).status_code == 200
    assert snapshot(env, "maya")["balances"]["payments"] == [], "a disputed payment stays reserved"
    # Notes are visible only to the two people in the payment.
    command(env, "riley", "addSeat", {"memberId": str(uuid.uuid4()), "displayName": "Dev"})
    join(env, "priya")
    for attempt in snapshot(env, "priya")["attempts"]:
        assert all(entry["note"] is None for entry in attempt["history"])
    notes = [entry["note"] for entry in next(a for a in snapshot(env, "maya")["attempts"] if a["id"] == first)["history"]]
    assert "Nothing arrived" in notes


def test_a_pending_payment_blocks_edits_that_would_change_it(env: Env) -> None:
    riley, maya, _ = _owing_group(env)
    body = expense(riley, 1000, [(riley, 500), (maya, 500)], method="equal")
    add_expense(env, "riley", body)
    attempt = str(uuid.uuid4())
    command(env, "maya", "startPayment", {"attemptId": attempt, "recipientId": riley, "amount": 3500, "provider": "cash"})
    command(env, "maya", "advancePayment", {"attemptId": attempt, "action": "reportSent"})
    conflict = command(env, "riley", "deleteExpense", {"expenseId": body["id"]})
    assert conflict.json["error"]["code"] == "pending_payment_conflict" and conflict.json["error"]["attemptIds"] == [attempt]


def test_only_the_payer_cancels_and_a_new_draft_supersedes_the_old(env: Env) -> None:
    riley, maya, _ = _owing_group(env)
    first, second = str(uuid.uuid4()), str(uuid.uuid4())
    command(env, "maya", "startPayment", {"attemptId": first, "recipientId": riley, "amount": 1000, "provider": "cash"})
    command(env, "maya", "startPayment", {"attemptId": second, "recipientId": riley, "amount": 1000, "provider": "cash"})
    states = {a["id"]: a["state"] for a in snapshot(env, "maya")["attempts"]}
    assert states == {first: "cancelled", second: "methodSelected"}
    assert command(env, "riley", "advancePayment", {"attemptId": second, "action": "cancel"}).json["error"]["code"] == "forbidden"
    assert command(env, "maya", "advancePayment", {"attemptId": second, "action": "cancel"}).status_code == 200
    assert (
        command(env, "riley", "startPayment", {"attemptId": str(uuid.uuid4()), "recipientId": maya, "amount": 1, "provider": "cash"}).json[
            "error"
        ]["code"]
        == "no_obligation"
    )


# MARK: - Privacy


def test_logs_never_contain_names_amounts_codes_or_destinations(env: Env, capsys: object) -> None:
    riley, maya, _ = _owing_group(env)
    invitation = invite(env)
    accept(env, invitation["code"], "priya", "Priya Natarajan")
    command(env, "maya", "startPayment", {"attemptId": str(uuid.uuid4()), "recipientId": riley, "amount": 2999, "provider": "cash"})
    output = capsys.readouterr().out  # type: ignore[attr-defined]
    for secret in (
        "Riley",
        "Maya",
        "Priya",
        "Natarajan",
        "riley-park",
        "2999",
        "6000",
        invitation["code"],
        invitation["code"].replace("-", ""),
        riley,
        maya,
    ):
        assert secret not in output, secret


def test_invitation_landing_page_reveals_nothing(env: Env) -> None:
    create_group(env, "riley", name="Secret Surprise Party")
    invitation = invite(env)
    code = invitation["code"].replace("-", "")
    page = env.client.get(f"/g/{code}")
    text = page.get_data(as_text=True)
    assert page.status_code == 200 and "Secret Surprise" not in text and "Riley" not in text
    assert f"squp://join-group/{code}" in text and invitation["code"] in text and "universal" not in text.lower()
    assert page.headers["Content-Security-Policy"].startswith("default-src 'none'")


def test_room_guest_credentials_never_open_group_apis(env: Env) -> None:
    from .conftest import invite as room_invite
    from .conftest import join as room_join
    from .conftest import publish as publish_room

    create_group(env, "riley")
    publish_room(env)
    guest = room_join(env, room_invite(env)["token"])
    headers = {"Authorization": f"Guest {guest['credential']}"}
    assert env.client.get(f"/v1/groups/{env.id('group')}", headers=headers).status_code in (401, 403)
    assert env.client.get("/v1/groups", headers=headers).status_code in (401, 403)


def test_invitation_acceptance_is_rate_limited(env: Env) -> None:
    create_group(env, "riley")
    profile(env, "mallory")
    codes = [f"{'A' * 19}{index}" for index in range(10)] + ["B" * 20]
    statuses = [env.client.post(f"/v1/group-invitations/{code}/accept", json={}, headers=account("mallory")).status_code for code in codes]
    assert statuses[-1] == 429 and set(statuses[:-1]) == {404}


def test_expired_group_invitations_are_cleaned_up(env: Env) -> None:
    create_group(env, "riley")
    invitation = invite(env, expiresInHours=1)
    env.clock.advance(days=9)
    removed = env.client.get("/tasks/cleanup").json["removed"]
    assert removed["groupInvitations"] == 1
    assert env.client.get(f"/v1/group-invitations/{invitation['code']}").json["error"]["code"] == "invitation_invalid"
