"""Direct invitations ("Find a person"): finding an existing account by a verified email address or
phone number, inviting it to a shared group, and the person accepting or declining in their own
Groups tab. Covers the directory, authorization, duplicates, every ending, enumeration limits, log
privacy, and two accounts staying in sync. Numbers and addresses are fictional."""

from __future__ import annotations

import io
import json
import logging
from contextlib import redirect_stdout
from typing import Any

from squareup.services.accounts import directory_key
from squareup.storage.base import ACCOUNT, ACCOUNT_DIRECTORY, DIRECT_INVITATION

from .conftest import Env
from .group_kit import account, add_expense, command, create_group, expense, join, member_id, profile, snapshot

NO_MATCH = {"match": None}


def lookup(env: Env, who: str, group_id: str | None = None, headers: dict[str, str] | None = None, **person: Any) -> Any:
    return env.client.post(f"/v1/groups/{group_id or env.id('group')}/people/lookup", json=person, headers=headers or account(who))


def send(env: Env, who: str, group_id: str | None = None, **person: Any) -> Any:
    return env.client.post(f"/v1/groups/{group_id or env.id('group')}/direct-invitations", json=person, headers=account(who))


def sent(env: Env, who: str, group_id: str | None = None) -> list[dict[str, Any]]:
    response = env.client.get(f"/v1/groups/{group_id or env.id('group')}/direct-invitations", headers=account(who))
    assert response.status_code == 200, response.json
    result: list[dict[str, Any]] = response.json["invitations"]
    return result


def received(env: Env, who: str) -> list[dict[str, Any]]:
    response = env.client.get("/v1/account/invitations", headers=account(who))
    assert response.status_code == 200, response.json
    result: list[dict[str, Any]] = response.json["invitations"]
    return result


def answer(env: Env, who: str, invitation_id: str, verb: str) -> Any:
    return env.client.post(f"/v1/account/invitations/{invitation_id}/{verb}", json={}, headers=account(who))


def invited(env: Env, sender: str = "riley", who: str = "sam") -> str:
    """``sender`` invites ``who`` (who has a profile) by email. Returns the invitation ID."""
    profile(env, who)
    response = send(env, sender, email=f"{who}@example.com")
    assert response.status_code == 201, response.json
    return str(response.json["invitation"]["invitationId"])


def error(response: Any) -> tuple[int, str]:
    return response.status_code, response.json["error"]["code"]


# MARK: - Finding a person


def test_a_verified_account_with_a_name_is_found_by_its_email(env: Env) -> None:
    create_group(env)
    profile(env, "sam", "Sam Rivera")
    for typed in ("sam@example.com", "  SAM@Example.COM "):
        response = lookup(env, "riley", email=typed)
        assert response.status_code == 200
        assert response.json == {"match": {"displayName": "Sam Rivera", "maskedIdentifier": "s•••@example.com", "status": "available"}}
    assert "uid" not in json.dumps(response.json) and "memberId" not in json.dumps(response.json), "nothing else about them"


def test_a_verified_phone_number_finds_its_account(env: Env) -> None:
    create_group(env)
    env.client.put("/v1/account/profile", json={"displayName": "Paula"}, headers={"Authorization": "Bearer tel16505550142-paula"})
    response = lookup(env, "riley", phone="+16505550142")
    assert response.json["match"] == {"displayName": "Paula", "maskedIdentifier": "•••• 0142", "status": "available"}


def test_everyone_who_cant_be_invited_looks_the_same(env: Env) -> None:
    create_group(env)
    env.client.get("/v1/account", headers=account("noname"))  # verified, but never chose a name
    env.client.put("/v1/account/profile", json={"displayName": "Una"}, headers={"Authorization": "Bearer unverified-una"})
    env.client.put("/v1/account/profile", json={"displayName": "Ann"}, headers={"Authorization": "Bearer anon-ann"})
    answers = [
        lookup(env, "riley", email=email)
        for email in ("nobody@example.com", "noname@example.com", "una@example.com", "ann@example.com", "+1@example.com")
    ]
    answers.append(lookup(env, "riley", phone="+16505550199"))
    assert all(response.status_code == 200 and response.json == NO_MATCH for response in answers)
    assert len({response.data for response in answers}) == 1, "byte-for-byte identical"


def test_malformed_lookups_are_refused_without_saying_anything_about_accounts(env: Env) -> None:
    create_group(env)
    bodies: list[dict[str, Any]] = [
        {},
        {"email": "a@b.co", "phone": "+16505550142"},
        {"email": "not an email"},
        {"email": 7},
        {"phone": "650-555-0142"},
        {"phone": "+0123"},
        {"email": "x" * 250 + "@example.com"},
    ]
    for body in bodies:
        response = env.client.post(f"/v1/groups/{env.id('group')}/people/lookup", json=body, headers=account("riley"))
        assert error(response) == (400, "invalid_payload"), body


def test_the_result_says_whether_they_can_be_invited(env: Env) -> None:
    create_group(env)
    join(env, "maya")
    profile(env, "sam")
    assert lookup(env, "riley", email="riley@example.com").json["match"]["status"] == "you"
    assert lookup(env, "riley", email="maya@example.com").json["match"]["status"] == "member"
    assert lookup(env, "riley", email="sam@example.com").json["match"]["status"] == "available"
    assert send(env, "riley", email="sam@example.com").status_code == 201
    assert lookup(env, "maya", email="sam@example.com").json["match"]["status"] == "invited", "for every member"


def test_only_members_of_a_live_group_can_look_people_up(env: Env) -> None:
    create_group(env)
    profile(env, "sam")
    profile(env, "outsider")
    assert error(lookup(env, "outsider", email="sam@example.com")) == (404, "group_not_found")
    assert error(lookup(env, "x", headers={"Authorization": "Bearer anon-x"}, email="sam@example.com")) == (403, "account_required")
    assert error(lookup(env, "x", headers={"Authorization": "Bearer unverified-x"}, email="sam@example.com")) == (403, "email_not_verified")
    unsigned = env.client.post(f"/v1/groups/{env.id('group')}/people/lookup", json={"email": "sam@example.com"})
    assert error(unsigned) == (401, "unauthenticated")
    join(env, "maya")
    assert command(env, "maya", "leaveGroup", {}).status_code == 200
    assert error(lookup(env, "maya", email="sam@example.com")) == (403, "not_a_member"), "former members can't either"
    assert command(env, "riley", "archiveGroup", {}).status_code == 200
    assert error(lookup(env, "riley", email="sam@example.com")) == (410, "group_archived")


def test_looking_people_up_is_rate_limited_per_minute_and_per_day(env: Env) -> None:
    create_group(env)
    for _ in range(10):
        assert lookup(env, "riley", email="nobody@example.com").status_code == 200
    limited = lookup(env, "riley", email="nobody@example.com")
    assert error(limited) == (429, "rate_limited") and int(limited.headers["Retry-After"]) > 0
    for _ in range(5):
        env.clock.advance(minutes=1)
        for _ in range(10):
            lookup(env, "riley", email="nobody@example.com")
    env.clock.advance(minutes=1)
    assert error(lookup(env, "riley", email="nobody@example.com")) == (429, "rate_limited"), "60 a day"
    assert lookup(env, "maya", email="nobody@example.com").status_code != 429, "per account"


def test_inviting_counts_as_a_lookup(env: Env) -> None:
    create_group(env)
    for _ in range(10):
        send(env, "riley", email="nobody@example.com")
    assert error(lookup(env, "riley", email="nobody@example.com")) == (429, "rate_limited")


# MARK: - The directory


def test_the_directory_holds_no_address_or_number(env: Env) -> None:
    env.client.put("/v1/account/profile", json={"displayName": "Paula"}, headers={"Authorization": "Bearer tel16505550142-paula"})
    profile(env, "sam")
    for kind, value, uid in (("phone", "+16505550142", "paula"), ("email", "sam@example.com", "sam")):
        entry = env.store.get(ACCOUNT_DIRECTORY, directory_key(kind, value))
        assert entry is not None and entry["uid"] == uid
        stored = json.dumps([entry, env.store.get(ACCOUNT, uid)])
        assert value not in stored and value.removeprefix("+1") not in stored and value.split("@")[0] + "@" not in stored
    assert env.client.get("/v1/account", headers=account("sam")).json["account"]["profile"].keys().isdisjoint({"directory"})


def test_a_number_that_moves_to_another_account_finds_only_that_account(env: Env) -> None:
    create_group(env)
    first = {"Authorization": "Bearer tel16505550142-paula"}
    env.client.put("/v1/account/profile", json={"displayName": "Paula"}, headers=first)
    assert lookup(env, "riley", phone="+16505550142").json["match"]["displayName"] == "Paula"
    # Paula's account changes its number; the old one stops finding her as soon as she opens the app.
    env.client.get("/v1/account", headers={"Authorization": "Bearer tel16505550177-paula"})
    assert lookup(env, "riley", phone="+16505550142").json == NO_MATCH
    assert lookup(env, "riley", phone="+16505550177").json["match"]["displayName"] == "Paula"
    # Someone else verifies 0177 later; Paula's stale sign-in (still 0177) can't take it back from them.
    env.client.put("/v1/account/profile", json={"displayName": "Quinn"}, headers={"Authorization": "Bearer tel16505550177-quinn"})
    assert lookup(env, "riley", phone="+16505550177").json["match"]["displayName"] == "Quinn"
    env.client.get("/v1/account", headers={"Authorization": "Bearer tel16505550177-paula"})
    assert lookup(env, "riley", phone="+16505550177").json["match"]["displayName"] == "Quinn"
    env.client.get("/v1/account", headers=first)  # Paula, back on 0142, removes only what's hers
    assert lookup(env, "riley", phone="+16505550177").json["match"]["displayName"] == "Quinn"
    assert lookup(env, "riley", phone="+16505550142").json["match"]["displayName"] == "Paula"


# MARK: - Inviting


def test_an_invitation_adds_nobody_until_it_is_accepted(env: Env) -> None:
    owner_view = create_group(env, name="Dinner Squad")
    invitation_id = invited(env)
    assert snapshot(env, "riley")["revision"] == owner_view["revision"], "the group itself doesn't change"
    assert [m["displayName"] for m in snapshot(env, "riley")["members"]] == ["Riley"]
    assert error(env.client.get(f"/v1/groups/{env.id('group')}", headers=account("sam"))) == (404, "group_not_found")
    assert env.client.get("/v1/groups", headers=account("sam")).json["groups"] == []
    [waiting] = received(env, "sam")
    assert waiting == {
        "invitationId": invitation_id,
        "status": "pending",
        "groupName": "Dinner Squad",
        "symbol": "beach.umbrella.fill",
        "currency": "USD",
        "inviterName": "Riley",
        "memberCount": 1,
        "createdAt": waiting["createdAt"],
        "expiresAt": "2026-10-25T12:00:00.000000Z",
    }
    assert "groupId" not in waiting and "balances" not in waiting, "nothing from inside the group"
    [mine] = sent(env, "riley")
    assert mine["status"] == "pending" and mine["displayName"] == "Sam" and mine["maskedIdentifier"] == "s•••@example.com"


def test_any_member_can_invite_someone(env: Env) -> None:
    create_group(env)
    join(env, "maya")
    profile(env, "sam")
    response = send(env, "maya", email="sam@example.com")
    assert response.status_code == 201
    assert received(env, "sam")[0]["inviterName"] == "Maya"


def test_duplicates_yourself_members_and_unknown_people_are_refused(env: Env) -> None:
    create_group(env)
    join(env, "maya")
    invited(env)
    assert error(send(env, "riley", email="sam@example.com")) == (409, "invitation_exists")
    assert error(send(env, "maya", email="sam@example.com")) == (409, "invitation_exists"), "one per person, whoever sends it"
    assert error(send(env, "riley", email="riley@example.com")) == (409, "cannot_invite_yourself")
    assert error(send(env, "riley", email="maya@example.com")) == (409, "invitee_already_member")
    unknown = send(env, "riley", email="nobody@example.com")
    assert error(unknown) == (404, "invitee_not_found") and "share an invitation link" in unknown.json["error"]["message"]
    assert len(received(env, "sam")) == 1


def test_only_members_of_a_live_group_can_invite(env: Env) -> None:
    create_group(env)
    profile(env, "sam")
    profile(env, "outsider")
    assert error(send(env, "outsider", email="sam@example.com")) == (404, "group_not_found")
    assert command(env, "riley", "archiveGroup", {}).status_code == 200
    assert error(send(env, "riley", email="sam@example.com")) == (410, "group_archived")


def test_a_full_group_takes_no_more_invitations(env: Env) -> None:
    create_group(env)
    for index in range(24):
        join(env, f"member{index}")
    profile(env, "sam")
    assert error(send(env, "riley", email="sam@example.com")) == (409, "group_full")


# MARK: - Accepting


def test_accepting_joins_the_group_and_both_accounts_see_the_same_group(env: Env) -> None:
    create_group(env)
    owner_cursor = snapshot(env, "riley")["cursor"]
    invitation_id = invited(env)
    response = answer(env, "sam", invitation_id, "accept")
    assert response.status_code == 201 and response.json["joined"] is True
    sams = response.json["snapshot"]
    assert sams["viewer"]["isOwner"] is False and {m["displayName"] for m in sams["members"]} == {"Riley", "Sam"}
    assert received(env, "sam") == []
    assert [summary["group"]["id"] for summary in env.client.get("/v1/groups", headers=account("sam")).json["groups"]] == [env.id("group")]
    # Riley's iPhone catches up through the change feed: Sam joined.
    changes = env.client.get(f"/v1/groups/{env.id('group')}/changes?after={owner_cursor}", headers=account("riley")).json["changes"]
    assert [event["kind"] for event in changes["events"]] == ["memberJoined"]
    assert changes["events"][0]["data"]["memberId"] == sams["viewer"]["memberId"]
    [answered] = sent(env, "riley")
    assert answered["status"] == "accepted" and answered["respondedAt"] is not None
    # Accepting again (a retry after a lost response) changes nothing.
    again = answer(env, "sam", invitation_id, "accept")
    assert again.status_code == 200 and again.json["joined"] is False
    assert len(snapshot(env, "riley")["members"]) == 2


def test_after_joining_balances_and_changes_reach_both_accounts(env: Env) -> None:
    create_group(env)
    answer(env, "sam", invited(env), "accept")
    riley, sam = member_id(snapshot(env, "riley"), "Riley"), member_id(snapshot(env, "riley"), "Sam")
    assert add_expense(env, "riley", expense(riley, 6000, [(riley, 3000), (sam, 3000)])).status_code == 200
    sams, rileys = snapshot(env, "sam"), snapshot(env, "riley")
    assert sams["balances"] == rileys["balances"] and sams["revision"] == rileys["revision"]
    assert sams["balances"]["confirmedNets"][sam] == -3000
    sam_cursor = sams["cursor"]
    assert add_expense(env, "sam", expense(sam, 1000, [(riley, 500), (sam, 500)], title="Coffee")).status_code == 200
    changes = env.client.get(f"/v1/groups/{env.id('group')}/changes?after={sam_cursor}", headers=account("riley")).json["changes"]
    assert [e["title"] for e in changes["expenses"]] == ["Coffee"] and changes["balances"]["confirmedNets"][sam] == -2500


def test_nobody_else_can_answer_someone_elses_invitation(env: Env) -> None:
    create_group(env)
    invitation_id = invited(env)
    profile(env, "mallory")
    for verb in ("accept", "decline"):
        assert error(answer(env, "mallory", invitation_id, verb)) == (404, "not_found"), "looks like it doesn't exist"
        assert error(answer(env, "riley", invitation_id, verb)) == (404, "not_found"), "not even the sender"
    assert error(answer(env, "sam", "not-a-uuid", "accept")) == (400, "invalid_payload")
    assert received(env, "mallory") == [] and received(env, "riley") == []
    assert len(received(env, "sam")) == 1


def test_joining_by_link_meanwhile_ends_the_direct_invitation(env: Env) -> None:
    create_group(env)
    invitation_id = invited(env)
    join(env, "sam")
    assert received(env, "sam") == []
    assert error(answer(env, "sam", invitation_id, "accept")) == (409, "already_member")


# MARK: - Declining, cancelling, and other endings


def test_declining_removes_it_and_the_sender_can_invite_again(env: Env) -> None:
    create_group(env)
    invitation_id = invited(env)
    declined = answer(env, "sam", invitation_id, "decline")
    assert declined.status_code == 200 and declined.json["invitation"]["status"] == "declined"
    assert answer(env, "sam", invitation_id, "decline").status_code == 200, "declining twice is harmless"
    assert received(env, "sam") == [] and sent(env, "riley")[0]["status"] == "declined"
    assert error(answer(env, "sam", invitation_id, "accept")) == (409, "invitation_declined")
    assert lookup(env, "riley", email="sam@example.com").json["match"]["status"] == "available"
    again = send(env, "riley", email="sam@example.com")
    assert again.status_code == 201 and again.json["invitation"]["invitationId"] != invitation_id
    assert [w["invitationId"] for w in received(env, "sam")] == [again.json["invitation"]["invitationId"]]


def test_the_sender_or_the_owner_can_cancel_but_nobody_else(env: Env) -> None:
    create_group(env)
    join(env, "maya")
    join(env, "lee")
    profile(env, "sam")
    profile(env, "ana")
    from_maya = send(env, "maya", email="sam@example.com").json["invitation"]["invitationId"]
    from_lee = send(env, "lee", email="ana@example.com").json["invitation"]["invitationId"]
    path = f"/v1/groups/{env.id('group')}/direct-invitations"
    assert {i["invitationId"] for i in sent(env, "riley")} == {from_maya, from_lee}, "the owner sees every one"
    assert [i["invitationId"] for i in sent(env, "maya")] == [from_maya], "everyone else, their own"
    assert error(env.client.delete(f"{path}/{from_maya}", headers=account("lee"))) == (403, "forbidden")
    assert error(env.client.delete(f"{path}/{from_maya}", headers=account("outsider"))) == (404, "group_not_found")
    cancelled = env.client.delete(f"{path}/{from_maya}", headers=account("maya"))
    assert cancelled.status_code == 200 and cancelled.json["invitation"]["status"] == "cancelled"
    assert env.client.delete(f"{path}/{from_lee}", headers=account("riley")).json["invitation"]["status"] == "cancelled"
    assert received(env, "sam") == [] and received(env, "ana") == []
    assert error(answer(env, "sam", from_maya, "accept")) == (410, "invitation_revoked")


def test_an_answered_invitation_cant_be_cancelled(env: Env) -> None:
    create_group(env)
    invitation_id = invited(env)
    answer(env, "sam", invitation_id, "accept")
    response = env.client.delete(f"/v1/groups/{env.id('group')}/direct-invitations/{invitation_id}", headers=account("riley"))
    assert error(response) == (409, "invitation_used")


def test_an_invitation_expires_after_30_days(env: Env) -> None:
    create_group(env)
    invitation_id = invited(env)
    env.clock.advance(days=30, seconds=1)
    assert received(env, "sam") == [] and sent(env, "riley")[0]["status"] == "expired"
    assert error(answer(env, "sam", invitation_id, "accept")) == (410, "invitation_expired")
    assert send(env, "riley", email="sam@example.com").status_code == 201, "a new one can be sent"


def test_it_ends_when_the_sender_leaves_or_the_group_is_archived(env: Env) -> None:
    create_group(env)
    join(env, "maya")
    profile(env, "sam")
    from_maya = send(env, "maya", email="sam@example.com").json["invitation"]["invitationId"]
    assert command(env, "maya", "leaveGroup", {}).status_code == 200
    assert received(env, "sam") == []
    assert error(answer(env, "sam", from_maya, "accept")) == (410, "invitation_revoked")
    from_riley = send(env, "riley", email="sam@example.com").json["invitation"]["invitationId"]
    assert command(env, "riley", "archiveGroup", {}).status_code == 200
    assert received(env, "sam") == []
    assert error(answer(env, "sam", from_riley, "accept")) == (410, "group_archived")


def test_a_full_group_refuses_the_acceptance(env: Env) -> None:
    create_group(env)
    invitation_id = invited(env)
    for index in range(24):
        join(env, f"member{index}")
    assert error(answer(env, "sam", invitation_id, "accept")) == (409, "group_full")
    assert received(env, "sam") != [], "still there if someone leaves"


def test_cleanup_deletes_old_direct_invitations(env: Env) -> None:
    create_group(env)
    invited(env)
    env.clock.advance(days=38)
    response = env.client.get("/tasks/cleanup", headers={"X-Appengine-Cron": "true"})
    assert response.status_code == 200 and response.json["removed"]["directInvitations"] == 1
    assert env.store.get(DIRECT_INVITATION, f"{env.id('group')}:sam") is None


# MARK: - Privacy


def test_logs_carry_no_address_number_name_or_account(env: Env) -> None:
    captured = io.StringIO()
    logger = logging.getLogger("squareup")
    handler = logging.StreamHandler(captured)
    handler.setFormatter(logger.handlers[0].formatter)
    logger.addHandler(handler)
    try:
        with redirect_stdout(captured):
            create_group(env)
            paula = {"Authorization": "Bearer tel16505550142-paula"}
            env.client.put("/v1/account/profile", json={"displayName": "Paula Secretname"}, headers=paula)
            lookup(env, "riley", phone="+16505550142")
            lookup(env, "riley", email="nobody@example.com")
            invitation_id = invited(env)
            send(env, "riley", phone="+16505550142")
            received(env, "sam")
            answer(env, "sam", invitation_id, "accept")
    finally:
        logger.removeHandler(handler)
    logged = captured.getvalue()
    assert "group.personLookup" in logged and "group.directInvitationCreated" in logged
    for secret in ("6505550142", "sam@example.com", "nobody@", "Secretname", '"paula"', '"sam"', directory_key("phone", "+16505550142")):
        assert secret not in logged, secret
