"""Claude through the official ``anthropic`` Python SDK (milestone 5 M5.3).

- Structured outputs: ``output_config.format`` with the strict JSON Schema, plus ``effort``.
  Thinking is left at the model default (adaptive, always on for the default model).
- Server-side refusal fallback (``fallbacks: "default"``) is on unless disabled by configuration;
  the model that actually answered is reported from the response.
- The SDK's own retries are off. This class makes at most one retry, only for transient failures,
  and never past the caller's deadline.
- Nothing from the request or response is logged or placed in exception messages.
"""

from __future__ import annotations

import time
from collections.abc import Callable
from typing import Any

from .prompt import PromptPackage
from .provider import ProviderError, ProviderResult
from .settings import IntelligenceSettings, Secret

FALLBACK_BETA = "server-side-fallback-2026-07-01"
#: Retry only when at least this much of the deadline remains.
RETRY_FLOOR_SECONDS = 15.0
MAX_RETRY_AFTER_SECONDS = 5.0


class ClaudeReceiptProvider:
    name = "anthropic"

    def __init__(self, key: Secret, settings: IntelligenceSettings, client_factory: Callable[[], Any] | None = None) -> None:
        self.model = settings.model
        self._settings = settings
        self._key = key
        self._factory = client_factory
        self._client: Any = None
        self.sleep: Callable[[float], None] = time.sleep

    @property
    def available(self) -> bool:
        return True

    def _sdk_client(self) -> Any:
        if self._client is None:
            if self._factory is not None:
                self._client = self._factory()
            else:
                import anthropic

                self._client = anthropic.Anthropic(api_key=self._key.reveal(), max_retries=0, timeout=self._settings.timeout_seconds)
        return self._client

    def request_arguments(self, package: PromptPackage, timeout: float) -> dict[str, Any]:
        """The exact SDK arguments (tests assert on this shape)."""
        arguments: dict[str, Any] = {
            "model": self._settings.model,
            "max_tokens": self._settings.max_output_tokens,
            "system": package.system,
            "messages": [{"role": "user", "content": package.content}],
            "output_config": {"effort": self._settings.effort, "format": {"type": "json_schema", "schema": package.schema}},
            "timeout": timeout,
        }
        if self._settings.refusal_fallback:
            arguments["betas"] = [FALLBACK_BETA]
            arguments["fallbacks"] = "default"
        return arguments

    def _create(self, arguments: dict[str, Any]) -> Any:
        client = self._sdk_client()
        if "betas" in arguments:
            return client.beta.messages.create(**arguments)
        return client.messages.create(**arguments)

    def complete(self, package: PromptPackage, deadline: float) -> ProviderResult:
        import anthropic

        attempt = 0
        while True:
            attempt += 1
            remaining = deadline - time.monotonic()
            if remaining < 1:
                raise ProviderError("timeout")
            can_retry = attempt == 1 and remaining >= RETRY_FLOOR_SECONDS
            try:
                response = self._create(self.request_arguments(package, remaining))
            except (anthropic.APITimeoutError, anthropic.DeadlineExceededError) as error:
                raise ProviderError("timeout") from error
            except anthropic.RateLimitError as error:
                retry_after = _retry_after(error)
                if can_retry and retry_after is not None and retry_after <= MAX_RETRY_AFTER_SECONDS:
                    self.sleep(retry_after)
                    continue
                raise ProviderError("rate_limited", retry_after) from error
            except (anthropic.AuthenticationError, anthropic.PermissionDeniedError) as error:
                raise ProviderError("auth") from error
            except (anthropic.BadRequestError, anthropic.RequestTooLargeError, anthropic.UnprocessableEntityError) as error:
                raise ProviderError("bad_request") from error
            except (
                anthropic.InternalServerError,
                anthropic.OverloadedError,
                anthropic.ServiceUnavailableError,
                anthropic.APIConnectionError,
            ) as error:
                if can_retry:
                    self.sleep(0.5)
                    continue
                raise ProviderError("overloaded") from error
            except anthropic.APIError as error:
                raise ProviderError("upstream") from error
            return _result(response, attempt)


def _retry_after(error: Any) -> float | None:
    try:
        return float(error.response.headers.get("retry-after", ""))
    except (AttributeError, TypeError, ValueError):
        return None


def _result(response: Any, attempts: int) -> ProviderResult:
    stop_reason = getattr(response, "stop_reason", None)
    if stop_reason == "refusal":
        raise ProviderError("refused")
    if stop_reason == "max_tokens":
        raise ProviderError("truncated")
    text = next((block.text for block in response.content if getattr(block, "type", None) == "text"), None)
    if text is None:
        raise ProviderError("upstream")
    usage = getattr(response, "usage", None)
    return ProviderResult(
        text=text,
        model=str(getattr(response, "model", "")),
        input_tokens=int(getattr(usage, "input_tokens", 0) or 0),
        output_tokens=int(getattr(usage, "output_tokens", 0) or 0),
        attempts=attempts,
    )
