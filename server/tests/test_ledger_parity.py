"""Swift/server parity for the shared ledger (milestone 7 §16.3): splits, multiple payers, rounding,
revisions, simplification, reservations, and payment outcomes. ``PARITY_RECORD=1`` rewrites the
recorded ``expect`` of every step; ``LedgerParityTests`` in the app asserts the same files."""

from __future__ import annotations

import json
import os

import pytest

from tests.ledger_parity import LEDGER_FIXTURES, LedgerRunner, ledger_fixture_names


def test_ledger_fixtures_exist() -> None:
    assert len(ledger_fixture_names()) >= 3


@pytest.mark.parametrize("name", ledger_fixture_names())
def test_ledger_fixture_matches(name: str) -> None:
    runner = LedgerRunner(name)
    results = runner.run()
    steps = runner.fixture["steps"]
    if os.environ.get("PARITY_RECORD") == "1":
        for step, result in zip(steps, results, strict=True):
            step["expect"] = result
        (LEDGER_FIXTURES / f"{name}.json").write_text(json.dumps(runner.fixture, indent=1) + "\n")
    for index, (step, result) in enumerate(zip(steps, results, strict=True)):
        assert "expect" in step, f"{name} step {index} has no recorded expectation (run with PARITY_RECORD=1 and review)"
        assert result == step["expect"], f"{name} step {index} ({step['actor']} {step['command']})"
