"""Who is calling.

Three credential types, all sent in the ``Authorization`` header:

- ``Bearer <Firebase ID token>`` — a full-app account, verified against Google's public keys
  (``google.oauth2.id_token.verify_firebase_token``) with the configured Firebase project as
  audience. The stable Firebase ``uid`` identifies the user. The account is *verified* when Firebase
  reports its email address as verified or it has a phone identity Firebase verified with an SMS
  code (``phone_number`` plus ``firebase.identities.phone``). Square Up never sends or checks codes.
- ``Guest <token>`` — a room-scoped guest credential issued by the server when an App Clip guest
  joins. Only its SHA-256 hash is stored. It works for exactly one room and expires.
- ``Dev <uid>`` — development and automated tests only. Refused unless explicitly enabled outside
  production and outside App Engine (see ``Config.from_environment``). A development account's
  verified email is ``<uid>@squareup.test`` (lower case), so "Find a person" can be tested.
- ``Demo <token>`` — one device's demo workspace ("Enter Demo", ``services.demo``), issued by the
  server with fictional sample data. Only its SHA-256 hash is stored; it expires. A demo account is
  its own isolated account: it can use shared groups, AI receipt scanning (on its own daily budget), and its own live rooms,
  but never "Find a person" or group invitation links, and no real account can find or join it.

A display name is never authentication.
"""

from __future__ import annotations

import hashlib
import hmac
import re
import secrets
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Any

from ..domain.errors import DomainError

_DEV_UID = re.compile(r"^[A-Za-z0-9_-]{3,64}$")
_E164 = re.compile(r"^\+[1-9][0-9]{6,14}$")


@dataclass(frozen=True)
class Principal:
    kind: str  # "user" | "guest"
    subject: str  # Firebase uid, or the guest credential hash
    room_id: str | None = None  # guests only
    participant_id: str | None = None  # guests only
    #: A Firebase account that can be recovered on another device (email/password), or a
    #: development account. Anonymous Firebase accounts and room guests are not recoverable, so
    #: they can't hold long-lived shared groups (milestone 7 §2.5).
    recoverable: bool = False
    #: Firebase reports the account's email address as verified (the ``email_verified`` claim).
    #: Development accounts count as verified.
    email_verified: bool = False
    #: The account has a phone number Firebase verified with an SMS code: an E.164 ``phone_number``
    #: claim that is also one of the token's ``firebase.identities.phone``.
    phone_verified: bool = False
    #: The verified email address (lower case) and verified E.164 phone number, used only to keep the
    #: account findable by "Find a person" (``AccountService.sync_directory``). Never stored as is,
    #: logged, or returned; kept out of ``repr`` so a stray log line can't carry them.
    email: str | None = field(default=None, repr=False)
    phone: str | None = field(default=None, repr=False)
    #: A demo workspace's account (``Demo <token>``): fictional data, isolated from real accounts.
    demo: bool = False

    @property
    def verified(self) -> bool:
        """A verified identity — a confirmed email or a verified phone number. Required for every
        account route, shared groups, receipt rooms with an account, and paid receipt intelligence."""
        return self.email_verified or self.phone_verified

    @property
    def binding(self) -> str:
        """The value stored on a participant seat bound to this principal."""
        return f"user:{self.subject}" if self.kind == "user" else f"guest:{self.subject}"


def new_secret_token() -> str:
    """256 bits from the OS CSPRNG, URL-safe (43 characters)."""
    return secrets.token_urlsafe(32)


def token_hash(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def hashes_match(stored: str, presented_token: str) -> bool:
    """Constant-time comparison of a stored hash with a presented token."""
    return hmac.compare_digest(stored, token_hash(presented_token))


TokenVerifier = Callable[[str], dict[str, Any]]


def firebase_verifier(project_id: str) -> TokenVerifier:
    """Verifies Firebase ID tokens. Imports lazily so tests don't need network access."""
    import google.auth.transport.requests
    import requests
    from cachecontrol import CacheControl
    from google.oauth2 import id_token

    session = CacheControl(requests.session())  # caches Google's signing certificates per HTTP cache headers
    transport = google.auth.transport.requests.Request(session=session)

    def verify(token: str) -> dict[str, Any]:
        claims: dict[str, Any] = id_token.verify_firebase_token(token, transport, audience=project_id)
        return claims

    return verify


def _has_verified_phone(claims: dict[str, Any]) -> bool:
    """Firebase puts ``phone_number`` on a token only for an account with a phone identity, which it
    verified with a code; both must agree before the number counts."""
    phone = claims.get("phone_number")
    firebase = claims.get("firebase")
    identities = firebase.get("identities") if isinstance(firebase, dict) else None
    numbers = identities.get("phone") if isinstance(identities, dict) else None
    return isinstance(phone, str) and _E164.match(phone) is not None and isinstance(numbers, list) and phone in numbers


def parse_authorization(
    header: str | None,
    *,
    verify_firebase: TokenVerifier | None,
    allow_dev: bool,
    resolve_guest: Callable[[str], Principal | None],
    resolve_demo: Callable[[str], Principal | None] | None = None,
) -> Principal | None:
    """Return the caller, ``None`` for an anonymous request, or raise ``unauthenticated``."""
    if not header:
        return None
    scheme, _, credential = header.partition(" ")
    credential = credential.strip()
    if not credential or len(credential) > 4096:
        raise DomainError("unauthenticated", "Sign in again")
    if scheme == "Bearer":
        if verify_firebase is None:
            raise DomainError("unauthenticated", "Account sign-in isn't configured on this server")
        try:
            claims = verify_firebase(credential)
        except Exception as error:
            raise DomainError("unauthenticated", "Sign in again") from error
        uid = claims.get("uid") or claims.get("sub") or claims.get("user_id")
        if not isinstance(uid, str) or not uid:
            raise DomainError("unauthenticated", "Sign in again")
        firebase = claims.get("firebase")
        provider = firebase.get("sign_in_provider") if isinstance(firebase, dict) else None
        email_verified = claims.get("email_verified") is True
        phone_verified = _has_verified_phone(claims)
        email = claims.get("email")
        return Principal(
            "user",
            uid,
            recoverable=provider not in (None, "anonymous", "custom"),
            email_verified=email_verified,
            phone_verified=phone_verified,
            email=email.strip().lower() if email_verified and isinstance(email, str) and email.strip() else None,
            phone=claims["phone_number"] if phone_verified else None,
        )
    if scheme == "Guest":
        principal = resolve_guest(credential)
        if principal is None:
            raise DomainError("credential_expired", "Your guest access ended. Open the invitation again")
        return principal
    if scheme == "Demo":
        principal = resolve_demo(credential) if resolve_demo is not None else None
        if principal is None:
            # The app treats this like any ended session (back to Welcome) and explains it's the demo.
            raise DomainError("unauthenticated", "This demo ended. Enter the demo again for a fresh copy")
        return principal
    if scheme == "Dev" and allow_dev and _DEV_UID.match(credential):
        return Principal("user", f"dev-{credential}", recoverable=True, email_verified=True, email=f"{credential.lower()}@squareup.test")
    raise DomainError("unauthenticated", "Unsupported credentials")
