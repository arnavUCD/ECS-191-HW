"""Who may use paid receipt intelligence, and how much: verified email, configurable daily limits."""

from __future__ import annotations

from typing import Any

import pytest

from squareup.config import Config
from squareup.intelligence.provider import FakeProvider
from squareup.intelligence.settings import IntelligenceSettings

from .conftest import build
from .intelligence_kit import ACCOUNT, PARSE, jpeg, output, request_body, text

UNVERIFIED = {"Authorization": "Bearer unverified-ai-user"}


def test_an_unverified_email_cannot_use_paid_ai() -> None:
    provider = FakeProvider(lambda _: text(output()))
    env = build(intelligence_provider=provider)
    response = env.client.post(PARSE, json=request_body(), headers=UNVERIFIED)
    assert response.status_code == 403
    assert response.json["error"]["code"] == "email_not_verified"
    body = response.get_data(as_text=True)
    assert "ai-user" not in body and "email_verified" not in body and "claims" not in body, "no private claims in the answer"
    assert provider.calls == [], "the provider is never reached"


def test_a_verified_email_can_use_ai() -> None:
    env = build(intelligence_provider=FakeProvider(lambda _: text(output())))
    assert env.client.post(PARSE, json=request_body(), headers=ACCOUNT).status_code == 200


def test_an_unverified_account_can_still_delete_its_cached_results() -> None:
    env = build(intelligence_provider=FakeProvider(lambda _: text(output())))
    response = env.client.delete("/v1/receipt-intelligence/cache", headers=UNVERIFIED)
    assert response.status_code == 200 and response.json == {"removed": 0}


def test_verification_does_not_affect_other_apis() -> None:
    env = build()
    assert env.client.get("/v1/account", headers=UNVERIFIED).status_code == 200


def test_production_limits_are_conservative_by_default() -> None:
    settings = IntelligenceSettings.from_environment({})
    assert (settings.daily_limit_per_account, settings.daily_limit_project, settings.minute_limit_per_account) == (10, 50, 6)
    defaults = Config()
    assert defaults.rate_limits["intelligence-daily"] == (10, 86_400) and defaults.rate_limits["intelligence-global"] == (50, 86_400)


def test_limits_are_configurable(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("SQUAREUP_AI_DAILY_LIMIT_PER_ACCOUNT", "3")
    monkeypatch.setenv("SQUAREUP_AI_DAILY_LIMIT_PROJECT", "7")
    monkeypatch.setenv("SQUAREUP_AI_MINUTE_LIMIT", "2")
    limits = Config.from_environment().rate_limits
    assert (
        limits["intelligence-daily"] == (3, 86_400) and limits["intelligence-global"] == (7, 86_400) and limits["intelligence"] == (2, 60)
    )


@pytest.mark.parametrize("value", ["0", "-1", "lots"])
def test_invalid_limits_refuse_to_start(value: str) -> None:
    with pytest.raises((RuntimeError, ValueError)):
        IntelligenceSettings.from_environment({"SQUAREUP_AI_DAILY_LIMIT_PROJECT": value})


def test_the_project_cap_counts_provider_calls_only() -> None:
    limits: dict[str, Any] = {
        "intelligence": (100, 60),
        "intelligence-daily": (100, 86_400),
        "intelligence-global": (2, 86_400),
        "command": (240, 60),
    }
    provider = FakeProvider(lambda _: text(output()))
    env = build(intelligence_provider=provider, rate_limits=limits)
    for _ in range(4):
        assert env.client.post(PARSE, json=request_body(), headers=ACCOUNT).status_code == 200  # one call, then cache hits
    assert env.client.post(PARSE, json=request_body(images=[jpeg(901)]), headers=ACCOUNT).status_code == 200
    blocked = env.client.post(PARSE, json=request_body(images=[jpeg(902)]), headers=ACCOUNT)
    assert blocked.status_code == 429 and len(provider.calls) == 2
