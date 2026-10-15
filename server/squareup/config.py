"""Environment-based configuration. Nothing environment-specific is hard-coded; see ``.env.example``."""

from __future__ import annotations

import os
from dataclasses import dataclass, field, replace

from .intelligence.settings import IntelligenceSettings


def _bool(name: str, default: bool = False) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in ("1", "true", "yes", "on")


def _int(name: str, default: int) -> int:
    raw = os.environ.get(name)
    return default if raw is None or not raw.strip() else int(raw)


def _public_base_url(on_app_engine: bool) -> str:
    """Explicit ``SQUAREUP_PUBLIC_BASE_URL``, else the App Engine default domain, else localhost."""
    explicit = os.environ.get("SQUAREUP_PUBLIC_BASE_URL")
    if explicit:
        return explicit.rstrip("/")
    project = os.environ.get("GOOGLE_CLOUD_PROJECT")
    if on_app_engine and project:
        return f"https://{project}.appspot.com"
    return "http://localhost:8080"


@dataclass(frozen=True)
class Config:
    #: ``development`` | ``test`` | ``production``.
    environment: str = "development"
    #: ``memory`` | ``datastore``.
    storage_backend: str = "memory"
    #: ``memory`` | ``gcs``.
    blob_backend: str = "memory"
    gcp_project: str | None = None
    datastore_namespace: str | None = None
    asset_bucket: str | None = None
    firebase_project_id: str | None = None
    #: Accept ``Authorization: Dev <uid>`` (local development and automated tests only).
    allow_dev_auth: bool = False
    #: Public origin used in invitation URLs, e.g. ``https://<project>.appspot.com``.
    public_base_url: str = "http://localhost:8080"
    apple_team_id: str | None = None
    app_bundle_id: str | None = None
    clip_bundle_id: str | None = None
    #: The full app's numeric App Store ID (the Smart App Banner's ``app-id``), once it has one.
    app_store_id: str | None = None
    invitation_ttl_hours: int = 48
    #: Shared-group invitations (milestone 7): a week by default, configurable per invitation.
    group_invitation_ttl_hours: int = 168
    #: Direct invitations ("Find a person"): an invitation sent to one account waits this long.
    direct_invitation_ttl_hours: int = 720
    guest_ttl_hours: int = 72
    #: Demo workspaces ("Enter Demo"): offered at all, and how long one lasts before it's deleted.
    demo_enabled: bool = True
    demo_ttl_hours: int = 168
    asset_retention_days: int = 30
    #: Temporary rooms ("Split with people now"): how long claiming stays open before the host
    #: finalizes, how long people then have to pay and be confirmed, and how long the read-only
    #: summary stays after the room ends before everything about it is deleted.
    temporary_room_ttl_hours: int = 72
    temporary_room_payment_days: int = 30
    temporary_room_retention_days: int = 30
    max_request_bytes: int = 256 * 1024
    #: Publishing a local group uploads its whole history once (milestone 7 §8.3).
    max_publication_bytes: int = 1024 * 1024
    max_asset_bytes: int = 4 * 1024 * 1024
    #: Requests per window per client for each scope.
    rate_limits: dict[str, tuple[int, int]] = field(
        default_factory=lambda: {
            "preview": (60, 60),
            # Short room codes are 60 bits; looking them up is limited more tightly than links.
            "code": (20, 60),
            "join": (20, 60),
            "command": (240, 60),
            "publish": (30, 60),
            "asset": (120, 60),
            # Shared groups (milestone 7).
            "account": (60, 60),
            "group-read": (240, 60),
            "group-command": (120, 60),
            "group-publish": (10, 60),
            "group-invite": (30, 60),
            "group-invite-preview": (30, 60),
            "group-invite-accept": (10, 60),
            # "Find a person": looking an account up by email or phone (and inviting it, which looks
            # it up again) is limited per account per minute and per day, against enumeration.
            "group-lookup": (10, 60),
            "group-lookup-daily": (60, 86_400),
            "reveal": (30, 60),
            # Receipt intelligence: per account per minute, per verified account per day, and
            # project-wide per day. The daily scopes count only requests that reach the AI provider
            # (cache hits are free). Configurable: see ``IntelligenceSettings``.
            "intelligence": (6, 60),
            "intelligence-daily": (10, 86_400),
            "intelligence-global": (50, 86_400),
            # Demo workspaces' own AI budget: per workspace, and for all demos together, per day.
            "intelligence-demo-daily": (50, 86_400),
            "intelligence-demo-global": (50, 86_400),
        }
    )
    #: Receipt intelligence (milestone 5). The API key is never stored here (see ``load_api_key``).
    intelligence: IntelligenceSettings = field(default_factory=IntelligenceSettings)

    @property
    def is_production(self) -> bool:
        return self.environment == "production"

    def with_intelligence_limits(self) -> Config:
        """The rate limits with receipt intelligence's configured values applied."""
        ai = self.intelligence
        limits = {
            **self.rate_limits,
            "intelligence": (ai.minute_limit_per_account, 60),
            "intelligence-daily": (ai.daily_limit_per_account, 86_400),
            "intelligence-global": (ai.daily_limit_project, 86_400),
            "intelligence-demo-daily": (ai.demo_daily_limit_per_workspace, 86_400),
            "intelligence-demo-global": (ai.demo_daily_limit_project, 86_400),
        }
        return replace(self, rate_limits=limits)

    @staticmethod
    def from_environment() -> Config:
        environment = os.environ.get("SQUAREUP_ENV", "development")
        on_app_engine = bool(os.environ.get("GAE_ENV", "").startswith("standard"))
        allow_dev = _bool("SQUAREUP_ALLOW_DEV_AUTH") and environment != "production" and not on_app_engine
        return Config(
            environment=environment,
            storage_backend=os.environ.get("SQUAREUP_STORAGE", "datastore" if on_app_engine else "memory"),
            blob_backend=os.environ.get("SQUAREUP_BLOBS", "gcs" if on_app_engine else "memory"),
            gcp_project=os.environ.get("GOOGLE_CLOUD_PROJECT"),
            datastore_namespace=os.environ.get("SQUAREUP_DATASTORE_NAMESPACE") or None,
            asset_bucket=os.environ.get("SQUAREUP_ASSET_BUCKET") or None,
            firebase_project_id=os.environ.get("SQUAREUP_FIREBASE_PROJECT_ID") or os.environ.get("GOOGLE_CLOUD_PROJECT"),
            allow_dev_auth=allow_dev,
            public_base_url=_public_base_url(on_app_engine),
            apple_team_id=os.environ.get("SQUAREUP_APPLE_TEAM_ID") or None,
            app_bundle_id=os.environ.get("SQUAREUP_APP_BUNDLE_ID") or None,
            clip_bundle_id=os.environ.get("SQUAREUP_CLIP_BUNDLE_ID") or None,
            app_store_id=os.environ.get("SQUAREUP_APP_STORE_ID") or None,
            invitation_ttl_hours=_int("SQUAREUP_INVITATION_TTL_HOURS", 48),
            group_invitation_ttl_hours=_int("SQUAREUP_GROUP_INVITATION_TTL_HOURS", 168),
            direct_invitation_ttl_hours=_int("SQUAREUP_DIRECT_INVITATION_TTL_HOURS", 720),
            guest_ttl_hours=_int("SQUAREUP_GUEST_TTL_HOURS", 72),
            demo_enabled=os.environ.get("SQUAREUP_DEMO_ENABLED", "1") != "0",
            demo_ttl_hours=_int("SQUAREUP_DEMO_TTL_HOURS", 168),
            asset_retention_days=_int("SQUAREUP_ASSET_RETENTION_DAYS", 30),
            temporary_room_ttl_hours=_int("SQUAREUP_TEMPORARY_ROOM_TTL_HOURS", 72),
            temporary_room_payment_days=_int("SQUAREUP_TEMPORARY_ROOM_PAYMENT_DAYS", 30),
            temporary_room_retention_days=_int("SQUAREUP_TEMPORARY_ROOM_RETENTION_DAYS", 30),
            intelligence=IntelligenceSettings.from_environment(),
        ).with_intelligence_limits()
