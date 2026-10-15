"""Content-free metrics (milestone 5 §8): outcome counts, cache hits, latency, token totals.

Per-instance and in memory; each parse also emits one structured log event, which is what Cloud
Logging-based metrics aggregate across instances. Nothing here can hold receipt content: only
codes from a fixed vocabulary and numbers.
"""

from __future__ import annotations

import threading
from collections import Counter, deque
from typing import Any

OUTCOMES = frozenset(
    {
        "ok",
        "cache_hit",
        "in_progress",
        "unavailable",
        "timeout",
        "rate_limited",
        "quota_exceeded",
        "provider_error",
        "refused",
        "invalid_output",
        "invalid_request",
    }
)


class IntelligenceMetrics:
    def __init__(self, window: int = 500) -> None:
        self._lock = threading.Lock()
        self._outcomes: Counter[str] = Counter()
        self._invalid_reasons: Counter[str] = Counter()
        self._latencies: deque[float] = deque(maxlen=window)
        self._tokens = {"input": 0, "output": 0}

    def record(
        self, outcome: str, *, latency_ms: float | None = None, input_tokens: int = 0, output_tokens: int = 0, reason: str | None = None
    ) -> None:
        if outcome not in OUTCOMES:
            raise ValueError("Unknown outcome")
        with self._lock:
            self._outcomes[outcome] += 1
            if reason:
                self._invalid_reasons[reason] += 1
            if latency_ms is not None:
                self._latencies.append(latency_ms)
            self._tokens["input"] += input_tokens
            self._tokens["output"] += output_tokens

    def snapshot(self) -> dict[str, Any]:
        with self._lock:
            ordered = sorted(self._latencies)
            return {
                "outcomes": dict(self._outcomes),
                "invalidReasons": dict(self._invalid_reasons),
                "latencyMs": {"p50": _percentile(ordered, 0.5), "p95": _percentile(ordered, 0.95), "samples": len(ordered)},
                "tokens": dict(self._tokens),
            }


def _percentile(ordered: list[float], fraction: float) -> float | None:
    if not ordered:
        return None
    index = min(len(ordered) - 1, max(0, round(fraction * (len(ordered) - 1))))
    return round(ordered[index], 1)
