"""Multi-person shared groups: the 25-person limit, single-use invitations and their states, joining
concurrently, membership and ownership changes, and settling up among several people."""

from __future__ import annotations

import threading
import uuid
from typing import Any

import pytest

from squareup.storage.base import GROUP_INVITATION

from .conftest import Env
from .group_kit import (
    accept,
    account,
    add_expense,
    command,
    create_group,
    expense,
    invite,
    join,
    profile,
    snapshot,
)


def people(size: int) -> list[str]:
    """Everyone after the owner, Riley."""
    return [f"p{index:02d}" for index in range(1, size)]


def grow(env: Env, size: int) -> dict[str, str]:
    """Riley's group with ``size`` joined members. Returns each person's member ID."""
    ids = {"riley": create_group(env, "riley")["viewer"]["memberId"]}
    for who in people(size):
        ids[who] = join(env, who)["viewer"]["memberId"]
    return ids


def error(response: Any) -> str:
    return str(response.json["error"]["code"])


def invitations(env: Env, who: str = "riley") -> list[dict[str, Any]]:
    response = env.client.get(f"/v1/groups/{env.id('group')}/invitations", headers=account(who))
    assert response.status_code == 200, response.json
    result: list[dict[str, Any]] = response.json["invitations"]
    return result


def revoke(env: Env, invitation_id: str, who: str = "riley") -> Any:
    return env.client.delete(f"/v1/groups/{env.id('group')}/invitations/{invitation_id}", headers=account(who))


def active(snap: dict[str, Any]) -> list[str]:
    return [member["id"] for member in snap["members"] if member["status"] == "active"]


def pay(env: Env, payer: str, recipient_id: str, amount: int) -> str:
    """The payer reports a payment made outside Square Up (cash). Returns the attempt ID."""
    attempt = str(uuid.uuid4())
    started = command(env, payer, "startPayment", {"attemptId": attempt, "recipientId": recipient_id, "amount": amount, "provider": "cash"})
    assert started.status_code == 200, started.json
    reported = command(env, payer, "advancePayment", {"attemptId": attempt, "action": "reportSent"})
    assert reported.status_code == 200, reported.json
    return attempt


def confirm(env: Env, recipient: str, attempt: str) -> Any:
    return command(env, recipient, "advancePayment", {"attemptId": attempt, "action": "confirm"})


# MARK: - Verified accounts only


def test_unverified_anonymous_and_signed_out_callers_are_refused_on_every_group_route(env: Env) -> None:
    create_group(env, "riley")
    code = invite(env)["code"].replace("-", "")
    group = env.id("group")
    routes = [
        ("put", "/v1/account/profile", {"displayName": "Maya", "locale": "en_US"}),
        ("get", "/v1/groups", None),
        ("post", "/v1/groups", {"groupId": str(uuid.uuid4()), "name": "X", "symbol": "star", "currency": "USD"}),
        ("get", f"/v1/groups/{group}", None),
        ("get", f"/v1/groups/{group}/changes?after=0", None),
        ("post", f"/v1/groups/{group}/commands", {"type": "updateGroup", "payload": {}}),
        ("post", f"/v1/groups/{group}/invitations", {}),
        ("get", f"/v1/groups/{group}/invitations", None),
        ("delete", f"/v1/groups/{group}/invitations/{uuid.uuid4()}", None),
        ("post", f"/v1/group-invitations/{code}/accept", {}),
    ]
    callers = {
        "unverified": ({"Authorization": "Bearer unverified-riley"}, 403, "email_not_verified"),
        "anonymous": ({"Authorization": "Bearer anon-riley"}, 403, "account_required"),
        "signedOut": ({}, 401, "unauthenticated"),
    }
    for headers, status, code_name in callers.values():
        for method, path, body in routes:
            response = getattr(env.client, method)(path, json=body, headers=headers)
            assert (response.status_code, error(response)) == (status, code_name), (method, path, headers)
            assert "Coastal Weekend" not in response.get_data(as_text=True), "the owner's own unverified token reads nothing"
    assert snapshot(env, "riley")["revision"] >= 1, "the verified owner still reads the group"
    # The account status read stays open to any signed-in account, so the app can say what's missing.
    status = env.client.get("/v1/account", headers={"Authorization": "Bearer unverified-riley"}).json["account"]
    assert (status["recoverable"], status["emailVerified"], status["profile"]["displayName"]) == (True, False, "Riley")
    assert env.client.get("/v1/account", headers=account("riley")).json["account"]["emailVerified"] is True
    assert env.client.get("/v1/account").status_code == 401


# MARK: - Group size


@pytest.mark.parametrize("size", [1, 2, 3, 10, 25])
def test_groups_of_several_sizes_share_one_ledger(env: Env, size: int) -> None:
    ids = grow(env, size)
    owner = snapshot(env, "riley")
    assert len(active(owner)) == size and owner["group"]["ownerMemberId"] == ids["riley"]
    assert owner["group"]["currency"] == "USD"
    everyone = list(ids.values())
    share, remainder = divmod(100 * size + 7, size)
    allocations = [(member, share + (1 if index < remainder else 0)) for index, member in enumerate(everyone)]
    added = add_expense(env, "riley", expense(ids["riley"], 100 * size + 7, allocations, method="equal"))
    assert added.status_code == 200, added.json
    views = [snapshot(env, who) for who in ids]
    assert all(view["balances"] == views[0]["balances"] for view in views), "every member sees the same balances"
    assert sum(views[0]["balances"]["confirmedNets"].values()) == 0
    assert all(len(view["members"]) == size for view in views)
    for who in ids:
        listed = env.client.get("/v1/groups", headers=account(who)).json["groups"]
        assert [entry["group"]["id"] for entry in listed] == [env.id("group")], f"{who} sees exactly this group"
    if size < 25:
        assert invite(env)["status"] == "unused"
    else:
        full = env.client.post(f"/v1/groups/{env.id('group')}/invitations", json={}, headers=account("riley"))
        assert (full.status_code, error(full), full.json["error"]["limit"]) == (409, "group_full", 25)


def test_the_twenty_sixth_person_is_refused_and_the_invitation_stays_unused(env: Env) -> None:
    grow(env, 24)
    last, extra = invite(env), invite(env)
    assert accept(env, last["code"], "p24").status_code == 201
    refused = accept(env, extra["code"], "p25")
    assert (refused.status_code, error(refused)) == (409, "group_full")
    assert len(active(snapshot(env, "riley"))) == 25
    assert env.client.get("/v1/groups", headers=account("p25")).json["groups"] == []
    statuses = {item["invitationId"]: item["status"] for item in invitations(env)}
    assert statuses[extra["invitationId"]] == "unused", "nothing was consumed"
    # Someone leaves; the same invitation now works.
    p01 = snapshot(env, "p01")["viewer"]["memberId"]
    assert command(env, "p01", "leaveGroup", {}).status_code == 200
    assert accept(env, extra["code"], "p25").status_code == 201
    assert p01 not in active(snapshot(env, "riley"))


def test_a_person_belongs_to_several_groups_independently(env: Env) -> None:
    first = create_group(env, "riley", "Trip", groupId=str(uuid.uuid4()))["group"]["id"]
    second = create_group(env, "maya", "Rent", groupId=str(uuid.uuid4()))["group"]["id"]
    join(env, "sam", "riley", first)
    join(env, "sam", "maya", second)
    listed = {entry["group"]["id"] for entry in env.client.get("/v1/groups", headers=account("sam")).json["groups"]}
    assert listed == {first, second}
    assert env.client.get(f"/v1/groups/{second}", headers=account("riley")).status_code == 404, "Riley isn't in Maya's group"


# MARK: - Invitations


def test_several_single_use_invitations_and_their_states(env: Env) -> None:
    create_group(env, "riley")
    accepted, revoked, expiring, waiting = invite(env), invite(env), invite(env, expiresInHours=1), invite(env)
    codes = {accepted["code"], revoked["code"], expiring["code"], waiting["code"]}
    assert len(codes) == 4, "each invitation has its own code"
    assert all(item["url"].endswith(item["code"].replace("-", "")) for item in (accepted, waiting))
    maya = accept(env, accepted["code"], "maya").json["snapshot"]["viewer"]["memberId"]
    assert revoke(env, revoked["invitationId"]).json["invitation"]["status"] == "revoked"
    env.clock.advance(hours=2)
    listed = {item["invitationId"]: item for item in invitations(env)}
    assert {key: item["status"] for key, item in listed.items()} == {
        accepted["invitationId"]: "accepted",
        revoked["invitationId"]: "revoked",
        expiring["invitationId"]: "expired",
        waiting["invitationId"]: "unused",
    }
    assert listed[accepted["invitationId"]]["acceptedMemberId"] == maya
    assert all(item["createdByMemberId"] == snapshot(env, "riley")["viewer"]["memberId"] for item in listed.values())
    assert all("code" not in item and "hash" not in item and "url" not in item for item in listed.values()), "codes are shown once"
    assert error(revoke(env, accepted["invitationId"])) == "invitation_used", "an accepted invitation can't be revoked"
    assert error(accept(env, revoked["code"], "sam")) == "invitation_revoked"
    assert error(accept(env, expiring["code"], "sam")) == "invitation_expired"
    assert accept(env, waiting["code"], "sam").status_code == 201
    assert env.store.get(GROUP_INVITATION, waiting["code"]) is None, "only a digest of the code is stored"


def test_the_default_expiry_is_seven_days(env: Env) -> None:
    create_group(env, "riley")
    created = invite(env)
    env.clock.advance(days=6, hours=23)
    assert env.client.get(f"/v1/group-invitations/{created['code']}").status_code == 200
    env.clock.advance(hours=2)
    assert error(env.client.get(f"/v1/group-invitations/{created['code']}")) == "invitation_expired"


def test_malformed_codes_are_indistinguishable_from_unknown_ones(env: Env) -> None:
    create_group(env, "riley")
    profile(env, "sam")
    for code in ["", "x", "a" * 300, "ABCD-EFGH-JKLM", "%00", "../../etc"]:
        for method in ("get", "post"):
            path = f"/v1/group-invitations/{code}" + ("/accept" if method == "post" else "")
            response = getattr(env.client, method)(path, json={}, headers=account("sam"))
            assert response.status_code in (404, 405), (code, response.status_code)
            if response.status_code == 404 and response.is_json:
                assert error(response) in ("invitation_invalid", "not_found")


def test_concurrent_acceptances_of_one_invitation_create_one_membership(env: Env) -> None:
    create_group(env, "riley")
    created = invite(env)
    contenders = [f"c{index}" for index in range(6)]
    for who in contenders:
        profile(env, who)
    results: dict[str, int] = {}

    def attempt(who: str) -> None:
        response = env.client.post(f"/v1/group-invitations/{created['code']}/accept", json={}, headers=account(who))
        results[who] = response.status_code

    threads = [threading.Thread(target=attempt, args=(who,)) for who in contenders]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    winners = [who for who, status in results.items() if status == 201]
    assert len(winners) == 1, results
    assert sorted(status for status in results.values() if status != 201) == [409] * 5
    assert len(active(snapshot(env, "riley"))) == 2
    accepted = next(item for item in invitations(env) if item["invitationId"] == created["invitationId"])
    assert accepted["acceptedMemberId"] == snapshot(env, winners[0])["viewer"]["memberId"]


def test_the_same_account_accepting_repeatedly_joins_once(env: Env) -> None:
    create_group(env, "riley")
    created = invite(env)
    profile(env, "maya")
    statuses: list[int] = []

    def attempt() -> None:
        statuses.append(env.client.post(f"/v1/group-invitations/{created['code']}/accept", json={}, headers=account("maya")).status_code)

    threads = [threading.Thread(target=attempt) for _ in range(5)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    assert sorted(statuses) == [200, 200, 200, 200, 201], "one join; the rest open the group"
    members = snapshot(env, "riley")["members"]
    assert len(members) == 2 and sum(1 for event in snapshot(env, "riley")["events"] if event["kind"] == "memberJoined") == 1


def test_reopening_an_accepted_invitation_and_duplicate_membership(env: Env) -> None:
    create_group(env, "riley")
    first, second = invite(env), invite(env)
    joined = accept(env, first["code"], "maya")
    again = accept(env, first["code"], "maya")
    assert (again.status_code, again.json["joined"]) == (200, False)
    assert again.json["snapshot"]["viewer"]["memberId"] == joined.json["snapshot"]["viewer"]["memberId"]
    preview = env.client.get(f"/v1/group-invitations/{first['code']}", headers=account("maya")).json["invitation"]
    assert preview["alreadyMember"] is True
    assert error(accept(env, first["code"], "sam")) == "invitation_used", "someone else gets a clear error"
    assert error(env.client.get(f"/v1/group-invitations/{first['code']}", headers=account("sam"))) == "invitation_used"
    duplicate = accept(env, second["code"], "maya")
    assert (duplicate.status_code, error(duplicate)) == (409, "already_member")
    assert next(item for item in invitations(env) if item["invitationId"] == second["invitationId"])["status"] == "unused"
    assert len(snapshot(env, "riley")["members"]) == 2


def test_the_preview_shows_only_the_permitted_context(env: Env) -> None:
    riley = create_group(env, "riley")["viewer"]["memberId"]
    add_expense(env, "riley", expense(riley, 4321, [(riley, 4321)]))
    command(env, "riley", "addSeat", {"memberId": str(uuid.uuid4()), "displayName": "Placeholder"})
    created = invite(env)
    preview = env.client.get(f"/v1/group-invitations/{created['code']}").json["invitation"]
    assert set(preview) == {
        "groupName", "symbol", "currency", "inviterName", "ownerName", "memberCount", "expiresAt", "isSeatInvitation", "alreadyMember",
    }  # fmt: skip
    assert (preview["groupName"], preview["ownerName"], preview["memberCount"], preview["currency"]) == (
        "Coastal Weekend",
        "Riley",
        1,
        "USD",
    )
    assert "4321" not in str(preview) and "Placeholder" not in str(preview), "no ledger and no unjoined placeholders"


# MARK: - Ownership and membership changes


def test_ownership_transfer_is_explicit_and_recorded(env: Env) -> None:
    ids = grow(env, 3)
    assert error(command(env, "p01", "transferOwnership", {"memberId": ids["p01"]})) == "owner_only"
    assert error(command(env, "riley", "transferOwnership", {"memberId": str(uuid.uuid4())})) == "not_a_member"
    assert command(env, "riley", "transferOwnership", {"memberId": ids["p01"]}).status_code == 200
    view = snapshot(env, "p01")
    assert view["viewer"]["isOwner"] and view["group"]["ownerMemberId"] == ids["p01"]
    event = next(event for event in view["events"] if event["kind"] == "ownershipTransferred")
    assert event["data"] == {"fromMemberId": ids["riley"], "toMemberId": ids["p01"]} and event["actorMemberId"] == ids["riley"]
    assert error(env.client.post(f"/v1/groups/{env.id('group')}/invitations", json={}, headers=account("riley"))) == "owner_only"
    assert invite(env, "p01")["status"] == "unused"
    created = invite(env, "p01")
    assert env.client.get(f"/v1/group-invitations/{created['code']}").json["invitation"]["ownerName"] == "P01"
    # Riley, no longer the owner, can now leave (nothing owed).
    assert command(env, "riley", "leaveGroup", {}).status_code == 200


def test_owner_cannot_leave_and_nobody_leaves_or_is_removed_owing_money(env: Env) -> None:
    ids = grow(env, 3)
    assert error(command(env, "riley", "leaveGroup", {})) == "owner_must_transfer"
    assert error(command(env, "riley", "removeMember", {"memberId": ids["riley"]})) == "cannot_remove_yourself"
    allocations = [(ids["riley"], 1000), (ids["p01"], 1000), (ids["p02"], 1000)]
    assert add_expense(env, "riley", expense(ids["riley"], 3000, allocations, method="equal")).status_code == 200
    unsettled = command(env, "p01", "leaveGroup", {})
    assert (unsettled.status_code, error(unsettled), unsettled.json["error"]["balance"]) == (409, "member_has_balance", -1000)
    assert error(command(env, "riley", "removeMember", {"memberId": ids["p02"]})) == "member_has_balance"
    assert error(command(env, "p01", "removeMember", {"memberId": ids["p02"]})) == "owner_only"
    attempt = pay(env, "p01", ids["riley"], 1000)
    assert error(command(env, "p01", "leaveGroup", {})) == "member_has_balance", "a reported payment isn't settled until confirmed"
    assert confirm(env, "riley", attempt).status_code == 200
    left = command(env, "p01", "leaveGroup", {})
    assert left.status_code == 200, left.json
    assert confirm(env, "riley", pay(env, "p02", ids["riley"], 1000)).status_code == 200
    assert command(env, "riley", "removeMember", {"memberId": ids["p02"]}).status_code == 200
    events = [(event["kind"], event["data"].get("memberId")) for event in snapshot(env, "riley")["events"]]
    assert ("memberLeft", ids["p01"]) in events and ("memberRemoved", ids["p02"]) in events


def test_former_members_keep_their_history_but_lose_access(env: Env) -> None:
    ids = grow(env, 3)
    shared = expense(ids["p01"], 900, [(ids["riley"], 300), (ids["p01"], 300), (ids["p02"], 300)], method="equal", title="Pizza")
    assert add_expense(env, "p01", shared).status_code == 200
    for who in ("riley", "p02"):
        assert confirm(env, "p01", pay(env, who, ids["p01"], 300)).status_code == 200
    assert command(env, "p01", "leaveGroup", {}).status_code == 200
    for method, path in [
        ("get", f"/v1/groups/{env.id('group')}"),
        ("get", f"/v1/groups/{env.id('group')}/changes?after=0"),
        ("get", f"/v1/groups/{env.id('group')}/invitations"),
    ]:
        response = getattr(env.client, method)(path, headers=account("p01"))
        assert (response.status_code, error(response)) == (403, "not_a_member")
    assert error(command(env, "p01", "addExpense", {"expense": shared}, revision=99)) == "not_a_member"
    assert env.client.get("/v1/groups", headers=account("p01")).json["groups"] == []
    view = snapshot(env, "riley")
    former = next(member for member in view["members"] if member["id"] == ids["p01"])
    assert former["status"] == "removed" and former["displayName"] == "P01", "attribution is kept"
    assert next(item for item in view["expenses"] if item["title"] == "Pizza")["payments"][0]["memberId"] == ids["p01"]
    assert view["balances"]["confirmedNets"].get(ids["p01"], 0) == 0
    stranger = add_expense(env, "riley", expense(ids["riley"], 200, [(ids["riley"], 100), (ids["p01"], 100)], method="equal"))
    assert (error(stranger), stranger.json["error"]["memberId"]) == ("inactive_participant", ids["p01"]), (
        "no new expenses for former members"
    )


def test_a_former_member_can_be_invited_back_as_a_new_member(env: Env) -> None:
    ids = grow(env, 2)
    assert command(env, "p01", "leaveGroup", {}).status_code == 200
    rejoined = join(env, "p01")
    assert rejoined["viewer"]["memberId"] != ids["p01"], "a new membership; the old one stays in history"
    statuses = sorted(member["status"] for member in rejoined["members"] if member["displayName"] == "P01")
    assert statuses == ["active", "removed"]


def test_archiving_needs_everyone_square_and_no_payment_in_progress(env: Env) -> None:
    ids = grow(env, 3)
    allocations = [(ids["riley"], 200), (ids["p01"], 200), (ids["p02"], 200)]
    add_expense(env, "riley", expense(ids["riley"], 600, allocations, method="equal"))
    assert error(command(env, "p01", "archiveGroup", {})) == "owner_only"
    assert error(command(env, "riley", "archiveGroup", {})) == "group_has_balances"
    first = pay(env, "p01", ids["riley"], 200)
    confirm(env, "riley", first)
    second = pay(env, "p02", ids["riley"], 200)
    assert error(command(env, "riley", "archiveGroup", {})) in ("group_has_balances", "group_has_open_payments")
    confirm(env, "riley", second)
    assert command(env, "riley", "archiveGroup", {}).status_code == 200
    assert snapshot(env, "p02")["group"]["archivedAt"] is not None, "history stays readable"
    assert error(add_expense(env, "p01", expense(ids["p01"], 100, [(ids["p01"], 100)]))) == "group_archived"
    assert error(env.client.post(f"/v1/groups/{env.id('group')}/invitations", json={}, headers=account("riley"))) == "group_archived"


def test_archiving_waits_for_a_reported_payment_even_when_reserved(env: Env) -> None:
    ids = grow(env, 2)
    add_expense(env, "riley", expense(ids["riley"], 200, [(ids["riley"], 100), (ids["p01"], 100)], method="equal"))
    attempt = pay(env, "p01", ids["riley"], 100)
    assert error(command(env, "riley", "archiveGroup", {})) in ("group_has_balances", "group_has_open_payments")
    assert command(env, "riley", "advancePayment", {"attemptId": attempt, "action": "reject", "reason": "Not received"}).status_code == 200
    assert error(command(env, "riley", "archiveGroup", {})) == "group_has_balances"


# MARK: - Expenses among several people


def test_expenses_before_a_join_never_include_the_new_member(env: Env) -> None:
    ids = grow(env, 2)
    before = add_expense(env, "riley", expense(ids["riley"], 1000, [(ids["riley"], 500), (ids["p01"], 500)], method="equal"))
    assert before.status_code == 200
    ids["p02"] = join(env, "p02")["viewer"]["memberId"]
    view = snapshot(env, "p02")
    assert view["balances"]["confirmedNets"].get(ids["p02"], 0) == 0, "joining adds no debt"
    assert all(share["memberId"] != ids["p02"] for item in view["expenses"] for share in item["allocations"])
    after = expense(ids["p02"], 900, [(ids["riley"], 300), (ids["p01"], 300), (ids["p02"], 300)], method="equal")
    assert add_expense(env, "p02", after).status_code == 200
    nets = snapshot(env, "riley")["balances"]["confirmedNets"]
    assert nets == {ids["riley"]: 200, ids["p01"]: -800, ids["p02"]: 600}


def test_multiple_payers_and_every_split_mode_with_several_people(env: Env) -> None:
    ids = grow(env, 4)
    r, a, b, c = ids["riley"], ids["p01"], ids["p02"], ids["p03"]
    equal = expense([(r, 600), (a, 401)], 1001, [(r, 251), (a, 250), (b, 250), (c, 250)], method="equal")
    assert add_expense(env, "p01", equal).status_code == 200
    exact = expense([(b, 1000), (c, 234)], 1234, [(r, 1), (a, 233), (b, 500), (c, 500)])
    assert add_expense(env, "p02", exact).status_code == 200
    percent = expense(c, 1000, [(r, 100), (a, 200), (b, 300), (c, 400)], method="percentage")
    split = {
        "method": "percentage",
        "percentages": [{"memberId": m, "percent": p} for m, p in [(r, "10"), (a, "20"), (b, "30"), (c, "40")]],
    }
    assert add_expense(env, "p03", percent, split).status_code == 200
    shares = expense(r, 700, [(r, 100), (a, 200), (b, 400)], method="shares")
    weights = {"method": "shares", "weights": [{"memberId": m, "weight": w} for m, w in [(r, 1), (a, 2), (b, 4)]]}
    assert add_expense(env, "riley", shares, weights).status_code == 200
    off_by_a_cent = expense(r, 1000, [(r, 333), (a, 333), (b, 333)])
    assert add_expense(env, "riley", off_by_a_cent).json["error"]["reason"] == "allocationsDoNotReconcile"
    nets = snapshot(env, "p03")["balances"]["confirmedNets"]
    assert sum(nets.values()) == 0
    assert nets[r] == (600 - 251) + (0 - 1) + (0 - 100) + (700 - 100)


def test_the_owner_may_remove_someone_elses_expense_and_it_is_recorded(env: Env) -> None:
    ids = grow(env, 3)
    body = expense(ids["p01"], 600, [(ids["p01"], 300), (ids["p02"], 300)], method="equal")
    add_expense(env, "p01", body)
    edited = {**body, "title": "Changed by owner"}
    assert error(command(env, "riley", "updateExpense", {"expenseId": body["id"], "expense": edited})) in ("forbidden", "not_creator")
    assert error(command(env, "p02", "deleteExpense", {"expenseId": body["id"]})) in ("forbidden", "not_creator")
    assert command(env, "riley", "deleteExpense", {"expenseId": body["id"]}).status_code == 200
    deleted = next(event for event in snapshot(env, "p01")["events"] if event["kind"] == "expenseDeleted")
    assert deleted["actorMemberId"] == ids["riley"] and deleted["data"].get("byOwner") is True
    assert snapshot(env, "p02")["balances"]["confirmedNets"].get(ids["p02"], 0) == 0
    assert command(env, "riley", "restoreExpense", {"expenseId": body["id"]}).status_code == 200
    restored = next(event for event in snapshot(env, "p01")["events"] if event["kind"] == "expenseRestored")
    assert restored["data"].get("byOwner") is True
    own = command(env, "p01", "deleteExpense", {"expenseId": body["id"]})
    assert own.status_code == 200
    assert "byOwner" not in [event for event in snapshot(env, "p01")["events"] if event["kind"] == "expenseDeleted"][-1]["data"]


def test_concurrent_additions_from_several_members_all_apply_and_retries_are_idempotent(env: Env) -> None:
    ids = grow(env, 5)
    revision = snapshot(env, "riley")["revision"]
    bodies = {who: expense(member, 500, [(member, 500)], title=f"From {who}") for who, member in ids.items()}
    keys = {who: uuid.uuid4().hex for who in ids}
    statuses: list[int] = []

    def send(who: str) -> None:
        response = add_expense(env, who, bodies[who], revision=revision, key=keys[who])
        statuses.append(response.status_code)

    threads = [threading.Thread(target=send, args=(who,)) for who in ids for _ in range(2)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    assert all(status == 200 for status in statuses), statuses
    titles = sorted(item["title"] for item in snapshot(env, "riley")["expenses"])
    assert titles == sorted(f"From {who}" for who in ids), "each expense once, despite the duplicate sends"
    views = [snapshot(env, who) for who in ids]
    assert len({view["revision"] for view in views}) == 1 and all(view["balances"] == views[0]["balances"] for view in views)


def test_concurrent_edits_of_one_expense_keep_a_revision_trail(env: Env) -> None:
    ids = grow(env, 3)
    body = expense(ids["p01"], 900, [(ids["riley"], 300), (ids["p01"], 300), (ids["p02"], 300)], method="equal")
    add_expense(env, "p01", body)
    revision = snapshot(env, "p01")["revision"]

    def edit(title: str) -> Any:
        payload = {"expenseId": body["id"], "expectedExpenseRevision": 1, "expense": {**body, "title": title}}
        return command(env, "p01", "updateExpense", payload, revision=revision)

    first, second = edit("First"), edit("Second")
    assert first.status_code == 200, first.json
    assert (second.status_code, error(second), second.json["error"]["currentRevision"]) == (409, "expense_conflict", 2)
    revisions = env.client.get(f"/v1/groups/{env.id('group')}/expenses/{body['id']}/revisions", headers=account("p02"))
    assert revisions.status_code == 200 and len(revisions.json["revisions"]) == 2
    assert next(item for item in snapshot(env, "p02")["expenses"] if item["id"] == body["id"])["title"] == "First"
    rename = command(env, "riley", "updateGroup", {"name": "Late rename"}, revision=revision)
    assert error(rename) == "revision_conflict", "group-level changes refuse a stale revision"


# MARK: - Settling up among several people


def test_optimized_settlement_with_four_people_converges(env: Env) -> None:
    ids = grow(env, 4)
    command(env, "riley", "setSimplification", {"simplifiesDebts": True})
    r, a, b, c = ids["riley"], ids["p01"], ids["p02"], ids["p03"]
    add_expense(env, "riley", expense(r, 4000, [(r, 1000), (a, 1000), (b, 1000), (c, 1000)], method="equal"))
    add_expense(env, "p01", expense(a, 2000, [(b, 1000), (c, 1000)]))
    add_expense(env, "p02", expense(b, 800, [(c, 800)]))
    plan = snapshot(env, "p03")["balances"]
    assert plan["simplified"] and plan["simplifiedPaymentCount"] <= 3
    assert plan["simplifiedPaymentCount"] <= plan["directPaymentCount"]
    nets = plan["confirmedNets"]
    for payment in plan["payments"]:
        nets[payment["payerId"]] += payment["amount"]
        nets[payment["recipientId"]] -= payment["amount"]
    assert set(nets.values()) == {0}, "the suggested payments clear everyone"
    names = {member: who for who, member in ids.items()}
    for payment in plan["payments"]:
        payer, recipient = names[payment["payerId"]], names[payment["recipientId"]]
        attempt = pay(env, payer, payment["recipientId"], payment["amount"])
        bystander = next(who for who in ids if who not in (payer, recipient))
        assert error(confirm(env, bystander, attempt)) == "attempt_not_found", "an unrelated member can't confirm"
        assert confirm(env, payer, attempt).status_code >= 400, "the payer can't confirm their own report"
        assert confirm(env, recipient, attempt).status_code == 200
        assert confirm(env, recipient, attempt).status_code == 200, "confirming twice is harmless"
    views = [snapshot(env, who) for who in ids]
    assert all(view["balances"]["payments"] == [] for view in views)
    assert all(set(view["balances"]["confirmedNets"].values()) <= {0} for view in views)
    assert len(views[0]["settlements"]) == len(plan["payments"]), "one settlement per confirmed payment"
    assert all(view["settlements"] == views[0]["settlements"] for view in views)


def test_partial_payments_reduce_the_suggestion_and_never_exceed_it(env: Env) -> None:
    ids = grow(env, 3)
    add_expense(env, "riley", expense(ids["riley"], 3000, [(ids["riley"], 1000), (ids["p01"], 1000), (ids["p02"], 1000)], method="equal"))
    too_much = command(
        env, "p01", "startPayment", {"attemptId": str(uuid.uuid4()), "recipientId": ids["riley"], "amount": 1001, "provider": "cash"}
    )
    assert error(too_much) == "exceeds_obligation"
    assert (
        error(
            command(
                env, "p01", "startPayment", {"attemptId": str(uuid.uuid4()), "recipientId": ids["p02"], "amount": 100, "provider": "cash"}
            )
        )
        == "no_obligation"
    ), "nobody pays someone they don't owe"
    assert confirm(env, "riley", pay(env, "p01", ids["riley"], 400)).status_code == 200
    remaining = next(p for p in snapshot(env, "p01")["balances"]["payments"] if p["payerId"] == ids["p01"])
    assert remaining["amount"] == 600
    assert confirm(env, "riley", pay(env, "p01", ids["riley"], 600)).status_code == 200
    assert all(p["payerId"] != ids["p01"] for p in snapshot(env, "riley")["balances"]["payments"])


# MARK: - Backward compatibility


def test_legacy_seat_invitations_and_records_stay_readable(env: Env) -> None:
    riley = create_group(env, "riley")["viewer"]["memberId"]
    seat = str(uuid.uuid4())
    assert command(env, "riley", "addSeat", {"memberId": seat, "displayName": "Maya"}).status_code == 200
    add_expense(env, "riley", expense(riley, 1000, [(riley, 500), (seat, 500)], method="equal"))
    seat_invitation = invite(env, seatMemberId=seat)
    plain = invite(env)
    # Records written before this release have no acceptedMemberId (and older ones no creator).
    for item in (seat_invitation, plain):
        key, record = next(
            (k, v) for k, v in env.store.query(GROUP_INVITATION, "groupId", env.id("group")) if v["id"] == item["invitationId"]
        )
        for field in ("acceptedMemberId", "createdByMemberId"):
            record.pop(field, None)
        env.store.run_in_transaction(
            lambda transaction, key=key, record=record: transaction.put(
                GROUP_INVITATION, key, record, indexed={"groupId": record["groupId"], "expiresAt": record["expiresAt"]}
            )
        )
    assert {item["status"] for item in invitations(env)} == {"unused"}
    joined = accept(env, seat_invitation["code"], "maya")
    assert joined.status_code == 201 and joined.json["snapshot"]["viewer"]["memberId"] == seat, "the seat keeps its history"
    assert snapshot(env, "maya")["balances"]["confirmedNets"][seat] == -500
    listed = {item["invitationId"]: item for item in invitations(env)}
    assert listed[seat_invitation["invitationId"]]["status"] == "accepted"
    assert listed[seat_invitation["invitationId"]]["acceptedMemberId"] == seat
    assert accept(env, plain["code"], "sam").status_code == 201
    assert len(active(snapshot(env, "riley"))) == 3
