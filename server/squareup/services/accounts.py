"""Account profiles and payment destinations (milestone 7 §3.1, §10.1).

A profile belongs to one Firebase account (keyed by its uid) and holds only what the product
needs: a stable member ID, a display name, locale and currency hints, and the person's own
payment destinations. Destinations are validated again here (the app validates first), so a
modified client can't store an unsafe link or a malformed identifier.

Destination identifiers are sensitive. They're returned in full only to their owner, and to a
group member who currently owes the owner (``GroupService.reveal_destinations``). Logs never
contain them.

The account directory ("Find a person") maps a digest of each *verified* identifier — the email
address Firebase confirmed, the phone number it verified — to the account, once the account has a
profile. It follows the sign-in token: an identifier that stops being verified on the account, or
moves to another account, stops finding it. The store never holds the address or number itself.
"""

from __future__ import annotations

import re
import uuid
from typing import Any
from urllib.parse import urlsplit

from ..auth.identity import Principal, token_hash
from ..domain.errors import DomainError
from ..domain.room import require_text, require_uuid
from ..ledger.group import PROVIDERS, require_currency, require_dict
from ..logging_setup import log_event, redact
from ..storage.base import ACCOUNT, ACCOUNT_DIRECTORY, Transaction
from .context import ServiceContext

MAX_DESTINATIONS = 12
MAX_DISPLAY_NAME = 60
MAX_LABEL = 40
MAX_INSTRUCTIONS = 140

_PHONE = re.compile(r"^\+1[2-9]\d{2}[2-9]\d{6}$")
_EMAIL = re.compile(r"^[a-z0-9._%+\-]+@[a-z0-9\-]+(\.[a-z0-9\-]+)*\.[a-z]{2,}$")
_PAYPAL = re.compile(r"^[A-Za-z0-9]{1,20}$")
_CASHTAG = re.compile(r"^(?=.*[A-Za-z])[A-Za-z0-9]{1,20}$")
_VENMO = re.compile(r"^[A-Za-z0-9_\-]{5,30}$")
_LOCALE = re.compile(r"^[A-Za-z]{2,3}([_-][A-Za-z0-9]{2,8}){0,3}$")
#: "Find a person": any address Firebase could have verified (one @, a dotted domain, no spaces),
#: and any E.164 number.
_LOOKUP_EMAIL = re.compile(r"^[^@\s]{1,64}@[^@\s]+\.[^@\s]+$")
_E164 = re.compile(r"^\+[1-9][0-9]{6,14}$")

#: ``ExternalURLPolicy.allowedHosts``: a leading "." also allows subdomains.
_ALLOWED_HOSTS: dict[str, tuple[str, ...]] = {
    "paypal": ("paypal.me", "www.paypal.me", "paypal.com", "www.paypal.com"),
    "cashApp": ("cash.app",),
    "zelle": (".zelle.com", ".zellepay.com"),
}

#: Which value kinds each provider accepts (``PaymentDestinationValidator``).
_VALUE_KINDS: dict[str, tuple[str, ...]] = {
    "appleCash": ("phone", "email"),
    "paypal": ("username",),
    "cashApp": ("username", "link"),
    "zelle": ("phone", "email"),
    "venmo": ("username",),
    "cash": ("instructions",),
    "other": ("instructions",),
}


def link_allowed(url: str, provider: str) -> bool:
    """``ExternalURLPolicy.isAllowed``: HTTPS, no credentials, default port, allowlisted host."""
    if len(url) > 512 or any(character.isspace() for character in url):
        return False
    try:
        parts = urlsplit(url)
        port = parts.port
    except ValueError:
        return False
    host = (parts.hostname or "").lower()
    if parts.scheme.lower() != "https" or parts.username or parts.password or port not in (None, 443) or not host:
        return False
    for allowed in _ALLOWED_HOSTS.get(provider, ()):
        if allowed.startswith("."):
            if host == allowed[1:] or host.endswith(allowed):
                return True
        elif host == allowed:
            return True
    return False


def _value_is_valid(provider: str, kind: str, text: str) -> bool:
    if kind == "phone":
        return bool(_PHONE.match(text))
    if kind == "email":
        return len(text) <= 254 and bool(_EMAIL.match(text))
    if kind == "username":
        return bool({"paypal": _PAYPAL, "cashApp": _CASHTAG, "venmo": _VENMO}[provider].match(text))
    if kind == "link":
        path = urlsplit(text).path if link_allowed(text, provider) else ""
        return bool(path) and (provider != "cashApp" or (len(path) > 2 and path.startswith("/$")))
    return 0 < len(text) <= MAX_INSTRUCTIONS


def parse_destination(raw: object, destination_id: str, now: str, existing: dict[str, Any] | None) -> dict[str, Any]:
    raw = require_dict(raw, "destination")
    provider = raw.get("provider")
    if provider not in PROVIDERS:
        raise DomainError("invalid_destination", "Unknown payment method")
    value = require_dict(raw.get("value"), "value")
    kind = value.get("kind")
    text = value.get("value")
    if kind not in _VALUE_KINDS[provider] or not isinstance(text, str):
        raise DomainError("invalid_destination", "That isn't a valid value for this payment method")
    valid = _value_is_valid(provider, kind, text)
    if not valid:
        raise DomainError("invalid_destination", "That isn't a valid value for this payment method")
    link = raw.get("link")
    if link is not None and (provider not in ("cashApp", "zelle") or not isinstance(link, str) or not link_allowed(link, provider)):
        raise DomainError("invalid_destination", "That link isn't allowed for this payment method")
    label = raw.get("label")
    if label is not None:
        label = require_text(label, "label", max_length=MAX_LABEL, allow_empty=True) or None
    if provider == "other" and not label:
        raise DomainError("invalid_destination", "Name this payment method")
    enabled = raw.get("isEnabled", True)
    preferred = raw.get("isPreferred", False)
    if not isinstance(enabled, bool) or not isinstance(preferred, bool):
        raise DomainError("invalid_payload", "isEnabled and isPreferred must be true or false")
    return {
        "id": destination_id,
        "provider": provider,
        "value": {"kind": kind, "value": text},
        "link": link,
        "label": label,
        "isEnabled": enabled,
        "isPreferred": preferred and enabled,
        "createdAt": existing["createdAt"] if existing else now,
        "updatedAt": now,
    }


def directory_key(kind: str, value: str) -> str:
    """The directory's key for one normalized identifier: a digest, never the identifier."""
    return token_hash(f"squareup.directory.v1|{kind}|{value}")


def parse_identifier(body: object) -> tuple[str, str]:
    """``("email" | "phone", normalized value)`` from ``{"email": …}`` or ``{"phone": "+…"}``.
    Emails are trimmed and lower-cased; phone numbers must already be E.164 (the app formats them)."""
    body = require_dict(body, "person")
    email, phone = body.get("email"), body.get("phone")
    if (email is None) == (phone is None):
        raise DomainError("invalid_payload", "Enter an email address or a phone number")
    if email is not None:
        value = email.strip().lower() if isinstance(email, str) else ""
        if len(value) > 254 or not _LOOKUP_EMAIL.match(value):
            raise DomainError("invalid_payload", "Enter a valid email address")
        return "email", value
    value = phone.strip() if isinstance(phone, str) else ""
    if not _E164.match(value):
        raise DomainError("invalid_payload", "Enter the phone number with its country code")
    return "phone", value


def masked_identifier(kind: str, value: str) -> str:
    """Enough to tell which address or number matched, without showing it: ``s•••@example.com``,
    ``•••• 3434``."""
    if kind == "email":
        local, _, domain = value.partition("@")
        return f"{local[:1]}•••@{domain}"
    return f"•••• {value[-4:]}"


def destination_summary(destination: dict[str, Any]) -> dict[str, Any]:
    """What other members may see without an obligation: the method, never the identifier."""
    return {"id": destination["id"], "provider": destination["provider"], "isPreferred": destination["isPreferred"]}


class AccountService:
    def __init__(self, ctx: ServiceContext) -> None:
        self.ctx = ctx

    @staticmethod
    def require_account(principal: Principal | None) -> Principal:
        """A recoverable account (email/password, phone, or a development account on a local server)
        with a verified identity: an email Firebase confirmed or a phone number it verified. Applies to
        every account and shared-group route. The refusal names the requirement only — never the
        account's claims. (An unverified account is always an email one: phone numbers are verified
        by their code before the account exists.)"""
        if principal is None or principal.kind != "user":
            raise DomainError("unauthenticated", "Sign in to use shared groups")
        if principal.demo:
            return principal  # its own isolated workspace of fictional data (``services.demo``)
        if not principal.recoverable:
            raise DomainError("account_required", "Create an account with your email or phone number to use shared groups")
        if not principal.verified:
            raise DomainError("email_not_verified", "Verify your email address to use shared groups")
        return principal

    @staticmethod
    def refuse_demo(principal: Principal | None, what: str) -> None:
        """Demo accounts stay among their own fictional people: nothing that reaches a real account,
        an invitation link, or a paid service."""
        if principal is not None and principal.demo:
            raise DomainError("demo_restricted", f"{what} isn't available in the demo")

    def profile(self, uid: str) -> dict[str, Any] | None:
        return self.ctx.store.get(ACCOUNT, uid)

    def account(self, principal: Principal | None) -> dict[str, Any]:
        """Account status and the profile, if one exists. Works for any signed-in account, verified or
        not, so the app can tell what's missing; everything else needs ``require_account``."""
        if principal is None or principal.kind != "user":
            raise DomainError("unauthenticated", "Sign in to continue")
        profile = self.profile(principal.subject)
        if profile is not None:
            self.sync_directory(principal, profile)
        status: dict[str, Any] = {
            "recoverable": principal.recoverable,
            "emailVerified": principal.email_verified,
            "phoneVerified": principal.phone_verified,
            "verified": principal.verified,
            "profile": None if profile is None else self.profile_view(profile),
        }
        if principal.demo:
            status["demo"] = True  # only a demo workspace's answer changes
        return status

    @staticmethod
    def profile_view(profile: dict[str, Any]) -> dict[str, Any]:
        return {
            "memberId": profile["memberId"],
            "displayName": profile["displayName"],
            "locale": profile.get("locale"),
            "currency": profile.get("currency"),
            "destinations": profile["destinations"],
            "createdAt": profile["createdAt"],
            "updatedAt": profile["updatedAt"],
        }

    def save_profile(self, principal: Principal | None, body: object) -> dict[str, Any]:
        caller = self.require_account(principal)
        body = require_dict(body, "profile")
        display_name = require_text(body.get("displayName"), "displayName", max_length=MAX_DISPLAY_NAME)
        locale = body.get("locale")
        if locale is not None and (not isinstance(locale, str) or not _LOCALE.match(locale)):
            raise DomainError("invalid_payload", "locale must look like en_US")
        currency = body.get("currency")
        if currency is not None:
            currency = require_currency(currency)
        proposed = body.get("memberId")
        now = self.ctx.now_iso()

        def body_fn(transaction: Transaction) -> dict[str, Any]:
            profile = transaction.get(ACCOUNT, caller.subject)
            if profile is None:
                # The app proposes a fresh random ID; anything else gets a server-generated one.
                member_id = require_uuid(proposed, "memberId") if isinstance(proposed, str) else str(uuid.uuid4())
                profile = {"memberId": member_id, "destinations": [], "createdAt": now}
            profile.update({"displayName": display_name, "locale": locale, "currency": currency, "updatedAt": now})
            transaction.put(ACCOUNT, caller.subject, profile)
            return profile

        profile = self.ctx.store.run_in_transaction(body_fn)
        log_event("account.profileSaved", account=redact(caller.subject))
        self.sync_directory(caller, profile)
        return self.profile_view(profile)

    # MARK: - Directory ("Find a person")

    def sync_directory(self, principal: Principal, profile: dict[str, Any]) -> None:
        """Keeps this account findable by its verified email and phone number, and by nothing else.
        Runs when the app reads the account (every launch) and when the name is saved; writes only
        when something changed. An entry another account has taken over since is left alone."""
        if principal.kind != "user" or not principal.recoverable or not principal.verified:
            return
        wanted = {kind: directory_key(kind, value) for kind, value in (("email", principal.email), ("phone", principal.phone)) if value}
        if profile.get("directory", {}) == wanted:
            return
        uid = principal.subject
        now = self.ctx.now_iso()

        def body_fn(transaction: Transaction) -> None:
            current = transaction.get(ACCOUNT, uid)
            if current is None:
                return
            for kind, key in current.get("directory", {}).items():
                if wanted.get(kind) != key:
                    entry = transaction.get(ACCOUNT_DIRECTORY, key)
                    if entry is not None and entry.get("uid") == uid:
                        transaction.delete(ACCOUNT_DIRECTORY, key)
            for kind, key in wanted.items():
                transaction.put(ACCOUNT_DIRECTORY, key, {"uid": uid, "kind": kind, "updatedAt": now})
            current["directory"] = wanted
            transaction.put(ACCOUNT, uid, current)

        self.ctx.store.run_in_transaction(body_fn)
        log_event("account.directorySynced", account=redact(uid), identifiers=len(wanted))

    def find(self, kind: str, value: str) -> tuple[str, dict[str, Any]] | None:
        """``(uid, profile)`` of the account this verified identifier belongs to, or ``None``."""
        key = directory_key(kind, value)
        entry = self.ctx.store.get(ACCOUNT_DIRECTORY, key)
        uid = entry.get("uid") if entry is not None else None
        profile = self.profile(uid) if isinstance(uid, str) else None
        if uid is None or profile is None or profile.get("directory", {}).get(kind) != key:
            return None
        return uid, profile

    def require_profile(self, transaction: Transaction, uid: str) -> dict[str, Any]:
        profile = transaction.get(ACCOUNT, uid)
        if profile is None:
            raise DomainError("profile_required", "Choose the name people will see first")
        return profile

    def save_destination(self, principal: Principal | None, destination_id: str, body: object) -> dict[str, Any]:
        """Create or replace one destination. ``saveDestination``'s preference rules: the first
        enabled method is preferred automatically, a disabled one never is, and choosing a new
        preferred method clears the old one."""
        caller = self.require_account(principal)
        destination_id = require_uuid(destination_id, "destinationId")
        now = self.ctx.now_iso()

        def body_fn(transaction: Transaction) -> dict[str, Any]:
            profile = self.require_profile(transaction, caller.subject)
            destinations: list[dict[str, Any]] = profile["destinations"]
            existing = next((d for d in destinations if d["id"] == destination_id), None)
            if existing is None and len(destinations) >= MAX_DESTINATIONS:
                raise DomainError("invalid_destination", "You've added the maximum number of payment methods")
            saved = parse_destination(body, destination_id, now, existing)
            siblings = [d for d in destinations if d["id"] != destination_id]
            if saved["isEnabled"] and not any(d["isPreferred"] and d["isEnabled"] for d in siblings):
                saved["isPreferred"] = True
            if saved["isPreferred"]:
                for sibling in siblings:
                    sibling["isPreferred"] = False
            # Siblings are the same objects as in ``destinations``, so the preference changes above apply.
            profile["destinations"] = (
                [*siblings, saved] if existing is None else [saved if d["id"] == destination_id else d for d in destinations]
            )
            profile["updatedAt"] = now
            transaction.put(ACCOUNT, caller.subject, profile)
            return profile

        profile = self.ctx.store.run_in_transaction(body_fn)
        log_event("account.destinationSaved", account=redact(caller.subject))
        return self.profile_view(profile)

    def delete_destination(self, principal: Principal | None, destination_id: str) -> dict[str, Any]:
        caller = self.require_account(principal)
        destination_id = require_uuid(destination_id, "destinationId")
        now = self.ctx.now_iso()

        def body_fn(transaction: Transaction) -> dict[str, Any]:
            profile = self.require_profile(transaction, caller.subject)
            destinations: list[dict[str, Any]] = profile["destinations"]
            removed = next((d for d in destinations if d["id"] == destination_id), None)
            if removed is None:
                raise DomainError("destination_not_found", "That payment method was already removed")
            remaining = [d for d in destinations if d["id"] != destination_id]
            if removed["isPreferred"]:
                successor = next((d for d in remaining if d["isEnabled"]), None)
                if successor is not None:
                    successor["isPreferred"] = True
            profile["destinations"] = remaining
            profile["updatedAt"] = now
            transaction.put(ACCOUNT, caller.subject, profile)
            return profile

        profile = self.ctx.store.run_in_transaction(body_fn)
        log_event("account.destinationDeleted", account=redact(caller.subject))
        return self.profile_view(profile)
