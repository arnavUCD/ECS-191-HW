"""Receipt-intelligence configuration (milestone 5 §3.2, §8).

Everything is read from the environment. The Anthropic API key is deliberately **not** part of
these settings: it is loaded separately into a :class:`Secret` (from Secret Manager in production,
see ``secret_manager``; from ``ANTHROPIC_API_KEY`` only in local development), so it can never
appear in a dataclass ``repr``, a log line, or an error message. ``secret_resource`` is only the
Secret Manager *name* of the key, never its value.
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass

#: The only place the default model is named. Override with ``SQUAREUP_AI_MODEL``.
DEFAULT_MODEL = "claude-opus-5-5"
PROVIDERS = ("off", "anthropic", "recorded")
EFFORTS = ("low", "medium", "high", "xhigh", "max")
_KEY_SHAPE = re.compile(r"^sk-ant-[A-Za-z0-9_\-]{20,400}$")


class Secret:
    """A credential that refuses to print itself."""

    __slots__ = ("_value",)

    def __init__(self, value: str) -> None:
        self._value = value

    def reveal(self) -> str:
        return self._value

    def __repr__(self) -> str:
        return "Secret('***')"

    __str__ = __repr__

    def __eq__(self, other: object) -> bool:
        return isinstance(other, Secret) and other._value == self._value

    def __hash__(self) -> int:
        return hash(("Secret", len(self._value)))

    def __reduce__(self) -> tuple[object, ...]:
        raise TypeError("Secrets can't be serialized")


def load_api_key(environ: dict[str, str] | None = None) -> Secret | None:
    """``ANTHROPIC_API_KEY`` from the environment, or ``None`` when absent or blank."""
    raw = (environ if environ is not None else os.environ).get("ANTHROPIC_API_KEY", "").strip()
    return Secret(raw) if raw else None


def key_looks_valid(key: Secret | None) -> bool:
    """A shape check only (prefix and character set); the API decides whether it works."""
    return key is not None and bool(_KEY_SHAPE.match(key.reveal()))


def _int(environ: dict[str, str], name: str, default: int) -> int:
    raw = environ.get(name, "").strip()
    return int(raw) if raw else default


def _positive(environ: dict[str, str], name: str, default: int) -> int:
    value = _int(environ, name, default)
    if value < 1:
        raise RuntimeError(f"{name} must be a positive whole number")
    return value


def _float(environ: dict[str, str], name: str, default: float) -> float:
    raw = environ.get(name, "").strip()
    return float(raw) if raw else default


@dataclass(frozen=True)
class IntelligenceSettings:
    #: ``off`` | ``anthropic`` | ``recorded`` (development and evaluation only).
    provider: str = "off"
    model: str = DEFAULT_MODEL
    effort: str = "medium"
    #: Server-side refusal fallback (``fallbacks: "default"``), on by default.
    refusal_fallback: bool = True
    #: Deadline for one parse, including at most one retry.
    timeout_seconds: float = 50.0
    max_output_tokens: int = 16000
    #: How long a completed structured result (never the image) is kept for duplicate requests.
    cache_hours: int = 24
    max_request_bytes: int = 8 * 1024 * 1024
    max_pages: int = 6
    max_image_bytes: int = 6 * 1024 * 1024
    max_regions: int = 1500
    #: Directory of recorded fictional responses for the ``recorded`` provider.
    recorded_directory: str | None = None
    #: Secret Manager version holding the Anthropic key, e.g.
    #: ``projects/<project>/secrets/anthropic-api-key/versions/latest`` (a name, not the key).
    secret_resource: str | None = None
    #: Provider calls per verified account per day, and across the project per day. Cache hits
    #: don't count. Conservative while paid AI is new.
    daily_limit_per_account: int = 10
    daily_limit_project: int = 50
    #: Parse requests per account per minute (cache hits included).
    minute_limit_per_account: int = 6
    #: Demo workspaces ("Enter Demo") have their own, separate daily budget — per workspace and for
    #: all demos together — and never count toward the real-account limits above. Cache hits don't count.
    demo_daily_limit_per_workspace: int = 50
    demo_daily_limit_project: int = 50

    @staticmethod
    def from_environment(environ: dict[str, str] | None = None) -> IntelligenceSettings:
        env = dict(os.environ if environ is None else environ)
        provider = env.get("SQUAREUP_AI_PROVIDER", "off").strip().lower() or "off"
        if provider not in PROVIDERS:
            raise RuntimeError("SQUAREUP_AI_PROVIDER must be off, anthropic, or recorded")
        effort = env.get("SQUAREUP_AI_EFFORT", "medium").strip().lower() or "medium"
        if effort not in EFFORTS:
            raise RuntimeError("SQUAREUP_AI_EFFORT must be low, medium, high, xhigh, or max")
        return IntelligenceSettings(
            provider=provider,
            model=env.get("SQUAREUP_AI_MODEL", "").strip() or DEFAULT_MODEL,
            effort=effort,
            refusal_fallback=env.get("SQUAREUP_AI_REFUSAL_FALLBACK", "default").strip().lower() != "off",
            timeout_seconds=_float(env, "SQUAREUP_AI_TIMEOUT_SECONDS", 50.0),
            max_output_tokens=_int(env, "SQUAREUP_AI_MAX_OUTPUT_TOKENS", 16000),
            cache_hours=_int(env, "SQUAREUP_AI_CACHE_HOURS", 24),
            recorded_directory=env.get("SQUAREUP_AI_RECORDED_DIR", "").strip() or None,
            secret_resource=env.get("SQUAREUP_ANTHROPIC_SECRET", "").strip() or None,
            daily_limit_per_account=_positive(env, "SQUAREUP_AI_DAILY_LIMIT_PER_ACCOUNT", 10),
            daily_limit_project=_positive(env, "SQUAREUP_AI_DAILY_LIMIT_PROJECT", 50),
            minute_limit_per_account=_positive(env, "SQUAREUP_AI_MINUTE_LIMIT", 6),
            demo_daily_limit_per_workspace=_positive(env, "SQUAREUP_AI_DEMO_DAILY_LIMIT_PER_WORKSPACE", 50),
            demo_daily_limit_project=_positive(env, "SQUAREUP_AI_DEMO_DAILY_LIMIT_PROJECT", 50),
        )
