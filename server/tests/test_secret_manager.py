"""The Anthropic key from Secret Manager: loading, verification, failure handling, and privacy.

Every test injects a fake accessor shaped like Secret Manager's ``access_secret_version`` payload.
Nothing here contacts Google Cloud (``conftest`` makes a real lookup fail the test) or Anthropic.
"""

from __future__ import annotations

import io
import logging
from collections.abc import Callable
from contextlib import redirect_stdout
from dataclasses import dataclass
from typing import Any

import google_crc32c
import pytest
from google.api_core import exceptions as google_errors

from squareup import create_app, select_provider
from squareup.config import Config
from squareup.intelligence import secret_manager
from squareup.intelligence.anthropic_provider import ClaudeReceiptProvider
from squareup.intelligence.provider import FakeProvider, UnavailableProvider
from squareup.intelligence.secret_manager import SecretUnavailable, load_secret_key
from squareup.intelligence import settings
from squareup.intelligence.settings import IntelligenceSettings, Secret
from squareup.storage.blobs import MemoryBlobStore
from squareup.storage.memory import MemoryStore

RESOURCE = "projects/example-project/secrets/anthropic-api-key/versions/latest"
# The server accepts only keys shaped like Anthropic's (``settings._KEY_SHAPE``). The fake keys here
# take that required prefix from the rule itself at run time, so no key-like string is in this file;
# everything after it says plainly that these aren't credentials.
KEY_PREFIX = settings._KEY_SHAPE.pattern.removeprefix("^").split("[", 1)[0]
SECRET_KEY = KEY_PREFIX + "test-only-not-a-credential-secret-manager"
LOCAL_KEY = KEY_PREFIX + "test-only-not-a-credential-local-env"


def checksum(data: bytes) -> int:
    crc = google_crc32c.Checksum()
    crc.update(data)
    return int(crc.hexdigest(), 16)


@dataclass
class Payload:
    data: bytes
    data_crc32c: int


class FakeAccessor:
    """Answers like ``access_secret_version`` (a payload with bytes and their CRC32C) or raises."""

    def __init__(self, data: bytes = SECRET_KEY.encode(), *, crc: int | None = None, error: Exception | None = None) -> None:
        self.data = data
        self.crc = checksum(data) if crc is None else crc
        self.error = error
        self.names: list[str] = []

    def __call__(self, name: str) -> Payload:
        self.names.append(name)
        if self.error is not None:
            raise self.error
        return Payload(self.data, self.crc)


def never_called(name: str) -> Payload:
    raise AssertionError("Secret Manager must not be contacted here")


def config(provider: str = "anthropic", environment: str = "production", resource: str | None = RESOURCE) -> Config:
    return Config(environment=environment, intelligence=IntelligenceSettings(provider=provider, secret_resource=resource))


def captured_logs(action: Callable[[], Any]) -> str:
    from squareup.logging_setup import configure

    output = io.StringIO()
    logger = configure()
    handler = logging.StreamHandler(output)
    handler.setFormatter(logger.handlers[0].formatter)
    logger.addHandler(handler)
    try:
        with redirect_stdout(output):
            try:
                action()
            except Exception as error:
                print(repr(error), str(error))
    finally:
        logger.removeHandler(handler)
    return output.getvalue()


# MARK: - Loading and verifying


def test_a_verified_key_is_loaded_once_and_wrapped() -> None:
    accessor = FakeAccessor()
    key = load_secret_key(RESOURCE, accessor)
    assert isinstance(key, Secret) and key.reveal() == SECRET_KEY
    assert accessor.names == [RESOURCE]


def test_surrounding_whitespace_is_ignored() -> None:
    assert load_secret_key(RESOURCE, FakeAccessor((SECRET_KEY + "\n").encode())).reveal() == SECRET_KEY


@pytest.mark.parametrize(
    ("error", "reason"),
    [
        (google_errors.NotFound("Secret [projects/x/secrets/y] not found or has no versions."), secret_manager.NOT_FOUND),
        (google_errors.PermissionDenied("Permission 'secretmanager.versions.access' denied"), secret_manager.PERMISSION_DENIED),
        (google_errors.Unauthenticated("no credentials"), secret_manager.PERMISSION_DENIED),
        (google_errors.FailedPrecondition("Secret version is in DISABLED state."), secret_manager.DISABLED),
        (google_errors.ServiceUnavailable("try again"), secret_manager.UNAVAILABLE),
        (OSError("network unreachable"), secret_manager.UNAVAILABLE),
    ],
)
def test_access_failures_become_a_reason_code(error: Exception, reason: str) -> None:
    with pytest.raises(SecretUnavailable) as raised:
        load_secret_key(RESOURCE, FakeAccessor(error=error))
    assert raised.value.reason == reason and str(raised.value) == reason
    assert raised.value.__cause__ is None and raised.value.__suppress_context__, "Google's error text is never chained"


@pytest.mark.parametrize("crc", [1, 0, -5])
def test_a_checksum_mismatch_is_refused(crc: int) -> None:
    with pytest.raises(SecretUnavailable) as raised:
        load_secret_key(RESOURCE, FakeAccessor(crc=crc))
    assert raised.value.reason == secret_manager.CHECKSUM_MISMATCH


@pytest.mark.parametrize(
    "data", [b"", b"   ", b"not-an-anthropic-key-at-all", (KEY_PREFIX + "short").encode(), b"\xff\xfe\x00bad-bytes", KEY_PREFIX.encode() + b"a b" * 20]
)
def test_a_malformed_key_is_refused(data: bytes) -> None:
    with pytest.raises(SecretUnavailable) as raised:
        load_secret_key(RESOURCE, FakeAccessor(data))
    # An empty payload has CRC32C 0, which is refused as unverified before it's decoded.
    assert raised.value.reason == (secret_manager.CHECKSUM_MISMATCH if not data else secret_manager.MALFORMED)


@pytest.mark.parametrize("resource", [None, "", "   "])
def test_no_resource_means_no_lookup(resource: str | None) -> None:
    with pytest.raises(SecretUnavailable) as raised:
        load_secret_key(resource, never_called)
    assert raised.value.reason == secret_manager.NOT_CONFIGURED


# MARK: - Startup (provider selection)


def test_production_loads_the_key_from_secret_manager() -> None:
    accessor = FakeAccessor()
    provider = select_provider(config(), {}, secret_accessor=accessor)
    assert isinstance(provider, ClaudeReceiptProvider) and provider.available
    assert accessor.names == [RESOURCE]


def test_production_ignores_an_environment_key() -> None:
    accessor = FakeAccessor()
    provider = select_provider(config(), {"ANTHROPIC_API_KEY": LOCAL_KEY}, secret_accessor=accessor)
    assert isinstance(provider, ClaudeReceiptProvider)
    assert provider._key.reveal() == SECRET_KEY, "the environment variable is for local development only"


@pytest.mark.parametrize(
    "accessor",
    [
        FakeAccessor(error=google_errors.NotFound("missing")),
        FakeAccessor(error=google_errors.PermissionDenied("denied")),
        FakeAccessor(error=google_errors.FailedPrecondition("DISABLED")),
        FakeAccessor(crc=12345),
        FakeAccessor(b"not-a-key"),
    ],
)
def test_production_fails_closed_without_a_usable_key(accessor: FakeAccessor) -> None:
    with pytest.raises(RuntimeError) as raised:
        select_provider(config(), {}, secret_accessor=accessor)
    assert str(raised.value).startswith("Receipt intelligence can't start: secret_")
    assert raised.value.__cause__ is None


def test_production_with_ai_on_but_no_resource_fails_closed() -> None:
    with pytest.raises(RuntimeError, match="secret_not_configured"):
        select_provider(config(resource=None), {"ANTHROPIC_API_KEY": LOCAL_KEY}, secret_accessor=never_called)


@pytest.mark.parametrize("environment", ["production", "development"])
def test_ai_off_never_contacts_secret_manager(environment: str) -> None:
    provider = select_provider(config(provider="off", environment=environment), {}, secret_accessor=never_called)
    assert isinstance(provider, UnavailableProvider)


def test_local_development_uses_the_environment_key_first() -> None:
    provider = select_provider(config(environment="development"), {"ANTHROPIC_API_KEY": LOCAL_KEY}, secret_accessor=never_called)
    assert isinstance(provider, ClaudeReceiptProvider) and provider._key.reveal() == LOCAL_KEY


def test_local_development_without_a_key_keeps_the_server_running() -> None:
    failing = FakeAccessor(error=google_errors.PermissionDenied("denied"))
    provider = select_provider(config(environment="development"), {}, secret_accessor=failing)
    assert isinstance(provider, UnavailableProvider)
    no_resource = select_provider(config(environment="development", resource=None), {}, secret_accessor=never_called)
    assert isinstance(no_resource, UnavailableProvider)


def test_an_injected_provider_never_contacts_secret_manager() -> None:
    app = create_app(
        config(),
        store=MemoryStore(),
        blobs=MemoryBlobStore(),
        verify_firebase=lambda _: {},
        intelligence_provider=FakeProvider(),
        secret_accessor=never_called,
    )
    assert app.extensions["squareup"].intelligence.provider.available


def test_the_app_refuses_to_start_in_production_when_the_secret_is_unavailable() -> None:
    with pytest.raises(RuntimeError, match="secret_permission_denied"):
        create_app(
            config(),
            store=MemoryStore(),
            blobs=MemoryBlobStore(),
            verify_firebase=lambda _: {},
            secret_accessor=FakeAccessor(error=google_errors.PermissionDenied("denied")),
        )


def test_ordinary_tests_cannot_reach_google() -> None:
    with pytest.raises(AssertionError, match="Google Secret Manager"):
        secret_manager.google_secret_accessor()


# MARK: - Privacy


def test_logs_errors_and_representations_never_contain_the_key() -> None:
    accessor = FakeAccessor()
    loaded = captured_logs(lambda: print(repr(select_provider(config(), {}, secret_accessor=accessor).__dict__)))
    assert '"ai.key_loaded"' in loaded and SECRET_KEY not in loaded
    for broken in (
        FakeAccessor(crc=7),
        FakeAccessor((SECRET_KEY + " extra words").encode()),
        FakeAccessor(error=google_errors.NotFound(SECRET_KEY)),
    ):

        def start(accessor: FakeAccessor = broken) -> None:
            select_provider(config(), {}, secret_accessor=accessor)

        logs = captured_logs(start)
        assert '"ai.unavailable"' in logs and "secret_" in logs
        assert SECRET_KEY not in logs and "extra words" not in logs
    key = load_secret_key(RESOURCE, FakeAccessor())
    assert SECRET_KEY not in repr(key) and SECRET_KEY not in str(key) and SECRET_KEY not in f"{key}"
    assert SECRET_KEY not in repr(SecretUnavailable(secret_manager.MALFORMED))


def test_the_key_is_not_kept_in_configuration() -> None:
    accessor = FakeAccessor()
    app = create_app(config(), store=MemoryStore(), blobs=MemoryBlobStore(), verify_firebase=lambda _: {}, secret_accessor=accessor)
    assert SECRET_KEY not in repr(app.config) and SECRET_KEY not in repr(app.extensions["squareup"].ctx.config)
    assert accessor.names == [RESOURCE], "read once, at startup"
