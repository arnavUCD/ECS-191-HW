"""Helpers shared by the blueprints."""

from __future__ import annotations

from typing import Any, cast

from flask import current_app, g, request

from ..auth.identity import Principal, parse_authorization
from ..domain.errors import DomainError
from ..logging_setup import redact


def services() -> Any:
    return current_app.extensions["squareup"]


def principal() -> Principal | None:
    """The authenticated caller, cached for the request."""
    if "principal" not in g:
        svc = services()
        g.principal = parse_authorization(
            request.headers.get("Authorization"),
            verify_firebase=svc.ctx.verify_firebase,
            allow_dev=svc.ctx.config.allow_dev_auth,
            resolve_guest=svc.rooms.resolve_guest,
            resolve_demo=svc.demo.resolve,
        )
        g.actor_kind = "anonymous" if g.principal is None else g.principal.kind
    return cast(Principal | None, g.principal)


def client_key() -> str:
    """Rate-limit key: the authenticated subject, else the client address (hashed, never logged raw)."""
    caller = principal()
    if caller is not None:
        return caller.binding
    address = request.headers.get("X-Appengine-User-IP") or request.remote_addr or "unknown"
    return f"ip:{redact(address)}"


def json_body() -> Any:
    config = services().ctx.config
    ceiling = config.max_publication_bytes if request.path == "/v1/groups/publications" else config.max_request_bytes
    if request.content_length and request.content_length > ceiling:
        raise DomainError("payload_too_large", "That request is too large")
    body = request.get_json(silent=True)
    if body is None:
        raise DomainError("invalid_payload", "Expected a JSON body")
    return body


def limit(scope: str) -> None:
    services().limits.check(scope, client_key())
