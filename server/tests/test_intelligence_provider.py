"""Key handling, provider selection, and the Claude provider against a stubbed SDK client (no network)."""

from __future__ import annotations

import io
import logging
import pickle
import time
from contextlib import redirect_stdout
from dataclasses import dataclass, field
from typing import Any

import anthropic
import httpx2
import pytest

from squareup import select_provider
from squareup.config import Config
from squareup.intelligence import prompt
from squareup.intelligence.anthropic_provider import FALLBACK_BETA, ClaudeReceiptProvider
from squareup.intelligence.provider import ProviderError, UnavailableProvider
from squareup.intelligence.schema import PROVIDER_OUTPUT_SCHEMA, parse_request
from squareup.intelligence.settings import DEFAULT_MODEL, IntelligenceSettings, Secret, key_looks_valid, load_api_key

from .intelligence_kit import output, request_body, text

FAKE_KEY = "sk-ant-api03-" + "A1b2C3d4" * 6


# MARK: - Secrets and settings


def test_secret_never_prints_or_serializes() -> None:
    secret = Secret(FAKE_KEY)
    assert FAKE_KEY not in repr(secret) and FAKE_KEY not in str(secret) and FAKE_KEY not in f"{secret}"
    assert FAKE_KEY not in repr({"key": secret}) and secret.reveal() == FAKE_KEY
    with pytest.raises(TypeError):
        pickle.dumps(secret)


def test_key_loading_and_shape() -> None:
    assert load_api_key({}) is None and load_api_key({"ANTHROPIC_API_KEY": "   "}) is None
    assert key_looks_valid(load_api_key({"ANTHROPIC_API_KEY": FAKE_KEY}))
    for bad in ("sk-test-123", "sk-ant-short", FAKE_KEY + " extra", "not a key"):
        assert not key_looks_valid(Secret(bad))


def test_settings_from_environment_and_config_has_no_key() -> None:
    settings = IntelligenceSettings.from_environment({"SQUAREUP_AI_PROVIDER": "anthropic", "SQUAREUP_AI_EFFORT": "high"})
    assert settings.provider == "anthropic" and settings.model == DEFAULT_MODEL and settings.effort == "high"
    assert settings.refusal_fallback is True
    assert IntelligenceSettings.from_environment({"SQUAREUP_AI_REFUSAL_FALLBACK": "off"}).refusal_fallback is False
    assert IntelligenceSettings.from_environment({"SQUAREUP_AI_MODEL": "claude-sonnet-5-5"}).model == "claude-sonnet-5-5"
    with pytest.raises(RuntimeError):
        IntelligenceSettings.from_environment({"SQUAREUP_AI_PROVIDER": "openai"})
    with pytest.raises(RuntimeError):
        IntelligenceSettings.from_environment({"SQUAREUP_AI_EFFORT": "extreme"})
    assert "ANTHROPIC" not in repr(Config()) and "sk-ant" not in repr(Config())


def _config(provider: str, environment: str = "development", **settings: Any) -> Config:
    return Config(environment=environment, intelligence=IntelligenceSettings(provider=provider, **settings))


def test_provider_selection() -> None:
    assert isinstance(select_provider(_config("off"), {}), UnavailableProvider)
    assert isinstance(select_provider(_config("anthropic"), {}), UnavailableProvider), "missing key: AI off, server runs"
    selected = select_provider(_config("anthropic"), {"ANTHROPIC_API_KEY": FAKE_KEY})
    assert isinstance(selected, ClaudeReceiptProvider) and selected.model == DEFAULT_MODEL


@pytest.mark.parametrize("environ", [{}, {"ANTHROPIC_API_KEY": "sk-wrong"}])
def test_production_refuses_ai_startup_with_invalid_key(environ: dict[str, str]) -> None:
    with pytest.raises(RuntimeError) as raised:
        select_provider(_config("anthropic", "production"), environ)
    assert "sk-wrong" not in str(raised.value)


def test_production_refuses_recorded_provider(tmp_path: Any) -> None:
    with pytest.raises(RuntimeError):
        select_provider(_config("recorded", "production", recorded_directory=str(tmp_path)), {})


def test_production_with_ai_off_starts_normally() -> None:
    assert isinstance(select_provider(_config("off", "production"), {}), UnavailableProvider)


def test_selection_never_logs_the_key() -> None:
    from squareup.logging_setup import configure

    captured = io.StringIO()
    logger = configure()
    handler = logging.StreamHandler(captured)
    handler.setFormatter(logger.handlers[0].formatter)
    logger.addHandler(handler)
    try:
        with redirect_stdout(captured):
            select_provider(_config("anthropic"), {"ANTHROPIC_API_KEY": "sk-ant-oops"})
            provider = select_provider(_config("anthropic"), {"ANTHROPIC_API_KEY": FAKE_KEY})
            print(repr(provider.__dict__))
    finally:
        logger.removeHandler(handler)
    assert '"ai.unavailable"' in captured.getvalue(), "the missing-key event was logged (without the key)"
    assert "sk-ant-oops" not in captured.getvalue() and FAKE_KEY not in captured.getvalue()


# MARK: - Claude provider with a stubbed SDK client


@dataclass
class Block:
    text: str
    type: str = "text"


@dataclass
class Usage:
    input_tokens: int = 6400
    output_tokens: int = 1100


@dataclass
class Response:
    content: list[Any]
    stop_reason: str = "end_turn"
    model: str = DEFAULT_MODEL
    usage: Usage = field(default_factory=Usage)


class StubMessages:
    def __init__(self, outcomes: list[Any]) -> None:
        self.outcomes = outcomes
        self.calls: list[dict[str, Any]] = []

    def create(self, **arguments: Any) -> Any:
        self.calls.append(arguments)
        outcome = self.outcomes.pop(0)
        if isinstance(outcome, Exception):
            raise outcome
        return outcome


class StubClient:
    def __init__(self, outcomes: list[Any]) -> None:
        self.messages = StubMessages(outcomes)
        self.beta = type("Beta", (), {"messages": self.messages})()


_REQUEST = httpx2.Request("POST", "https://api.anthropic.example/v1/messages")


def _status_error(kind: type[anthropic.APIStatusError], status: int, headers: dict[str, str] | None = None) -> anthropic.APIStatusError:
    return kind("error", response=httpx2.Response(status, request=_REQUEST, headers=headers or {}), body=None)


def _package() -> prompt.PromptPackage:
    request = parse_request(request_body(), max_pages=6, max_regions=1500, max_image_bytes=6_000_000)
    return prompt.build(
        request, [page.image for page in request.pages], prompt.RegionAliases.build(request.regions), PROVIDER_OUTPUT_SCHEMA
    )


def _provider(outcomes: list[Any], **settings: Any) -> tuple[ClaudeReceiptProvider, StubClient]:
    client = StubClient(outcomes)
    provider = ClaudeReceiptProvider(
        Secret(FAKE_KEY), IntelligenceSettings(provider="anthropic", **settings), client_factory=lambda: client
    )
    provider.sleep = lambda _: None
    return provider, client


def test_request_shape_uses_structured_outputs_effort_and_refusal_fallback() -> None:
    provider, client = _provider([Response([Block(text(output()))])])
    result = provider.complete(_package(), time.monotonic() + 50)
    call = client.messages.calls[0]
    assert call["model"] == DEFAULT_MODEL and call["max_tokens"] == 16000
    assert call["output_config"] == {"effort": "medium", "format": {"type": "json_schema", "schema": PROVIDER_OUTPUT_SCHEMA}}
    assert call["betas"] == [FALLBACK_BETA] and call["fallbacks"] == "default"
    assert "thinking" not in call, "adaptive thinking is the model default; budgets are rejected on current models"
    assert call["messages"][0]["role"] == "user" and call["messages"][0]["content"][1]["type"] == "image"
    assert "untrusted" in call["system"] and 0 < call["timeout"] <= 50
    assert result.model == DEFAULT_MODEL and (result.input_tokens, result.output_tokens) == (6400, 1100)


def test_fallback_can_be_disabled() -> None:
    provider, client = _provider([Response([Block(text(output()))])], refusal_fallback=False, model="claude-sonnet-5-5", effort="low")
    provider.complete(_package(), time.monotonic() + 50)
    call = client.messages.calls[0]
    assert "betas" not in call and "fallbacks" not in call and call["model"] == "claude-sonnet-5-5"
    assert call["output_config"]["effort"] == "low"


def test_reports_the_model_that_answered() -> None:
    provider, _ = _provider([Response([Block(text(output()))], model="claude-opus-4-8")])
    assert provider.complete(_package(), time.monotonic() + 50).model == "claude-opus-4-8"


@pytest.mark.parametrize(("stop_reason", "code"), [("refusal", "refused"), ("max_tokens", "truncated")])
def test_stop_reasons(stop_reason: str, code: str) -> None:
    provider, _ = _provider([Response([Block("{}")], stop_reason=stop_reason)])
    with pytest.raises(ProviderError) as raised:
        provider.complete(_package(), time.monotonic() + 50)
    assert raised.value.code == code


def test_no_text_block_is_an_upstream_error() -> None:
    provider, _ = _provider([Response([Block("", type="thinking")])])
    with pytest.raises(ProviderError) as raised:
        provider.complete(_package(), time.monotonic() + 50)
    assert raised.value.code == "upstream"


def test_one_retry_for_short_rate_limit_then_success() -> None:
    provider, client = _provider([_status_error(anthropic.RateLimitError, 429, {"retry-after": "2"}), Response([Block(text(output()))])])
    assert provider.complete(_package(), time.monotonic() + 50).attempts == 2
    assert len(client.messages.calls) == 2


def test_long_rate_limit_is_not_retried() -> None:
    provider, client = _provider([_status_error(anthropic.RateLimitError, 429, {"retry-after": "30"})])
    with pytest.raises(ProviderError) as raised:
        provider.complete(_package(), time.monotonic() + 50)
    assert raised.value.code == "rate_limited" and raised.value.retry_after == 30 and len(client.messages.calls) == 1


def test_transient_errors_retry_once_only() -> None:
    errors = [_status_error(anthropic.OverloadedError, 529), _status_error(anthropic.InternalServerError, 500)]
    provider, client = _provider(errors)
    with pytest.raises(ProviderError) as raised:
        provider.complete(_package(), time.monotonic() + 50)
    assert raised.value.code == "overloaded" and len(client.messages.calls) == 2


def test_no_retry_when_deadline_is_near() -> None:
    provider, client = _provider([anthropic.APIConnectionError(request=_REQUEST)])
    with pytest.raises(ProviderError):
        provider.complete(_package(), time.monotonic() + 5)
    assert len(client.messages.calls) == 1


@pytest.mark.parametrize(
    ("error", "code"),
    [
        (anthropic.APITimeoutError(request=_REQUEST), "timeout"),
        (_status_error(anthropic.AuthenticationError, 401), "auth"),
        (_status_error(anthropic.PermissionDeniedError, 403), "auth"),
        (_status_error(anthropic.BadRequestError, 400), "bad_request"),
        (_status_error(anthropic.NotFoundError, 404), "upstream"),
    ],
)
def test_error_taxonomy(error: Exception, code: str) -> None:
    provider, client = _provider([error])
    with pytest.raises(ProviderError) as raised:
        provider.complete(_package(), time.monotonic() + 50)
    assert raised.value.code == code and len(client.messages.calls) == 1
    assert FAKE_KEY not in str(raised.value) and FAKE_KEY not in repr(raised.value)


def test_expired_deadline_never_calls_the_api() -> None:
    provider, client = _provider([])
    with pytest.raises(ProviderError) as raised:
        provider.complete(_package(), time.monotonic())
    assert raised.value.code == "timeout" and client.messages.calls == []
