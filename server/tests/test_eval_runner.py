"""The opt-in evaluation runner: refuses without a key, and its plumbing works (oracle mode, no API calls)."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
from types import ModuleType

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "run_receipt_eval.py"


def _runner() -> ModuleType:
    spec = importlib.util.spec_from_file_location("run_receipt_eval", SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_refuses_without_a_key(monkeypatch: pytest.MonkeyPatch, tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    runner = _runner()
    setattr(runner, "load_local_env", lambda _: None)  # noqa: B010 - module attribute on a dynamically loaded script
    # After loading: importing the runner imports ``main``, which must not have brought a key back.
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    assert runner.main(["--output", str(tmp_path)]) == 2
    assert "Nothing was sent" in capsys.readouterr().out and not list(tmp_path.iterdir())


def test_oracle_mode_exercises_the_full_server_path(tmp_path: Path) -> None:
    runner = _runner()
    setattr(runner, "load_local_env", lambda _: None)  # noqa: B010 - module attribute on a dynamically loaded script
    assert runner.main(["--oracle", "--output", str(tmp_path), "--case", "prompt-injection", "--case", "yen"]) == 0
    summary = json.loads((tmp_path / "summary.json").read_text())
    assert summary["model"] == "oracle" and {run["outcome"] for run in summary["runs"]} == {"ok"}
    response = json.loads((tmp_path / "yen.json").read_text())
    assert response["proposal"]["total"]["value"] == 1350 and response["validation"]["reconciled"] is True
