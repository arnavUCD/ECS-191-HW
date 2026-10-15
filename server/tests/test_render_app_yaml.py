"""``scripts/render_app_yaml.py``: what reaches the deployed app.yaml, and what never does."""

from __future__ import annotations

import importlib.util
from pathlib import Path
from types import ModuleType

import pytest

SCRIPTS = Path(__file__).resolve().parent.parent / "scripts"
FAKE_KEY = "sk-ant-api03-" + "Z" * 40


def renderer() -> ModuleType:
    spec = importlib.util.spec_from_file_location("render_app_yaml", SCRIPTS / "render_app_yaml.py")
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def render(tmp_path: Path, env: str) -> str:
    (tmp_path / "deploy.env").write_text(env)
    template = Path(__file__).resolve().parent.parent / "app.yaml"
    renderer().main(str(tmp_path / "deploy.env"), str(template), str(tmp_path / "out.yaml"))
    return (tmp_path / "out.yaml").read_text()


def test_the_secret_resource_name_is_deployed_but_never_a_key(tmp_path: Path) -> None:
    rendered = render(
        tmp_path,
        "GOOGLE_CLOUD_PROJECT=demo\nSQUAREUP_AI_PROVIDER=anthropic\n"
        "SQUAREUP_ANTHROPIC_SECRET=projects/demo/secrets/anthropic-api-key/versions/latest\n"
        f"ANTHROPIC_API_KEY={FAKE_KEY}\nSQUAREUP_AI_DAILY_LIMIT_PROJECT=50\n",
    )
    assert 'SQUAREUP_ANTHROPIC_SECRET: "projects/demo/secrets/anthropic-api-key/versions/latest"' in rendered
    assert 'SQUAREUP_AI_PROVIDER: "anthropic"' in rendered and 'SQUAREUP_AI_DAILY_LIMIT_PROJECT: "50"' in rendered
    assert FAKE_KEY not in rendered and "ANTHROPIC_API_KEY" not in rendered and "GOOGLE_CLOUD_PROJECT" not in rendered


def test_a_key_shaped_value_stops_rendering_without_printing_it(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    with pytest.raises(SystemExit) as stopped:
        render(tmp_path, f"SQUAREUP_ANTHROPIC_SECRET={FAKE_KEY}\n")
    assert FAKE_KEY not in str(stopped.value) and FAKE_KEY not in capsys.readouterr().out
    assert not (tmp_path / "out.yaml").exists()


def test_development_settings_are_never_deployed(tmp_path: Path) -> None:
    with pytest.raises(SystemExit):
        render(tmp_path, "SQUAREUP_ALLOW_DEV_AUTH=1\n")
