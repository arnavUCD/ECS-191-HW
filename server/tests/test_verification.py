"""Every full Square Up account needs an email address Firebase reports as verified — no exceptions
by age. An unverified (or anonymous) account can read its own status and remove its AI results,
nothing else; room guests keep working with their room-scoped credential only."""

from __future__ import annotations

import uuid
from typing import Any

from .conftest import HOST, Env, guest_headers, invite, join, publish

UNVERIFIED = {"Authorization": "Bearer unverified-host-uid"}
ANONYMOUS = {"Authorization": "Bearer anon-host-uid"}


def code(response: Any) -> str:
    return str(response.json["error"]["code"])


def test_unverified_and_anonymous_accounts_cannot_use_receipt_rooms(env: Env) -> None:
    publish(env)  # the verified host
    token = invite(env)["token"]
    room = env.id("room")
    envelope = {"commandId": str(uuid.uuid4()), "idempotencyKey": uuid.uuid4().hex, "expectedRevision": 1, "type": "claim", "payload": {}}
    routes: list[tuple[str, str, Any]] = [
        ("post", "/v1/receipt-rooms", {"roomId": str(uuid.uuid4())}),
        ("get", f"/v1/receipt-rooms/{room}", None),
        ("get", f"/v1/receipt-rooms/{room}/history", None),
        ("post", f"/v1/receipt-rooms/{room}/commands", envelope),
        ("post", f"/v1/receipt-rooms/{room}/finalize", {**envelope, "type": "finalize"}),
        ("post", f"/v1/receipt-rooms/{room}/invitations", {}),
        ("get", f"/v1/receipt-rooms/{room}/invitations", None),
        ("delete", f"/v1/receipt-rooms/{room}/invitations/{uuid.uuid4()}", None),
        ("post", f"/v1/receipt-rooms/{room}/link-guest", {"guestToken": "x" * 43}),
        ("get", f"/v1/receipt-rooms/{room}/receipt-assets/{uuid.uuid4()}", None),
        ("post", f"/v1/receipt-room-invitations/{token}/join", {"displayName": "Sam"}),
    ]
    for headers, expected in ((UNVERIFIED, "email_not_verified"), (ANONYMOUS, "account_required")):
        for method, path, body in routes:
            response = getattr(env.client, method)(path, json=body, headers=headers)
            assert response.status_code == 403 and code(response) == expected, (method, path, expected, response.json)
    # The same account, verified, still hosts.
    assert env.client.get(f"/v1/receipt-rooms/{room}", headers=HOST).status_code == 200


def test_room_guests_still_join_and_act_with_their_own_credential(env: Env) -> None:
    publish(env)
    joined = join(env, invite(env)["token"], "Sam")
    guest = guest_headers(joined["credential"])
    assert env.client.get(f"/v1/receipt-rooms/{env.id('room')}", headers=guest).status_code == 200
    # ...and never reach shared groups or receipt AI with it.
    assert env.client.get("/v1/groups", headers=guest).status_code in (401, 403)
    assert env.client.post("/v1/receipt-intelligence/parse", json={}, headers=guest).status_code in (401, 403)


def test_an_unverified_account_keeps_only_the_minimum(env: Env) -> None:
    status = env.client.get("/v1/account", headers=UNVERIFIED)
    assert status.status_code == 200 and status.json["account"]["emailVerified"] is False, "it can read why it's blocked"
    assert env.client.delete("/v1/receipt-intelligence/cache", headers=UNVERIFIED).status_code == 200, "and withdraw AI consent"
    refused = [
        env.client.put("/v1/account/profile", json={"displayName": "Riley"}, headers=UNVERIFIED),
        env.client.put(f"/v1/account/destinations/{uuid.uuid4()}", json={}, headers=UNVERIFIED),
        env.client.get("/v1/groups", headers=UNVERIFIED),
        env.client.post("/v1/receipt-intelligence/parse", data=b"{}", headers={**UNVERIFIED, "Content-Type": "application/json"}),
    ]
    assert [(response.status_code, code(response)) for response in refused] == [(403, "email_not_verified")] * 4
