"""The provider boundary (milestone 5 §3.2) and its error taxonomy.

A provider turns a :class:`PromptPackage` into raw JSON text. It knows nothing about money,
validation, caching, or who is calling; the service owns all of that. Every failure is a
:class:`ProviderError` with a stable code, and the app treats every one as "use the on-device parser".
"""

from __future__ import annotations

import json
import time
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

from .prompt import PromptPackage

#: Provider error code → stable API error code (server/API.md).
ERROR_CODES: dict[str, str] = {
    "unavailable": "ai_unavailable",
    "timeout": "ai_timeout",
    "rate_limited": "rate_limited",
    "overloaded": "ai_provider_error",
    "upstream": "ai_provider_error",
    "auth": "ai_unavailable",
    "bad_request": "ai_provider_error",
    "refused": "ai_refused",
    "truncated": "ai_invalid_output",
    "cancelled": "ai_timeout",
}


class ProviderError(Exception):
    """A provider failure. Messages are fixed strings; they never carry request or response content."""

    def __init__(self, code: str, retry_after: float | None = None) -> None:
        if code not in ERROR_CODES:
            raise ValueError(f"Unknown provider error {code}")
        super().__init__(code)
        self.code = code
        self.retry_after = retry_after


@dataclass(frozen=True)
class ProviderResult:
    text: str
    #: The model that actually answered (a refusal fallback may differ from the configured one).
    model: str
    input_tokens: int = 0
    output_tokens: int = 0
    attempts: int = 1


class ReceiptIntelligenceProvider(Protocol):
    name: str
    model: str

    @property
    def available(self) -> bool: ...

    def complete(self, package: PromptPackage, deadline: float) -> ProviderResult:
        """``deadline`` is a ``time.monotonic()`` instant; implementations must not run past it."""
        ...


class UnavailableProvider:
    """No provider configured (or no key): the rest of the server runs; parsing returns 503."""

    name = "none"
    model = ""

    @property
    def available(self) -> bool:
        return False

    def complete(self, package: PromptPackage, deadline: float) -> ProviderResult:
        raise ProviderError("unavailable")


Script = Callable[[PromptPackage], ProviderResult | ProviderError | str]


class FakeProvider:
    """Tests: returns scripted output (a JSON string, a result, or an error) and records calls."""

    name = "fake"

    def __init__(self, script: Script | None = None, model: str = "fake-model") -> None:
        self.model = model
        self.script: Script = script or (lambda _: ProviderError("unavailable"))
        self.calls: list[PromptPackage] = []
        self.delay = 0.0

    @property
    def available(self) -> bool:
        return True

    def complete(self, package: PromptPackage, deadline: float) -> ProviderResult:
        self.calls.append(package)
        if self.delay:
            if time.monotonic() + self.delay > deadline:
                raise ProviderError("timeout")
            time.sleep(self.delay)
        outcome = self.script(package)
        if isinstance(outcome, ProviderError):
            raise outcome
        if isinstance(outcome, str):
            return ProviderResult(outcome, self.model, input_tokens=1000, output_tokens=200)
        return outcome


class RecordedProvider:
    """Development and evaluation only: replays fictional recorded outputs by OCR signature.

    Each ``*.json`` file in ``directory`` is ``{"signature": "<sha256>", "output": {…}}``. Never
    enabled in production (``create_app`` refuses it).
    """

    name = "recorded"

    def __init__(self, directory: str, model: str = "recorded") -> None:
        self.model = model
        self._outputs: dict[str, str] = {}
        for path in sorted(Path(directory).glob("*.json")):
            record = json.loads(path.read_text())
            if isinstance(record, dict) and isinstance(record.get("signature"), str) and "output" in record:
                self._outputs[record["signature"]] = json.dumps(record["output"])

    @property
    def available(self) -> bool:
        return bool(self._outputs)

    def complete(self, package: PromptPackage, deadline: float) -> ProviderResult:
        text = self._outputs.get(package.evidence_signature)
        if text is None:
            raise ProviderError("unavailable")
        return ProviderResult(text, self.model)
