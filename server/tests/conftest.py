"""Shared fixtures: an app over in-memory storage with a controllable clock and fake Firebase tokens."""

from __future__ import annotations

import os
import uuid
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from typing import Any

import pytest
from flask import Flask
from flask.testing import FlaskClient

# Never read the developer's gitignored server/.env (it may hold a real ANTHROPIC_API_KEY): a test
# must not be able to make a paid provider call by accident. Set before anything imports ``main``.
os.environ["SQUAREUP_SKIP_LOCAL_ENV"] = "1"
if os.environ.get("SQUAREUP_RUN_LIVE") != "1":
    os.environ.pop("ANTHROPIC_API_KEY", None)
    # Deployment settings exported into the shell (scripts/deploy.sh sources deploy.env) must not
    # turn on AI or point a test at Secret Manager.
    for name in [name for name in os.environ if name.startswith("SQUAREUP_AI_")] + ["SQUAREUP_ANTHROPIC_SECRET"]:
        os.environ.pop(name, None)

from squareup import create_app
from squareup.config import Config
from squareup.intelligence import secret_manager
from squareup.storage.blobs import MemoryBlobStore
from squareup.storage.memory import MemoryStore


class Clock:
    def __init__(self) -> None:
        self.now = datetime(2026, 9, 25, 12, tzinfo=UTC)

    def __call__(self) -> datetime:
        return self.now

    def advance(self, **delta: float) -> None:
        self.now += timedelta(**delta)


@pytest.fixture(autouse=True)
def _no_google_secret_manager(monkeypatch: pytest.MonkeyPatch) -> None:
    """Automated tests never reach Google Cloud: a real Secret Manager lookup fails loudly."""

    def refuse() -> secret_manager.SecretAccessor:
        raise AssertionError("A test tried to contact Google Secret Manager")

    monkeypatch.setattr(secret_manager, "google_secret_accessor", refuse)


def fake_firebase(token: str) -> dict[str, Any]:
    """``valid-<uid>``: an email/password account with a verified address (``<uid>@example.com``).
    ``unverified-<uid>``: the same, address not verified. ``anon-<uid>``: an anonymous Firebase
    account. ``phone-<uid>``: an account signed in with a phone number Firebase verified (a fictional
    number). ``tel<digits>-<uid>``: the same with the number ``+<digits>``. Anything else fails
    verification like a forged token."""
    if token.startswith(("valid-", "unverified-")):
        verified, _, uid = token.partition("-")
        email = f"{uid}@example.com"
        return {"uid": uid, "sub": uid, "email": email, "email_verified": verified == "valid", "firebase": {"sign_in_provider": "password"}}
    if token.startswith("anon-"):
        uid = token.removeprefix("anon-")
        return {"uid": uid, "sub": uid, "firebase": {"sign_in_provider": "anonymous"}}
    if token.startswith(("phone-", "tel")):
        digits, _, uid = token.removeprefix("tel").partition("-") if token.startswith("tel") else ("16505553434", "", token[6:])
        number = f"+{digits}"
        firebase = {"sign_in_provider": "phone", "identities": {"phone": [number]}}
        return {"uid": uid, "sub": uid, "phone_number": number, "firebase": firebase}
    raise ValueError("bad token")


@dataclass
class Env:
    app: Flask
    client: FlaskClient
    store: Any  # MemoryStore, or DatastoreStore against the emulator (both provide ``count``)
    blobs: MemoryBlobStore
    clock: Clock
    ids: dict[str, str] = field(default_factory=dict)

    def id(self, key: str) -> str:
        return self.ids.setdefault(key, str(uuid.uuid4()))


def test_store() -> Any:
    """``SQUAREUP_TEST_STORE=datastore`` runs the whole suite against the Datastore emulator."""
    if os.environ.get("SQUAREUP_TEST_STORE") == "datastore":
        from squareup.storage.datastore_store import DatastoreStore

        return DatastoreStore(os.environ.get("DATASTORE_PROJECT_ID", "squareup-emulator"), namespace=f"t{uuid.uuid4().hex}")
    return MemoryStore()


def build(intelligence_provider: Any = None, **overrides: Any) -> Env:
    clock = Clock()
    store, blobs = test_store(), MemoryBlobStore()
    settings: dict[str, Any] = {"environment": "test", "allow_dev_auth": True, "public_base_url": "https://squareup.example"}
    config = Config(**{**settings, **overrides})
    app = create_app(
        config, store=store, blobs=blobs, clock=clock, verify_firebase=fake_firebase, intelligence_provider=intelligence_provider
    )
    return Env(app, app.test_client(), store, blobs, clock)


@pytest.fixture
def env() -> Env:
    return build()


HOST = {"Authorization": "Bearer valid-host-uid"}


def receipt(env: Env) -> dict[str, Any]:
    return {
        "merchant": "Fernwood Supper Club",
        "date": "2026-09-24",
        "currency": "USD",
        "total": 2165,
        "items": [
            {"id": env.id("fries"), "name": "Truffle Fries", "lineTotal": 950},
            {"id": env.id("pizza"), "name": "Pizza", "lineTotal": 1000},
        ],
        "charges": [{"id": env.id("tax"), "kind": "tax", "label": "Tax", "amount": 215}],
    }


def publish(env: Env, **extra: Any) -> dict[str, Any]:
    body = {
        "roomId": env.id("room"),
        "hostParticipantId": env.id("host"),
        "payerId": env.id("host"),
        "participants": [{"id": env.id("host"), "displayName": "Riley"}, {"id": env.id("maya"), "displayName": "Maya"}],
        "receipt": receipt(env),
        **extra,
    }
    response = env.client.post("/v1/receipt-rooms", json=body, headers=HOST)
    assert response.status_code in (200, 201), response.json
    room: dict[str, Any] = response.json["room"]
    return room


def invite(env: Env, **options: Any) -> dict[str, Any]:
    response = env.client.post(f"/v1/receipt-rooms/{env.id('room')}/invitations", json=options, headers=HOST)
    assert response.status_code == 201, response.json
    invitation: dict[str, Any] = response.json["invitation"]
    return invitation


def join(env: Env, token: str, name: str = "Sam", **body: Any) -> dict[str, Any]:
    response = env.client.post(f"/v1/receipt-room-invitations/{token}/join", json={"displayName": name, **body})
    assert response.status_code in (200, 201), response.json
    assert response.json is not None
    result: dict[str, Any] = response.json
    return result


def command(
    env: Env,
    headers: dict[str, str],
    kind: str,
    payload: dict[str, Any],
    *,
    revision: int | None = None,
    key: str | None = None,
    path: str = "commands",
) -> Any:
    if revision is None:
        revision = env.client.get(f"/v1/receipt-rooms/{env.id('room')}", headers=headers).json["room"]["revision"]
    body = {
        "commandId": str(uuid.uuid4()),
        "idempotencyKey": key or uuid.uuid4().hex,
        "expectedRevision": revision,
        "type": kind,
        "payload": payload,
    }
    return env.client.post(f"/v1/receipt-rooms/{env.id('room')}/{path}", json=body, headers=headers)


def guest_headers(credential: str) -> dict[str, str]:
    return {"Authorization": f"Guest {credential}"}
