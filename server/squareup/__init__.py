"""Square Up API server: authoritative multi-device Receipt Rooms (milestone 4), hybrid receipt
intelligence (milestone 5), and shared P2P groups (milestone 7).

``create_app`` wires configuration, storage, authentication, the receipt-intelligence provider,
and the versioned blueprints. Tests inject an in-memory store, blob store, clock, token verifier,
and a fake provider.
"""

from __future__ import annotations

import time
from collections.abc import Callable
from datetime import datetime
from typing import Any

from flask import Flask, Response, g, jsonify, request
from werkzeug.exceptions import HTTPException, RequestEntityTooLarge

from .auth.identity import TokenVerifier, firebase_verifier
from .config import Config
from .domain.errors import DomainError
from .intelligence.provider import ReceiptIntelligenceProvider, RecordedProvider, UnavailableProvider
from .intelligence.secret_manager import SecretAccessor, SecretUnavailable, load_secret_key
from .intelligence.settings import Secret, key_looks_valid, load_api_key
from .logging_setup import configure, log_event, request_id_from
from .services.accounts import AccountService
from .services.assets import AssetService
from .services.cleanup import CleanupService
from .services.context import ServiceContext, utc_now
from .services.demo import DemoService
from .services.direct_invitations import DirectInvitationService
from .services.groups import GroupService
from .services.intelligence import IntelligenceService
from .services.invitations import InvitationService
from .services.limits import RateLimiter
from .services.rooms import RoomService
from .storage.base import Store, TransientStoreError
from .storage.blobs import BlobStore, GCSBlobStore, MemoryBlobStore


class Services:
    def __init__(self, ctx: ServiceContext, provider: ReceiptIntelligenceProvider) -> None:
        self.ctx = ctx
        self.rooms = RoomService(ctx)
        self.invitations = InvitationService(ctx, self.rooms)
        self.assets = AssetService(ctx, self.rooms)
        self.limits = RateLimiter(ctx)
        self.intelligence = IntelligenceService(ctx, self.limits, provider)
        self.accounts = AccountService(ctx)
        self.demo = DemoService(ctx, self.accounts, self.rooms)
        self.cleanup = CleanupService(ctx, self.assets, self.demo)
        self.groups = GroupService(ctx, self.accounts)
        self.direct_invitations = DirectInvitationService(ctx, self.accounts, self.groups)


def select_provider(
    config: Config, environ: dict[str, str] | None = None, *, secret_accessor: SecretAccessor | None = None
) -> ReceiptIntelligenceProvider:
    """The configured receipt-intelligence provider (milestone 5 §3.2).

    With ``SQUAREUP_AI_PROVIDER=anthropic`` the key comes from:

    - **Production:** Secret Manager only (``SQUAREUP_ANTHROPIC_SECRET``), read once here at startup.
      Any failure — not configured, not found, no permission, disabled version, checksum mismatch,
      malformed key — refuses to start (fail closed). ``ANTHROPIC_API_KEY`` is ignored.
    - **Elsewhere:** ``ANTHROPIC_API_KEY`` (deliberate local development), else the Secret Manager
      resource if one is configured. A failure leaves AI unavailable while the rest of the server runs.

    Secret Manager is never contacted when AI is off, for the recorded provider, or when the app is
    given a provider (tests). Only a reason code is ever logged; the key never leaves its ``Secret``.
    """
    settings = config.intelligence
    if settings.provider == "off":
        return UnavailableProvider()
    if settings.provider == "recorded":
        if config.is_production:
            raise RuntimeError("The recorded AI provider is for development and evaluation only")
        if not settings.recorded_directory:
            raise RuntimeError("SQUAREUP_AI_RECORDED_DIR is required for the recorded provider")
        return RecordedProvider(settings.recorded_directory, model=f"recorded:{settings.model}")
    key: Secret | None = None if config.is_production else load_api_key(environ)
    reason = "missing_or_malformed_key"
    if key is None and (config.is_production or settings.secret_resource):
        try:
            key = load_secret_key(settings.secret_resource, secret_accessor)
            log_event("ai.key_loaded", source="secret_manager")
        except SecretUnavailable as error:
            reason = error.reason
            key = None
    if key is None or not key_looks_valid(key):
        log_event("ai.unavailable", reason=reason)
        if config.is_production:
            # The message names only the reason: never the key, the response, or Google's error text.
            raise RuntimeError(f"Receipt intelligence can't start: {reason}")
        return UnavailableProvider()
    from .intelligence.anthropic_provider import ClaudeReceiptProvider

    return ClaudeReceiptProvider(key, settings)


def _default_store(config: Config) -> Store:
    if config.storage_backend == "datastore":
        from .storage.datastore_store import DatastoreStore

        return DatastoreStore(config.gcp_project, config.datastore_namespace)
    from .storage.memory import MemoryStore

    return MemoryStore()


def _default_blobs(config: Config) -> BlobStore:
    if config.blob_backend == "gcs":
        if not config.asset_bucket:
            raise RuntimeError("SQUAREUP_ASSET_BUCKET is required for Cloud Storage")
        return GCSBlobStore(config.asset_bucket, config.gcp_project)
    return MemoryBlobStore()


def create_app(
    config: Config | None = None,
    *,
    store: Store | None = None,
    blobs: BlobStore | None = None,
    clock: Callable[[], datetime] | None = None,
    verify_firebase: TokenVerifier | None = None,
    intelligence_provider: ReceiptIntelligenceProvider | None = None,
    secret_accessor: SecretAccessor | None = None,
) -> Flask:
    config = config or Config.from_environment()
    if config.is_production and config.allow_dev_auth:
        raise RuntimeError("Development authentication must never be enabled in production")
    configure()
    verifier = verify_firebase
    if verifier is None and config.firebase_project_id:
        verifier = firebase_verifier(config.firebase_project_id)
    ctx = ServiceContext(
        config=config,
        store=store or _default_store(config),
        blobs=blobs or _default_blobs(config),
        verify_firebase=verifier,
        clock=clock or utc_now,
    )
    app = Flask(__name__)
    app.config["MAX_CONTENT_LENGTH"] = (
        max(config.max_asset_bytes, config.max_request_bytes, config.max_publication_bytes, config.intelligence.max_request_bytes) + 1024
    )
    app.json.sort_keys = False  # type: ignore[attr-defined]
    app.extensions["squareup"] = Services(ctx, intelligence_provider or select_provider(config, secret_accessor=secret_accessor))

    from .api.demo import blueprint as demo
    from .api.groups import accounts, group_invitations, groups
    from .api.health import blueprint as health
    from .api.intelligence import blueprint as intelligence
    from .api.invitations import blueprint as invitations
    from .api.invitations import codes as room_codes
    from .api.rooms import blueprint as rooms
    from .api.tasks import blueprint as tasks
    from .api.web import blueprint as web

    for blueprint in (health, rooms, invitations, room_codes, intelligence, web, tasks, accounts, groups, group_invitations, demo):
        app.register_blueprint(blueprint)

    @app.before_request
    def start() -> None:
        g.request_id = request_id_from(request.headers.get("X-Request-Id"))
        g.started = time.perf_counter()
        g.actor_kind = "anonymous"
        # Image uploads, receipt-intelligence requests, and group publications have their own, larger limits.
        if request.path.startswith("/v1/") and not request.path.endswith(("/receipt-assets", "/receipt-intelligence/parse")):
            length = request.content_length or 0
            ceiling = config.max_publication_bytes if request.path == "/v1/groups/publications" else config.max_request_bytes
            if length > ceiling:
                raise DomainError("payload_too_large", "That request is too large")

    @app.after_request
    def finish(response: Response) -> Response:
        response.headers["X-Request-Id"] = g.get("request_id", "")
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Referrer-Policy"] = "no-referrer"
        if request.path.startswith("/v1/") or request.path.startswith("/r/"):
            response.headers.setdefault("Cache-Control", "no-store")
        rule = request.url_rule.rule if request.url_rule else "unmatched"
        log_event(
            "request",
            requestId=g.get("request_id"),
            method=request.method,
            route=rule,
            status=response.status_code,
            latencyMs=round((time.perf_counter() - g.get("started", time.perf_counter())) * 1000, 1),
            actor=g.get("actor_kind"),
        )
        return response

    @app.errorhandler(DomainError)
    def domain_error(error: DomainError) -> tuple[Response, int]:
        body: dict[str, Any] = {"error": {"code": error.code, "message": error.message, "requestId": g.get("request_id")}}
        body["error"].update({key: value for key, value in error.details.items() if key != "room"})
        if "room" in error.details:
            body["room"] = error.details["room"]
        response = jsonify(body)
        if error.code == "rate_limited":
            response.headers["Retry-After"] = str(error.details.get("retryAfterSeconds", 60))
        return response, error.status

    @app.errorhandler(TransientStoreError)
    def transient(_: TransientStoreError) -> tuple[Response, int]:
        return jsonify(
            {"error": {"code": "temporarily_unavailable", "message": "Try again in a moment", "requestId": g.get("request_id")}}
        ), 503

    @app.errorhandler(RequestEntityTooLarge)
    def too_large(_: RequestEntityTooLarge) -> tuple[Response, int]:
        return jsonify(
            {"error": {"code": "payload_too_large", "message": "That request is too large", "requestId": g.get("request_id")}}
        ), 413

    @app.errorhandler(HTTPException)
    def http_error(error: HTTPException) -> tuple[Response, int]:
        code = "invalid_payload"
        if error.code == 404:
            # Unroutable invitation paths (malformed tokens) look exactly like unknown tokens.
            code = (
                "invitation_invalid"
                if request.path.startswith(("/v1/receipt-room-invitations/", "/v1/group-invitations/"))
                else "not_found"
            )
        return jsonify({"error": {"code": code, "message": error.name, "requestId": g.get("request_id")}}), error.code or 500

    @app.errorhandler(Exception)
    def unexpected(error: Exception) -> tuple[Response, int]:
        # Type only: exception messages and tracebacks can carry request data.
        log_event("unhandled", requestId=g.get("request_id"), type=type(error).__name__)
        return jsonify(
            {"error": {"code": "temporarily_unavailable", "message": "Something went wrong. Try again", "requestId": g.get("request_id")}}
        ), 503

    return app
