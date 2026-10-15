"""Authoritative rooms: authorization matrix, revisions, concurrency, idempotency, finalization,
validation, rate limiting, assets, retention, and privacy (milestone 4 §7–§11, §14.2)."""

from __future__ import annotations

import io
import json
import logging
import threading
import uuid
from contextlib import redirect_stdout
from typing import Any

import pytest

from squareup.domain.errors import STATUS_FOR_CODE
from squareup.services.assets import strip_jpeg_metadata
from squareup.storage.base import ASSET, IDEMPOTENCY
from tests.conftest import HOST, Env, build, command, guest_headers, invite, join, publish

ROOM = "/v1/receipt-rooms"


def _guest(env: Env) -> tuple[dict[str, str], str]:
    joined = join(env, invite(env)["token"])
    return guest_headers(joined["credential"]), joined["participantId"]


# MARK: - Publish


def test_publish_is_idempotent_and_owned(env: Env) -> None:
    first = publish(env)
    again = env.client.post(
        ROOM,
        json={
            "roomId": env.id("room"),
            "hostParticipantId": env.id("host"),
            "payerId": env.id("host"),
            "participants": [{"id": env.id("host"), "displayName": "Riley"}],
            "receipt": first["receipt"],
        },
        headers=HOST,
    )
    assert again.status_code == 200 and again.json["created"] is False
    stranger = env.client.post(
        ROOM,
        json={
            "roomId": env.id("room"),
            "hostParticipantId": env.id("x"),
            "payerId": env.id("x"),
            "participants": [{"id": env.id("x"), "displayName": "X"}],
            "receipt": first["receipt"],
        },
        headers={"Authorization": "Bearer valid-someone-else"},
    )
    assert stranger.status_code == 404


def test_publish_requires_an_account_and_a_reconciled_receipt(env: Env) -> None:
    assert env.client.post(ROOM, json={}).status_code == 401
    assert env.client.post(ROOM, json={}, headers={"Authorization": "Bearer forged"}).status_code == 401
    body = {
        "roomId": env.id("room"),
        "hostParticipantId": env.id("host"),
        "payerId": env.id("host"),
        "participants": [{"id": env.id("host"), "displayName": "Riley"}],
        "receipt": {
            "merchant": "M",
            "date": "2026-09-24",
            "currency": "USD",
            "total": 999,
            "items": [{"id": env.id("i"), "name": "A", "lineTotal": 1000}],
            "charges": [],
        },
    }
    response = env.client.post(ROOM, json=body, headers=HOST)
    assert response.status_code == 422 and response.json["error"]["code"] == "receipt_not_ready"
    assert response.json["error"]["issues"] == [{"kind": "totalMismatch", "difference": -1}]


@pytest.mark.parametrize(
    "mutate",
    [
        lambda b: b.update(roomId="not-a-uuid"),
        lambda b: b["receipt"].update(currency="usd"),
        lambda b: b["receipt"].update(date="Sept 24"),
        lambda b: b["receipt"]["items"][0].update(lineTotal=1.5),
        lambda b: b["receipt"]["items"][0].update(lineTotal="950"),
        lambda b: b["receipt"]["items"][0].update(lineTotal=10**15),
        lambda b: b["receipt"]["items"][0].update(name="x" * 500),
        lambda b: b["receipt"].update(items=[b["receipt"]["items"][0]] * 2),
        lambda b: b["participants"][0].update(displayName=""),
        lambda b: b["receipt"]["charges"][0].update(kind="bribe"),
        lambda b: b.update(participants=[{"id": str(uuid.uuid4()), "displayName": "P"}] * 61),
    ],
)
def test_malformed_publish_payloads_are_rejected(env: Env, mutate: Any) -> None:
    body = {
        "roomId": env.id("room"),
        "hostParticipantId": env.id("host"),
        "payerId": env.id("host"),
        "participants": [{"id": env.id("host"), "displayName": "Riley"}],
        "receipt": {
            "merchant": "M",
            "date": "2026-09-24",
            "currency": "USD",
            "total": 950,
            "items": [{"id": env.id("i"), "name": "A", "lineTotal": 950}],
            "charges": [{"id": env.id("c"), "kind": "tax", "label": "T", "amount": 1}],
        },
    }
    mutate(body)
    response = env.client.post(ROOM, json=body, headers=HOST)
    assert 400 <= response.status_code < 500
    assert response.json["error"]["code"] in STATUS_FOR_CODE


def test_oversized_and_non_json_requests(env: Env) -> None:
    publish(env)
    huge = {"payload": "x" * 400_000}
    response = env.client.post(f"{ROOM}/{env.id('room')}/commands", data=json.dumps(huge), content_type="application/json", headers=HOST)
    assert response.status_code == 413 and response.json["error"]["code"] == "payload_too_large"
    response = env.client.post(f"{ROOM}/{env.id('room')}/commands", data="not json", content_type="text/plain", headers=HOST)
    assert response.status_code == 400


# MARK: - Authorization matrix (§8.3)


HOST_ONLY = [
    ("resolveDispute", lambda env: {"disputeId": str(uuid.uuid4()), "status": "resolved"}),
    ("setChargeAllocation", lambda env: {"chargeId": env.id("tax"), "allocation": {"kind": "payer"}}),
    ("reviseReceipt", lambda env: {"receipt": {}}),
    ("transition", lambda env: {"move": "beginResolving"}),
    ("cancel", lambda env: {}),
    ("removeParticipant", lambda env: {"participantId": env.id("host")}),
    ("setPayerAcceptsFullReceipt", lambda env: {"accepts": True}),
]


@pytest.mark.parametrize(("kind", "payload"), HOST_ONLY)
def test_guests_and_members_cannot_use_host_only_actions(env: Env, kind: str, payload: Any) -> None:
    publish(env)
    headers, _ = _guest(env)
    response = command(env, headers, kind, payload(env))
    assert response.status_code == 403 and response.json["error"]["code"] == "host_only"
    member = join(env, invite(env)["token"], "Maya", seatId=env.id("maya"))
    response = command(env, guest_headers(member["credential"]), kind, payload(env))
    assert response.json["error"]["code"] == "host_only"
    finalize = command(env, headers, "finalize", {}, path="finalize")
    assert finalize.json["error"]["code"] == "host_only"


def test_participants_can_claim_share_unclaim_dispute_and_review(env: Env) -> None:
    publish(env)
    headers, guest_id = _guest(env)
    assert command(env, headers, "claim", {"itemId": env.id("fries"), "request": "mine"}).status_code == 200
    assert command(env, HOST, "claim", {"itemId": env.id("fries"), "request": "share"}).status_code == 200
    assert command(env, headers, "dispute", {"target": {"kind": "item", "id": env.id("pizza")}, "note": "not mine"}).status_code == 200
    reviewed = command(env, headers, "markReviewed", {})
    assert reviewed.status_code == 200
    room = reviewed.json["room"]
    assert {"participantId": guest_id, "revision": room["revision"]} in room["reviews"]
    assert command(env, headers, "unclaim", {"itemId": env.id("fries")}).status_code == 200


def test_anonymous_and_outsiders_see_nothing(env: Env) -> None:
    publish(env)
    assert env.client.get(f"{ROOM}/{env.id('room')}").status_code == 401
    outsider = env.client.get(f"{ROOM}/{env.id('room')}", headers={"Authorization": "Bearer valid-outsider"})
    assert outsider.status_code == 404 and "room" not in outsider.json
    assert (
        command(
            env, {"Authorization": "Bearer valid-outsider"}, "claim", {"itemId": env.id("fries"), "request": "mine"}, revision=1
        ).status_code
        == 404
    )


def test_server_never_trusts_client_totals_or_roles(env: Env) -> None:
    publish(env)
    headers, guest_id = _guest(env)
    forged = command(
        env, headers, "claim", {"itemId": env.id("fries"), "request": "mine", "amount": 1, "isHost": True, "participantId": env.id("host")}
    )
    assert forged.status_code == 200
    room = forged.json["room"]
    assert room["claims"] == [{"itemId": env.id("fries"), "participantId": guest_id, "mode": {"kind": "full"}}]
    totals = {p["participantId"]: p["items"] for p in room["allocation"]["participants"]}
    assert totals[guest_id] == 950, "Computed by the server from the receipt, not from the request"


def test_development_tokens_are_refused_unless_enabled(env: Env) -> None:
    production = build(allow_dev_auth=False)
    publish_body = {"roomId": production.id("room")}
    response = production.client.post(ROOM, json=publish_body, headers={"Authorization": "Dev host"})
    assert response.status_code == 401


# MARK: - Revisions, conflicts, concurrency


def test_stale_revision_is_rejected_atomically_with_current_snapshot(env: Env) -> None:
    room = publish(env)
    headers, _ = _guest(env)
    stale = room["revision"]
    command(env, HOST, "claim", {"itemId": env.id("pizza"), "request": "mine"})
    response = command(env, headers, "claim", {"itemId": env.id("fries"), "request": "mine"}, revision=stale)
    assert response.status_code == 409
    assert response.json["error"]["code"] == "revision_conflict"
    assert response.json["error"]["currentRevision"] == response.json["room"]["revision"]
    assert [c["itemId"] for c in response.json["room"]["claims"]] == [env.id("pizza")], "Nothing partially applied"


def test_simultaneous_conflicting_claims_have_one_winner(env: Env) -> None:
    room = publish(env)
    first, first_id = _guest(env)
    second, second_id = _guest(env)
    revision = env.client.get(f"{ROOM}/{room['roomId']}", headers=HOST).json["room"]["revision"]
    results: dict[str, Any] = {}
    barrier = threading.Barrier(2)

    def attempt(name: str, headers: dict[str, str]) -> None:
        barrier.wait()
        with env.app.app_context():
            results[name] = command(env, headers, "claim", {"itemId": env.id("fries"), "request": "mine"}, revision=revision)

    threads = [threading.Thread(target=attempt, args=("a", first)), threading.Thread(target=attempt, args=("b", second))]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    codes = sorted(result.status_code for result in results.values())
    assert codes == [200, 409]
    final = env.client.get(f"{ROOM}/{room['roomId']}", headers=HOST).json["room"]
    assert len(final["claims"]) == 1 and final["claims"][0]["participantId"] in (first_id, second_id)


def test_over_allocation_is_refused(env: Env) -> None:
    publish(env)
    headers, guest_id = _guest(env)
    command(env, headers, "claim", {"itemId": env.id("fries"), "request": "share"})
    command(env, HOST, "claim", {"itemId": env.id("fries"), "request": "share"})
    response = command(
        env,
        HOST,
        "setItemSplit",
        {
            "itemId": env.id("fries"),
            "split": {
                "kind": "exact",
                "amounts": [{"participantId": guest_id, "amount": 900}, {"participantId": env.id("host"), "amount": 100}],
            },
        },
    )
    assert response.status_code == 422 and response.json["error"]["code"] == "invalid_split"
    assert response.json["error"]["remaining"] == -50


# MARK: - Idempotency and finalization


def test_retried_command_is_applied_once(env: Env) -> None:
    publish(env)
    headers, _ = _guest(env)
    revision = env.client.get(f"{ROOM}/{env.id('room')}", headers=headers).json["room"]["revision"]
    body = {
        "commandId": str(uuid.uuid4()),
        "idempotencyKey": "retry-key-1",
        "expectedRevision": revision,
        "type": "dispute",
        "payload": {"target": {"kind": "item", "id": env.id("pizza")}},
    }
    first = env.client.post(f"{ROOM}/{env.id('room')}/commands", json=body, headers=headers).json
    second = env.client.post(f"{ROOM}/{env.id('room')}/commands", json=body, headers=headers).json
    assert first["applied"] is True and second["replayed"] is True
    assert second["commandId"] == first["commandId"] and second["revision"] == first["revision"]
    assert len(second["room"]["disputes"]) == 1
    reused = dict(body, payload={"target": {"kind": "item", "id": env.id("fries")}})
    response = env.client.post(f"{ROOM}/{env.id('room')}/commands", json=reused, headers=headers)
    assert response.status_code == 422 and response.json["error"]["code"] == "idempotency_key_reused"


def test_idempotency_keys_are_scoped_to_the_caller(env: Env) -> None:
    publish(env)
    headers, _ = _guest(env)
    for caller in (headers, HOST):
        response = command(env, caller, "claim", {"itemId": env.id("fries"), "request": "share"}, key="same-key-123")
        assert response.status_code == 200 and response.json["replayed"] is False


def _ready_room(env: Env) -> None:
    publish(env)
    headers, _ = _guest(env)
    command(env, headers, "claim", {"itemId": env.id("fries"), "request": "mine"})
    command(env, HOST, "claim", {"itemId": env.id("pizza"), "request": "mine"})
    response = command(env, HOST, "transition", {"move": "requestFinalReview"})
    assert response.status_code == 200, response.json


def test_finalize_exactly_once(env: Env) -> None:
    _ready_room(env)
    first = command(env, HOST, "finalize", {}, path="finalize")
    assert first.status_code == 200 and first.json["applied"] is True
    room = first.json["room"]
    assert room["state"] == "finalized"
    final = room["finalization"]
    assert sum(p["total"] for p in final["participants"]) == final["total"] == 2165
    stale_retry = command(env, HOST, "finalize", {}, path="finalize", revision=1)
    assert stale_retry.status_code == 200 and stale_retry.json["applied"] is False
    assert stale_retry.json["room"]["finalization"] == final
    after = command(env, HOST, "claim", {"itemId": env.id("fries"), "request": "share"})
    assert after.status_code == 409 and after.json["error"]["code"] == "room_finalized"


def test_double_finalize_race_has_one_finalization(env: Env) -> None:
    _ready_room(env)
    revision = env.client.get(f"{ROOM}/{env.id('room')}", headers=HOST).json["room"]["revision"]
    results: list[Any] = []
    barrier = threading.Barrier(2)

    def attempt() -> None:
        barrier.wait()
        results.append(command(env, HOST, "finalize", {}, path="finalize", revision=revision))

    threads = [threading.Thread(target=attempt) for _ in range(2)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    applied = [result.json["applied"] for result in results]
    assert sorted(applied) == [False, True]


def test_finalize_blocked_by_open_dispute(env: Env) -> None:
    publish(env)
    headers, _ = _guest(env)
    command(env, headers, "claim", {"itemId": env.id("fries"), "request": "mine"})
    command(env, HOST, "claim", {"itemId": env.id("pizza"), "request": "mine"})
    command(env, headers, "dispute", {"target": {"kind": "charge", "id": env.id("tax")}})
    response = command(env, HOST, "transition", {"move": "requestFinalReview"})
    assert response.status_code == 409 and response.json["error"]["code"] == "not_ready_to_finalize"
    assert any(issue["kind"] == "openDispute" for issue in response.json["error"]["issues"])


# MARK: - Rate limiting


def test_join_is_rate_limited() -> None:
    limited = build(rate_limits={"preview": (3, 60), "join": (2, 60), "command": (100, 60), "publish": (100, 60), "asset": (10, 60)})
    publish(limited)
    token = invite(limited)["token"]
    statuses = [limited.client.post(f"/v1/receipt-room-invitations/{token}/join", json={"displayName": "S"}).status_code for _ in range(3)]
    assert statuses[:2] == [201, 201] and statuses[2] == 429
    response = limited.client.post(f"/v1/receipt-room-invitations/{token}/join", json={"displayName": "S"})
    assert response.json["error"]["code"] == "rate_limited" and int(response.headers["Retry-After"]) > 0
    limited.clock.advance(seconds=61)
    assert limited.client.post(f"/v1/receipt-room-invitations/{token}/join", json={"displayName": "S"}).status_code == 201


def test_token_guessing_is_rate_limited() -> None:
    limited = build(rate_limits={"preview": (5, 60), "join": (5, 60), "command": (100, 60), "publish": (100, 60), "asset": (10, 60)})
    codes = [limited.client.get(f"/v1/receipt-room-invitations/{'G' * 43}").status_code for _ in range(7)]
    assert codes[:5] == [404] * 5 and codes[5:] == [429, 429]


# MARK: - Receipt assets


def _jpeg_with_exif() -> bytes:
    app0 = b"\xff\xe0" + (16).to_bytes(2, "big") + b"JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00"
    exif = b"\xff\xe1" + (13).to_bytes(2, "big") + b"Exif\x00\x00GPS!!"
    comment = b"\xff\xfe" + (7).to_bytes(2, "big") + b"hello"
    scan = b"\xff\xda" + (8).to_bytes(2, "big") + b"\x01\x01\x00\x00\x3f\x00" + b"\x12\x34\x56" + b"\xff\xd9"
    return b"\xff\xd8" + app0 + exif + comment + scan


def test_metadata_is_stripped_from_jpegs() -> None:
    clean = strip_jpeg_metadata(_jpeg_with_exif())
    assert b"Exif" not in clean and b"GPS" not in clean and b"hello" not in clean
    assert clean.startswith(b"\xff\xd8\xff\xe0") and clean.endswith(b"\xff\xd9")


def test_assets_are_private_and_authorized(env: Env) -> None:
    publish(env)
    headers, _ = _guest(env)
    denied = env.client.post(f"{ROOM}/{env.id('room')}/receipt-assets", data=_jpeg_with_exif(), content_type="image/jpeg", headers=headers)
    assert denied.status_code == 403
    not_jpeg = env.client.post(f"{ROOM}/{env.id('room')}/receipt-assets", data=b"GIF89a....", content_type="image/jpeg", headers=HOST)
    assert not_jpeg.status_code == 415
    uploaded = env.client.post(f"{ROOM}/{env.id('room')}/receipt-assets", data=_jpeg_with_exif(), content_type="image/jpeg", headers=HOST)
    assert uploaded.status_code == 201
    asset_id = uploaded.json["assetId"]
    assert all(asset_id in name and "Fernwood" not in name for name in env.blobs.names())
    room = env.client.get(f"{ROOM}/{env.id('room')}", headers=headers).json["room"]
    assert room["assets"] == [{"id": asset_id}] and "http" not in json.dumps(room["assets"])
    image = env.client.get(f"{ROOM}/{env.id('room')}/receipt-assets/{asset_id}", headers=headers)
    assert image.status_code == 200 and image.mimetype == "image/jpeg" and b"Exif" not in image.data
    assert "no-store" in image.headers["Cache-Control"]
    assert env.client.get(f"{ROOM}/{env.id('room')}/receipt-assets/{asset_id}").status_code == 401
    outsider = env.client.get(f"{ROOM}/{env.id('room')}/receipt-assets/{asset_id}", headers={"Authorization": "Bearer valid-x"})
    assert outsider.status_code == 404


def test_asset_retention_after_room_finishes(env: Env) -> None:
    publish(env)
    env.client.post(f"{ROOM}/{env.id('room')}/receipt-assets", data=_jpeg_with_exif(), content_type="image/jpeg", headers=HOST)
    command(env, HOST, "cancel", {})
    env.clock.advance(days=29)
    assert env.client.get("/tasks/cleanup").json["removed"]["receiptImages"] == 0
    env.clock.advance(days=2)
    assert env.client.get("/tasks/cleanup").json["removed"]["receiptImages"] == 1
    assert env.blobs.names() == [] and env.store.count(ASSET) == 0
    room = env.client.get(f"{ROOM}/{env.id('room')}", headers=HOST).json["room"]
    assert room["assets"] == [] and room["receipt"]["items"], "Structured data remains"


def test_cleanup_removes_expired_records_and_requires_cron_in_production(env: Env) -> None:
    publish(env)
    command(env, HOST, "claim", {"itemId": env.id("fries"), "request": "mine"})
    assert env.store.count(IDEMPOTENCY) == 1
    env.clock.advance(days=3)
    removed = env.client.get("/tasks/cleanup").json["removed"]
    assert removed["idempotencyRecords"] == 1
    production = build(allow_dev_auth=False, environment="production")
    assert production.client.get("/tasks/cleanup").status_code == 403
    assert production.client.get("/tasks/cleanup", headers={"X-Appengine-Cron": "true"}).status_code == 200


# MARK: - Web surface, health, privacy


def test_health_readiness_and_request_ids(env: Env) -> None:
    response = env.client.get("/healthz", headers={"X-Request-Id": "abc123def456"})
    assert response.json == {"status": "ok"} and response.headers["X-Request-Id"] == "abc123def456"
    assert env.client.get("/readyz").status_code == 200
    assert len(env.client.get("/healthz", headers={"X-Request-Id": "<script>"}).headers["X-Request-Id"]) == 32


def test_invitation_page_and_aasa() -> None:
    # Identifiers alone don't make the App Clip available: the page never claims it before the app
    # has an App Store ID (the Smart App Banner needs one), and always offers the app and the code.
    prepared = build(apple_team_id="TEAMID1234", app_bundle_id="com.example.app", clip_bundle_id="com.example.app.Clip")
    page = prepared.client.get("/r/" + "T" * 43)
    assert page.status_code == 200 and "app-clip-bundle-id" not in page.text and "App Clip" not in page.text
    assert "short code" in page.text and "Open in Square Up" in page.text
    unconfigured = build().client.get("/r/" + "T" * 43)
    assert "App Clip" not in unconfigured.text and "apple-itunes-app" not in unconfigured.text
    configured = build(
        apple_team_id="TEAMID1234", app_bundle_id="com.example.app", clip_bundle_id="com.example.app.Clip", app_store_id="1234567890"
    )
    page = configured.client.get("/r/" + "T" * 43)
    assert page.status_code == 200 and "app-id=1234567890, app-clip-bundle-id=com.example.app.Clip" in page.text
    # The token appears only in the app's own link (it is already in the address bar), never as text.
    assert page.text.count("T" * 43) == 1
    assert f'href="squp://join/{"T" * 43}"' in page.text and "no-store" in page.headers["Cache-Control"]
    aasa = configured.client.get("/.well-known/apple-app-site-association").json
    assert aasa["appclips"] == {"apps": ["TEAMID1234.com.example.app.Clip"]}
    assert aasa["applinks"]["details"][0]["components"] == [{"/": "/r/*", "comment": "Receipt room invitations"}]
    assert build().client.get("/.well-known/apple-app-site-association").status_code == 404


def test_logs_never_contain_secrets_or_receipt_content(env: Env, caplog: pytest.LogCaptureFixture) -> None:
    captured = io.StringIO()
    logger = logging.getLogger("squareup")
    handler = logging.StreamHandler(captured)
    handler.setFormatter(logger.handlers[0].formatter)
    logger.addHandler(handler)
    try:
        with redirect_stdout(captured):
            publish(env)
            invitation = invite(env)
            joined = join(env, invitation["token"], "Samantha Secretname")
            command(
                env,
                guest_headers(joined["credential"]),
                "dispute",
                {"target": {"kind": "item", "id": env.id("fries")}, "note": "private note text"},
            )
    finally:
        logger.removeHandler(handler)
    text = captured.getvalue()
    assert "room.command" in text
    # Random request IDs and salted hashes are hex and can contain digit runs such as "950" by
    # chance; scan the log with those values removed so the amount checks below are meaningful.
    for line in text.splitlines():
        entry = json.loads(line)
        for key in ("requestId", "room"):
            if isinstance(entry.get(key), str):
                text = text.replace(entry[key], "<id>")
    for secret in (
        invitation["token"],
        joined["credential"],
        "Samantha",
        "Secretname",
        "Fernwood",
        "Truffle",
        "private note",
        env.id("room"),
        env.id("fries"),
        "valid-host-uid",
        "2165",
        "950",
    ):
        assert secret not in text, f"Leaked {secret[:12]}…"
