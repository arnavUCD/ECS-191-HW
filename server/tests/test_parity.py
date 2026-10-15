"""Swift/server parity (milestone 4 §14.1): every shared fixture must reproduce its recorded
step outcomes and final allocation exactly. ``PARITY_RECORD=1`` rewrites ``expect`` blocks; the
Swift runner (``ParityFixtureTests``) asserts the same files."""

from __future__ import annotations

import json
import os

import pytest

from tests.parity import FIXTURES, Runner, fixture_names


@pytest.mark.parametrize("name", fixture_names())
def test_fixture_matches(name: str) -> None:
    runner = Runner(name)
    outcomes, final = runner.run()
    steps = runner.fixture["steps"]
    for index, (step, outcome) in enumerate(zip(steps, outcomes, strict=True)):
        assert outcome == step["expect"], f"{name} step {index} ({step['actor']} {step['command']}): {outcome} != {step['expect']}"
    if os.environ.get("PARITY_RECORD") == "1":
        fixture = runner.fixture
        fixture["expect"] = final
        (FIXTURES / f"{name}.json").write_text(json.dumps(fixture, indent=1) + "\n")
    assert "expect" in runner.fixture, f"{name} has no recorded expectation (run with PARITY_RECORD=1 and review)"
    assert final == runner.fixture["expect"]
