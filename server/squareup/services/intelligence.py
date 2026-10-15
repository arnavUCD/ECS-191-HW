"""Receipt intelligence orchestration (milestone 5 §3.2, §8).

Order of checks, cheapest first: account → per-minute limit (API layer) → provider availability →
request validation and consent → images → fingerprint → cache → in-flight lease → daily quotas →
provider → strict schema → deterministic validation → cache write.

The service is the only place that knows who is calling. The provider sees a prompt package; the
cache key and logs see only a salted hash of the account.
"""

from __future__ import annotations

import hashlib
import json
import time
from datetime import timedelta
from typing import Any

from ..auth.identity import Principal, token_hash
from ..domain.errors import DomainError
from ..intelligence import prompt
from ..intelligence.images import prepare_image, visual_tokens
from ..intelligence.metrics import IntelligenceMetrics
from ..intelligence.provider import ERROR_CODES, ProviderError, ReceiptIntelligenceProvider
from ..intelligence.schema import PROVIDER_OUTPUT_SCHEMA, SCHEMA_VERSION, InvalidOutput, ParseRequest, parse_provider_output, parse_request
from ..intelligence.validation import validate
from ..logging_setup import log_event, redact
from ..storage.base import INTELLIGENCE, Transaction
from .context import ServiceContext, iso, parse_iso
from .limits import RateLimiter

#: Bumped when the cache record format changes.
CACHE_FORMAT = 1
#: How long another identical request waits before it may take over an abandoned lease.
LEASE_GRACE_SECONDS = 10
IN_PROGRESS_RETRY_SECONDS = 3


def owner_hash(principal: Principal) -> str:
    return token_hash(f"intelligence|{principal.binding}")


class IntelligenceService:
    def __init__(self, ctx: ServiceContext, limits: RateLimiter, provider: ReceiptIntelligenceProvider) -> None:
        self.ctx = ctx
        self.limits = limits
        self.provider = provider
        self.metrics = IntelligenceMetrics()
        self.settings = ctx.config.intelligence

    # MARK: - Public

    def require_account(self, principal: Principal | None, *, verified: bool = True) -> Principal:
        if principal is None:
            raise DomainError("unauthenticated", "Sign in to use AI processing")
        if principal.kind != "user":
            raise DomainError("forbidden", "AI processing is available in the Square Up app")
        # Paid AI only for verified accounts (a confirmed email or a verified phone number), and for
        # demo workspaces (``services.demo``). The response names the requirement, never the claims.
        if verified and not principal.verified and not principal.demo:
            raise DomainError("email_not_verified", "Verify your email address to use AI processing")
        return principal

    def parse(self, principal: Principal | None, body: object) -> dict[str, Any]:
        caller = self.require_account(principal)
        started = time.monotonic()
        owner = owner_hash(caller)
        if not self.provider.available:
            self._finish("unavailable", owner, started)
            raise DomainError("ai_unavailable", "AI processing isn't available right now")
        try:
            request = parse_request(
                body,
                max_pages=self.settings.max_pages,
                max_regions=self.settings.max_regions,
                max_image_bytes=self.settings.max_image_bytes,
            )
            prepared = [prepare_image(page.image) for page in request.pages]
        except DomainError as error:
            self._finish("invalid_request", owner, started, code=error.code)
            raise
        images = [clean for clean, _, _ in prepared]
        fingerprint = self._fingerprint(owner, request, images)

        cached = self._claim(fingerprint, owner)
        if cached is not None:
            self._finish("cache_hit", owner, started, pages=len(images))
            return {**cached, "cached": True}

        try:
            self._check_quotas(owner, demo=caller.demo)
            aliases = prompt.RegionAliases.build(request.regions)
            package = prompt.build(request, images, aliases, PROVIDER_OUTPUT_SCHEMA)
            deadline = started + self.settings.timeout_seconds
            result = self.provider.complete(package, deadline)
        except ProviderError as error:
            self._release(fingerprint)
            outcome = {"ai_timeout": "timeout", "rate_limited": "rate_limited", "ai_refused": "refused", "ai_unavailable": "unavailable"}
            api_code = ERROR_CODES[error.code]
            self._finish(outcome.get(api_code, "provider_error"), owner, started, code=error.code, pages=len(images))
            details = {"retryAfterSeconds": max(1, round(error.retry_after or 30))} if api_code == "rate_limited" else {}
            raise DomainError(api_code, "AI processing wasn't available", details) from error
        except DomainError as error:
            self._release(fingerprint)
            quota = error.code in ("rate_limited", "ai_demo_limit")
            self._finish("quota_exceeded" if quota else "invalid_request", owner, started, code=error.code)
            raise
        except BaseException:
            self._release(fingerprint)
            raise

        try:
            raw = parse_provider_output(result.text)
            checked = validate(raw, aliases, likely_currency=request.likely_currency)
        except InvalidOutput as error:
            self._release(fingerprint)
            self._finish(
                "invalid_output",
                owner,
                started,
                code=error.reason,
                model=result.model,
                input_tokens=result.input_tokens,
                output_tokens=result.output_tokens,
                pages=len(images),
            )
            raise DomainError("ai_invalid_output", "AI processing wasn't available", {"reason": error.reason}) from error

        response = {
            "schemaVersion": SCHEMA_VERSION,
            "provider": self.provider.name,
            "model": result.model or self.provider.model,
            "proposal": checked.proposal,
            "validation": {"issues": checked.issues, "reconciled": checked.reconciled},
        }
        self._store(fingerprint, owner, response)
        self._finish(
            "ok",
            owner,
            started,
            model=result.model,
            input_tokens=result.input_tokens,
            output_tokens=result.output_tokens,
            pages=len(images),
            regions=len(request.regions),
            imageTokens=sum(visual_tokens(w, h) for _, w, h in prepared),
            items=len(checked.proposal["items"]),
            issues=len(checked.issues),
            evidenceMismatches=checked.evidence_mismatches,
            attempts=result.attempts,
        )
        return {**response, "cached": False}

    def delete_cache(self, principal: Principal | None) -> int:
        """Removes this account's cached results (consent revoked). Returns how many were removed."""
        # Removing results is always allowed, verified or not (consent can be withdrawn any time).
        owner = owner_hash(self.require_account(principal, verified=False))
        removed = 0
        for key, _ in self.ctx.store.query(INTELLIGENCE, "owner", owner, limit=500):

            def delete(transaction: Transaction, key: str = key) -> None:
                transaction.delete(INTELLIGENCE, key)

            self.ctx.store.run_in_transaction(delete)
            removed += 1
        log_event("ai.cache_deleted", user=redact(owner), removed=removed)
        return removed

    # MARK: - Fingerprint, cache, lease

    def _fingerprint(self, owner: str, request: ParseRequest, images: list[bytes]) -> str:
        """Anything that could change the answer is in here, so a changed image or prompt never hits."""
        material = {
            "format": CACHE_FORMAT,
            "schema": SCHEMA_VERSION,
            "prompt": prompt.PROMPT_VERSION,
            "model": self.provider.model,
            "effort": self.settings.effort,
            "owner": owner,
            "images": [hashlib.sha256(image).hexdigest() for image in images],
            "warnings": [list(page.warnings) for page in request.pages],
            "regions": [
                [r.client_id, r.page, r.order, r.text, round(r.confidence, 3), [round(v, 4) for v in r.box], list(r.alternatives)]
                for r in request.regions
            ],
            "locale": request.locale,
            "currency": request.likely_currency,
        }
        return hashlib.sha256(json.dumps(material, sort_keys=True, separators=(",", ":")).encode()).hexdigest()

    def _claim(self, fingerprint: str, owner: str) -> dict[str, Any] | None:
        """The cached response, or ``None`` after taking the in-flight lease. Raises ``ai_in_progress``."""
        now = self.ctx.now()
        lease_until = iso(now + timedelta(seconds=self.settings.timeout_seconds + LEASE_GRACE_SECONDS))

        def body(transaction: Transaction) -> tuple[str, dict[str, Any] | None]:
            record = transaction.get(INTELLIGENCE, fingerprint)
            if record is not None and parse_iso(record["expiresAt"]) > now:
                if record["state"] == "done":
                    return "done", record["response"]
                return "busy", None
            transaction.put(
                INTELLIGENCE,
                fingerprint,
                {"state": "pending", "owner": owner, "expiresAt": lease_until},
                indexed={"owner": owner, "expiresAt": lease_until},
            )
            return "claimed", None

        state, response = self.ctx.store.run_in_transaction(body)
        if state == "busy":
            self.metrics.record("in_progress")
            raise DomainError("ai_in_progress", "This receipt is already being processed", {"retryAfterSeconds": IN_PROGRESS_RETRY_SECONDS})
        return response if state == "done" else None

    def _release(self, fingerprint: str) -> None:
        def body(transaction: Transaction) -> None:
            record = transaction.get(INTELLIGENCE, fingerprint)
            if record is not None and record["state"] == "pending":
                transaction.delete(INTELLIGENCE, fingerprint)

        self.ctx.store.run_in_transaction(body)

    def _store(self, fingerprint: str, owner: str, response: dict[str, Any]) -> None:
        expires = iso(self.ctx.now() + timedelta(hours=self.settings.cache_hours))

        def body(transaction: Transaction) -> None:
            transaction.put(
                INTELLIGENCE,
                fingerprint,
                {"state": "done", "owner": owner, "expiresAt": expires, "response": response},
                indexed={"owner": owner, "expiresAt": expires},
            )

        self.ctx.store.run_in_transaction(body)

    def _check_quotas(self, owner: str, *, demo: bool = False) -> None:
        """Daily limits count only requests that will reach the provider (cache hits are free).
        Demo workspaces use their own budget (per workspace and for all demos together), so a demo
        never spends what real accounts are allowed; when it's used up the app reads on device."""
        if not demo:
            self.limits.check("intelligence-daily", owner)
            self.limits.check("intelligence-global", "global")
            return
        try:
            self.limits.check("intelligence-demo-daily", owner)
            self.limits.check("intelligence-demo-global", "global")
        except DomainError as error:
            if error.code != "rate_limited":
                raise
            raise DomainError(
                "ai_demo_limit",
                "The demo's AI receipt reading is used up for today",
                {"retryAfterSeconds": error.details.get("retryAfterSeconds", 3600)},
            ) from error

    # MARK: - Metrics and logs

    def _finish(
        self,
        outcome: str,
        owner: str,
        started: float,
        *,
        code: str | None = None,
        model: str | None = None,
        input_tokens: int = 0,
        output_tokens: int = 0,
        **counts: int,
    ) -> None:
        latency = round((time.monotonic() - started) * 1000, 1)
        self.metrics.record(outcome, latency_ms=latency, input_tokens=input_tokens, output_tokens=output_tokens, reason=code)
        log_event(
            "ai.parse",
            outcome=outcome,
            code=code,
            latencyMs=latency,
            user=redact(owner),
            provider=self.provider.name,
            model=model,
            inputTokens=input_tokens,
            outputTokens=output_tokens,
            **counts,
        )
