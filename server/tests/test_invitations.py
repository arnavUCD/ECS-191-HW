"""Invitations, guest identities, restoration, linking (milestone 4 §6, §8.2, §13)."""

from __future__ import annotations

from squareup.storage.base import GUEST, INVITATION
from tests.conftest import HOST, Env, command, guest_headers, invite, join, publish


def test_invitation_url_is_opaque_and_token_is_only_stored_hashed(env: Env) -> None:
    publish(env)
    invitation = invite(env)
    token = invitation["token"]
    assert invitation["url"] == f"https://squareup.example/r/{token}"
    assert len(token) >= 43, "256-bit token"
    for secret in (env.id("room"), "Fernwood", "Riley", "Maya", "2165"):
        assert secret not in invitation["url"]
    stored = env.store.query(INVITATION, "roomId", env.id("room"))
    assert len(stored) == 1
    key, record = stored[0]
    assert token not in key and token not in str(record), "Only the hash is stored"


def test_preview_reveals_permitted_context_only(env: Env) -> None:
    publish(env)
    token = invite(env)["token"]
    preview = env.client.get(f"/v1/receipt-room-invitations/{token}").json["invitation"]
    assert preview["host"] == {"displayName": "Riley"}
    assert preview["openSeats"] == [{"id": env.id("maya"), "displayName": "Maya"}]
    assert "items" not in preview and "claims" not in preview and "allocation" not in preview


def test_invalid_unknown_and_malformed_tokens_are_indistinguishable(env: Env) -> None:
    publish(env)
    for token in ("A" * 43, "short", "../../etc", "x" * 300):
        response = env.client.get(f"/v1/receipt-room-invitations/{token}")
        assert response.status_code == 404
        assert response.json["error"]["code"] == "invitation_invalid"
        assert "room" not in response.json


def test_expired_and_revoked_invitations_reveal_nothing(env: Env) -> None:
    publish(env)
    expired = invite(env, expiresInHours=1)["token"]
    revoked = invite(env)
    env.client.delete(f"/v1/receipt-rooms/{env.id('room')}/invitations/{revoked['invitationId']}", headers=HOST)
    env.clock.advance(hours=2)
    response = env.client.get(f"/v1/receipt-room-invitations/{expired}")
    assert response.status_code == 410 and response.json["error"]["code"] == "invitation_expired"
    response = env.client.post(f"/v1/receipt-room-invitations/{revoked['token']}/join", json={"displayName": "Sam"})
    assert response.status_code == 410 and response.json["error"]["code"] == "invitation_revoked"
    assert "room" not in response.json


def test_recreating_can_revoke_older_invitations(env: Env) -> None:
    publish(env)
    first = invite(env)["token"]
    invite(env, revokeExisting=True)
    assert env.client.get(f"/v1/receipt-room-invitations/{first}").json["error"]["code"] == "invitation_revoked"


def test_guest_join_creates_room_scoped_credential(env: Env) -> None:
    publish(env)
    joined = join(env, invite(env)["token"], "Sam")
    assert joined["restored"] is False and joined["credential"]
    room = joined["room"]
    assert room["viewer"] == {"participantId": joined["participantId"], "isHost": False}
    guest = next(p for p in room["participants"] if p["id"] == joined["participantId"])
    assert guest["kind"] == "guest" and guest["displayName"] == "Sam" and guest["accountBacked"] is False
    assert "boundSubject" not in str(room) and joined["credential"] not in str(room)
    ((_, record),) = env.store.query(GUEST, "roomId", env.id("room"))
    assert record["participantId"] == joined["participantId"]


def test_returning_guest_is_restored_without_duplicate(env: Env) -> None:
    publish(env)
    token = invite(env)["token"]
    first = join(env, token, "Sam")
    again = env.client.post(
        f"/v1/receipt-room-invitations/{token}/join", json={"displayName": "Sammy"}, headers=guest_headers(first["credential"])
    ).json
    assert again["restored"] is True and again["participantId"] == first["participantId"]
    assert again["credential"] is None
    participants = again["room"]["participants"]
    assert sum(1 for p in participants if p["kind"] == "guest") == 1


def test_display_name_is_not_authentication(env: Env) -> None:
    publish(env)
    token = invite(env)["token"]
    first = join(env, token, "Sam")
    second = join(env, token, "Sam")
    assert second["participantId"] != first["participantId"], "Same name, different person"


def test_guest_credential_only_works_for_its_room(env: Env) -> None:
    publish(env)
    credential = join(env, invite(env)["token"])["credential"]
    other_room = env.id("other-room")
    response = env.client.get(f"/v1/receipt-rooms/{other_room}", headers=guest_headers(credential))
    assert response.status_code == 404


def test_guest_credential_expires_and_slides_while_active(env: Env) -> None:
    publish(env)
    token = invite(env, expiresInHours=200)["token"]
    credential = join(env, token)["credential"]
    env.clock.advance(hours=71)
    env.client.post(f"/v1/receipt-room-invitations/{token}/join", json={}, headers=guest_headers(credential))
    env.clock.advance(hours=71)
    assert env.client.get(f"/v1/receipt-rooms/{env.id('room')}", headers=guest_headers(credential)).status_code == 200
    env.clock.advance(hours=73)
    response = env.client.get(f"/v1/receipt-rooms/{env.id('room')}", headers=guest_headers(credential))
    assert response.status_code == 401 and response.json["error"]["code"] == "credential_expired"


def test_seat_claim_binds_once(env: Env) -> None:
    publish(env)
    token = invite(env)["token"]
    joined = join(env, token, "Maya", seatId=env.id("maya"))
    assert joined["participantId"] == env.id("maya")
    response = env.client.post(f"/v1/receipt-room-invitations/{token}/join", json={"displayName": "X", "seatId": env.id("maya")})
    assert response.status_code == 409 and response.json["error"]["code"] == "seat_taken"


def test_max_guests_is_enforced(env: Env) -> None:
    publish(env)
    token = invite(env, maxGuests=1)["token"]
    join(env, token)
    response = env.client.post(f"/v1/receipt-room-invitations/{token}/join", json={"displayName": "Extra"})
    assert response.status_code == 409 and response.json["error"]["code"] == "invitation_full"


def test_finalized_and_cancelled_rooms_refuse_new_participants(env: Env) -> None:
    publish(env)
    token = invite(env)["token"]
    existing = join(env, token)
    command(env, HOST, "cancel", {})
    response = env.client.post(f"/v1/receipt-room-invitations/{token}/join", json={"displayName": "Late"})
    assert response.status_code == 409 and response.json["error"]["code"] == "room_cancelled"
    # An existing participant still gets the read-only final state.
    restored = env.client.post(f"/v1/receipt-room-invitations/{token}/join", json={}, headers=guest_headers(existing["credential"])).json
    assert restored["restored"] is True and restored["room"]["state"] == "cancelled"


def test_full_app_account_joins_and_links_guest_without_duplicate(env: Env) -> None:
    publish(env)
    token = invite(env)["token"]
    guest = join(env, token, "Sam")
    claim = command(env, guest_headers(guest["credential"]), "claim", {"itemId": env.id("fries"), "request": "mine"})
    assert claim.status_code == 200
    account = {"Authorization": "Bearer valid-sam-uid"}
    linked = env.client.post(f"/v1/receipt-rooms/{env.id('room')}/link-guest", json={"guestToken": guest["credential"]}, headers=account)
    assert linked.status_code == 200, linked.json
    room = linked.json["room"]
    sam = next(p for p in room["participants"] if p["id"] == guest["participantId"])
    assert sam["accountBacked"] is True
    assert [c["participantId"] for c in room["claims"]] == [guest["participantId"]], "Claims stay with the participant"
    assert sum(1 for p in room["participants"] if p["displayName"] == "Sam") == 1
    # The account now restores the same participant; the guest credential no longer works.
    restored = env.client.post(f"/v1/receipt-room-invitations/{token}/join", json={}, headers=account).json
    assert restored["participantId"] == guest["participantId"] and restored["restored"] is True
    assert env.client.get(f"/v1/receipt-rooms/{env.id('room')}", headers=guest_headers(guest["credential"])).status_code == 401


def test_host_alone_manages_invitations(env: Env) -> None:
    publish(env)
    guest = join(env, invite(env)["token"])
    headers = guest_headers(guest["credential"])
    assert env.client.post(f"/v1/receipt-rooms/{env.id('room')}/invitations", json={}, headers=headers).status_code == 403
    assert env.client.get(f"/v1/receipt-rooms/{env.id('room')}/invitations", headers=headers).status_code == 403
    listed = env.client.get(f"/v1/receipt-rooms/{env.id('room')}/invitations", headers=HOST).json["invitations"]
    assert len(listed) == 1 and "token" not in listed[0] and "tokenHash" not in listed[0]


def test_seat_claim_keeps_the_seat_name_and_new_people_need_one(env: Env) -> None:
    publish(env)
    token = invite(env)["token"]
    response = env.client.post(f"/v1/receipt-room-invitations/{token}/join", json={"seatId": env.id("maya")})
    assert response.status_code == 201
    maya = next(p for p in response.json["room"]["participants"] if p["id"] == env.id("maya"))
    assert maya["displayName"] == "Maya"
    nameless = env.client.post(f"/v1/receipt-room-invitations/{token}/join", json={})
    assert nameless.status_code == 400
    assert nameless.json["error"]["code"] == "invalid_payload"
