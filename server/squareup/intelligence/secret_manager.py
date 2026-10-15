"""The Anthropic API key from Google Secret Manager (production).

The key is read once, at startup, from the version named by ``SQUAREUP_ANTHROPIC_SECRET`` (for
example ``projects/<project>/secrets/anthropic-api-key/versions/latest``) with Application Default
Credentials — on App Engine, the app's service account. It is wrapped in :class:`Secret` straight
away and is never placed in ``Config``, Flask configuration, logs, exceptions, generated YAML, or
storage.

Every failure becomes a :class:`SecretUnavailable` that carries only a fixed reason code, never the
payload, the Google error message, or the response. Callers log that reason and, in production,
refuse to start.

The accessor is injectable: tests pass a fake, and nothing here contacts Google Cloud unless a real
lookup is asked for.
"""

from __future__ import annotations

from collections.abc import Callable
from typing import Protocol

from .settings import Secret, key_looks_valid

#: Reason codes (safe to log).
NOT_CONFIGURED = "secret_not_configured"
NOT_FOUND = "secret_not_found"
PERMISSION_DENIED = "secret_permission_denied"
DISABLED = "secret_disabled"
CHECKSUM_MISMATCH = "secret_checksum_mismatch"
MALFORMED = "secret_malformed"
UNAVAILABLE = "secret_unavailable"


class SecretUnavailable(Exception):
    """The key couldn't be loaded. Its only content is a reason code."""

    def __init__(self, reason: str) -> None:
        super().__init__(reason)
        self.reason = reason

    def __repr__(self) -> str:
        return f"SecretUnavailable({self.reason!r})"


class SecretPayload(Protocol):
    """The parts of Secret Manager's ``SecretPayload`` used here."""

    data: bytes
    data_crc32c: int


#: ``name -> payload``: Secret Manager's ``access_secret_version``, or a fake in tests.
SecretAccessor = Callable[[str], SecretPayload]


def google_secret_accessor() -> SecretAccessor:
    """The real accessor (Application Default Credentials). Imported lazily: only production startup calls it."""
    from google.cloud import secretmanager

    client = secretmanager.SecretManagerServiceClient()

    def access(name: str) -> SecretPayload:
        response = client.access_secret_version(request={"name": name})
        payload: SecretPayload = response.payload
        return payload

    return access


def _crc32c(data: bytes) -> int:
    import google_crc32c

    checksum = google_crc32c.Checksum()
    checksum.update(data)
    return int(checksum.hexdigest(), 16)


def _reason_for(error: Exception) -> str:
    """Maps Google API errors to a reason code without reading their messages."""
    try:
        from google.api_core import exceptions
    except ImportError:  # pragma: no cover - google-api-core is a runtime dependency
        return UNAVAILABLE
    if isinstance(error, exceptions.NotFound):
        return NOT_FOUND
    if isinstance(error, (exceptions.PermissionDenied, exceptions.Unauthenticated)):
        return PERMISSION_DENIED
    # A disabled or destroyed version is refused as a failed precondition.
    if isinstance(error, exceptions.FailedPrecondition):
        return DISABLED
    return UNAVAILABLE


def load_secret_key(name: str | None, accessor: SecretAccessor | None = None) -> Secret:
    """Reads, verifies, and wraps the key, or raises :class:`SecretUnavailable`.

    Verification follows Google's documented approach: compute CRC32C over the payload bytes and
    compare it with ``payload.data_crc32c`` before using the data. The decoded key must then have
    the shape of an Anthropic key.
    """
    if not name or not name.strip():
        raise SecretUnavailable(NOT_CONFIGURED)
    access = accessor or google_secret_accessor()
    try:
        payload = access(name.strip())
        data = bytes(payload.data)
        expected = payload.data_crc32c
    except SecretUnavailable:
        raise
    except Exception as error:
        # `from None`: Google's error text (with its own details) is never chained or shown.
        raise SecretUnavailable(_reason_for(error)) from None
    if not isinstance(expected, int) or expected <= 0 or _crc32c(data) != expected:
        raise SecretUnavailable(CHECKSUM_MISMATCH)
    try:
        text = data.decode("utf-8").strip()
    except UnicodeDecodeError:
        raise SecretUnavailable(MALFORMED) from None
    key = Secret(text)
    if not key_looks_valid(key):
        raise SecretUnavailable(MALFORMED)
    return key
