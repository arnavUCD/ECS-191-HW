#!/usr/bin/env bash
# Deploys the API to App Engine Standard. Reads environment-specific values from deploy.env
# (gitignored; copy .env.example), runs the quality gate, renders app.deploy.yaml, then deploys.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ! -f deploy.env ]]; then
  echo "Missing deploy.env — copy .env.example and fill in your project values." >&2
  exit 1
fi

# Checked before deploy.env is sourced, so a stray key is never even exported.
if grep -q '^ANTHROPIC_API_KEY=.' deploy.env; then
  echo "deploy.env must not contain ANTHROPIC_API_KEY; production reads the key from Secret Manager." >&2
  exit 1
fi

# The quality gate runs before deploy.env is loaded, so deployment settings (AI provider, secret
# resource) never reach the test environment.
scripts/check.sh

set -a; source deploy.env; set +a
: "${GOOGLE_CLOUD_PROJECT:?Set GOOGLE_CLOUD_PROJECT in deploy.env}"
: "${SQUAREUP_ASSET_BUCKET:?Set SQUAREUP_ASSET_BUCKET in deploy.env}"

.venv/bin/python scripts/render_app_yaml.py deploy.env app.yaml app.deploy.yaml
# Extra arguments go to gcloud, e.g. `scripts/deploy.sh --no-promote` to check a version before it gets traffic.
gcloud app deploy app.deploy.yaml cron.yaml index.yaml --project "$GOOGLE_CLOUD_PROJECT" --quiet "$@"
rm -f app.deploy.yaml
