#!/usr/bin/env bash
# Server quality gate: tests, lint, format, types, security scan, and dependency audit.
# If DATASTORE_EMULATOR_HOST is set, the suite also runs against the real Datastore adapter.
set -euo pipefail
cd "$(dirname "$0")/.."
PY=.venv/bin/python

$PY -m pytest -q
if [[ -n "${DATASTORE_EMULATOR_HOST:-}" ]]; then
  SQUAREUP_TEST_STORE=datastore $PY -m pytest -q
fi
.venv/bin/ruff check .
.venv/bin/ruff format --check .
.venv/bin/mypy .
.venv/bin/bandit -q -c pyproject.toml -r squareup main.py
.venv/bin/pip-audit -r requirements.txt
echo "Server quality gate passed."
