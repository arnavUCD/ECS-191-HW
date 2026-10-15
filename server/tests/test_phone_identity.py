"""Phone sign-in (Firebase phone authentication): an account with a phone number Firebase verified
with an SMS code is a verified identity, like a confirmed email. Square Up never sends or checks
codes; the Firebase ID token is the only source of truth. Anonymous accounts stay restricted, and
nothing else about authorization changes. Numbers are fictional."""

from __future__ import annotations

import logging
import uuid
from typing import Any

import pytest

from squareup.auth.identity import parse_authorization
from squareup.domain.errors import DomainError

from .conftest import Env
from .group_kit import create_group

PHONE = {"Authorization": "Bearer phone-paula"}
NUMBER = "+16505553434"


def _principal(claims: dict[str, Any]) -> Any:
    return parse_authorization("Bearer token", verify_firebase=lambda _: claims, allow_dev=False, resolve_guest=lambda _: None)


def _claims(**extra: Any) -> dict[str, Any]:
    return {"uid": "u1", "sub": "u1", **extra}


def test_a_firebase_verified_phone_number_is_a_verified_identity() -> None:
    principal = _principal(_claims(phone_number=NUMBER, firebase={"sign_in_provider": "phone", "identities": {"phone": [NUMBER]}}))
    assert principal.phone_verified and principal.verified and not principal.email_verified
    assert principal.recoverable, "a phone account comes back on another device"


def test_email_verification_is_unchanged() -> None:
    verified = _principal(_claims(email_verified=True, firebase={"sign_in_provider": "password"}))
    unverified = _principal(_claims(email_verified=False, firebase={"sign_in_provider": "password"}))
    assert verified.verified and not verified.phone_verified
    assert not unverified.verified


def test_a_phone_number_counts_only_as_a_firebase_phone_identity() -> None:
    no_identity = _principal(_claims(phone_number=NUMBER, firebase={"sign_in_provider": "phone"}))

    def phone(number: Any, identities: list[Any]) -> Any:
        return _principal(_claims(phone_number=number, firebase={"sign_in_provider": "phone", "identities": {"phone": identities}}))

    other_number = phone(NUMBER, ["+16505550000"])
    malformed = phone("6505553434", ["6505553434"])
    not_a_string = phone(16505553434, [16505553434])
    for principal in (no_identity, other_number, malformed, not_a_string):
        assert not principal.phone_verified and not principal.verified


def test_an_anonymous_account_stays_restricted_whatever_its_claims() -> None:
    principal = _principal(_claims(phone_number=NUMBER, firebase={"sign_in_provider": "anonymous", "identities": {"phone": [NUMBER]}}))
    assert not principal.recoverable, "anonymous sign-ins never become full accounts"


def test_token_verification_is_not_weakened() -> None:
    def forged(_: str) -> dict[str, Any]:
        raise ValueError("bad signature")

    with pytest.raises(DomainError) as refused:
        parse_authorization("Bearer forged", verify_firebase=forged, allow_dev=False, resolve_guest=lambda _: None)
    assert refused.value.code == "unauthenticated"


def test_a_phone_account_uses_accounts_groups_and_rooms(env: Env) -> None:
    status = env.client.get("/v1/account", headers=PHONE).json["account"]
    assert status == {"recoverable": True, "emailVerified": False, "phoneVerified": True, "verified": True, "profile": None}
    saved = env.client.put("/v1/account/profile", json={"displayName": "Paula", "locale": "en_US"}, headers=PHONE)
    assert saved.status_code == 200, saved.json
    group = env.client.post(
        "/v1/groups", json={"groupId": str(uuid.uuid4()), "name": "Phone Group", "symbol": "phone", "currency": "USD"}, headers=PHONE
    )
    assert group.status_code in (200, 201), group.json
    room = env.client.post(
        "/v1/receipt-rooms",
        json={
            "kind": "temporary",
            "roomId": str(uuid.uuid4()),
            "hostParticipantId": (host := str(uuid.uuid4())),
            "payerId": host,
            "participants": [{"id": host, "displayName": "Paula"}],
            "receipt": {
                "merchant": "Kiosk",
                "date": "2026-10-13",
                "currency": "USD",
                "total": 500,
                "items": [{"id": str(uuid.uuid4()), "name": "Tea", "lineTotal": 500}],
                "charges": [],
            },
        },
        headers=PHONE,
    )
    assert room.status_code in (200, 201), room.json


def test_a_phone_account_passes_the_ai_verification_gate(env: Env) -> None:
    response = env.client.post("/v1/receipt-intelligence/parse", json={}, headers=PHONE)
    assert not (response.status_code == 403 and response.json["error"]["code"] == "email_not_verified")


def test_other_peoples_groups_stay_closed_to_a_phone_account(env: Env) -> None:
    snapshot = create_group(env, "riley")
    group_id = snapshot["group"]["id"]
    env.client.put("/v1/account/profile", json={"displayName": "Paula"}, headers=PHONE)
    response = env.client.get(f"/v1/groups/{group_id}", headers=PHONE)
    assert response.status_code == 404 and response.json["error"]["code"] == "group_not_found", "verification never grants membership"


def test_the_phone_number_never_reaches_the_logs(env: Env, caplog: pytest.LogCaptureFixture) -> None:
    caplog.set_level(logging.DEBUG)
    env.client.get("/v1/account", headers=PHONE)
    env.client.put("/v1/account/profile", json={"displayName": "Paula"}, headers=PHONE)
    env.client.get("/v1/groups", headers=PHONE)
    logged = "\n".join(record.getMessage() for record in caplog.records)
    assert NUMBER not in logged and "6505553434" not in logged
