"""Fixed-window rate limiting backed by the store, so limits hold across App Engine instances."""

from __future__ import annotations

from ..auth.identity import token_hash
from ..domain.errors import DomainError
from ..storage.base import RATE, Transaction
from .context import ServiceContext, iso


class RateLimiter:
    def __init__(self, ctx: ServiceContext) -> None:
        self.ctx = ctx

    def check(self, scope: str, client: str) -> None:
        """Count one request for ``client`` in ``scope``; raise ``rate_limited`` past the limit."""
        limit, window = self.ctx.config.rate_limits.get(scope, (120, 60))
        now = self.ctx.now()
        bucket = int(now.timestamp()) // window
        key = token_hash(f"{scope}|{client}|{bucket}")
        reset_at = (bucket + 1) * window

        def body(transaction: Transaction) -> int:
            record = transaction.get(RATE, key) or {"count": 0}
            record["count"] += 1
            expires = iso(now.fromtimestamp(reset_at, tz=now.tzinfo))
            transaction.put(RATE, key, record, indexed={"expiresAt": expires})
            return int(record["count"])

        count = self.ctx.store.run_in_transaction(body)
        if count > limit:
            raise DomainError(
                "rate_limited", "Too many requests. Try again shortly", {"retryAfterSeconds": max(1, reset_at - int(now.timestamp()))}
            )
