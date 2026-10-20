"""Helpers shared by the blueprints."""

from __future__ import annotations

import ipaddress
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
    """Rate-limit key: the authenticated subject, else the caller's network (``network_key``)."""
    caller = principal()
    if caller is not None:
        return caller.binding
    return network_key()


def network_key() -> str:
    """The caller's network for rate limits, hashed (never logged raw). On App Engine the address is
    ``X-Appengine-User-IP``, which Google's front end sets (it removes App Engine's own headers from
    incoming requests); anywhere else only the connection's address counts, so a header a client
    made up is never trusted, and ``X-Forwarded-For`` never is. IPv6 addresses count by their /64,
    the block one home or phone network usually gets, so rotating within it doesn't evade a limit."""
    trusted = request.headers.get("X-Appengine-User-IP") if services().ctx.config.on_app_engine else None
    address = trusted or request.remote_addr or "unknown"
    try:
        parsed = ipaddress.ip_address(address)
    except ValueError:
        return f"ip:{redact(address)}"
    if parsed.version == 6:
        address = f"{ipaddress.ip_network(f'{parsed}/64', strict=False).network_address}/64"
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


def limit(scope: str, *, client: str | None = None, message: str | None = None) -> None:
    """Counts this request against ``scope`` for ``client`` (default: the caller); 429 past the limit."""
    if message is None:
        services().limits.check(scope, client or client_key())
    else:
        services().limits.check(scope, client or client_key(), message)
