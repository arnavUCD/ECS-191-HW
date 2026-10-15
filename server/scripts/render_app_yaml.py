"""Render app.deploy.yaml: app.yaml plus the non-comment KEY=VALUE pairs of an env file.

Only SQUAREUP_* keys are copied (GOOGLE_CLOUD_PROJECT is provided by App Engine itself). ANTHROPIC_API_KEY
is deliberately never copied into app.yaml: production reads the key from Secret Manager at startup, and
SQUAREUP_ANTHROPIC_SECRET carries only the secret's resource name (README). As a last line of defense,
rendering stops if any value looks like an Anthropic key, without printing it.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

_KEY_LIKE = re.compile(r"sk-ant-", re.IGNORECASE)


def main(env_path: str, template_path: str, output_path: str) -> None:
    values: dict[str, str] = {}
    for raw in Path(env_path).read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key.startswith("SQUAREUP_") and value:
            if key == "SQUAREUP_ALLOW_DEV_AUTH":
                sys.exit("SQUAREUP_ALLOW_DEV_AUTH must not be deployed")
            if key == "SQUAREUP_AI_RECORDED_DIR":
                sys.exit("The recorded AI provider must not be deployed")
            if _KEY_LIKE.search(value):
                sys.exit(f"{key} looks like an API key; keys belong in Secret Manager, never in app.yaml")
            values[key] = value
    lines = Path(template_path).read_text().splitlines()
    index = lines.index("env_variables:") + 1
    rendered = [f"  {key}: {json.dumps(value)}" for key, value in sorted(values.items())]
    Path(output_path).write_text("\n".join(lines[:index] + rendered + lines[index:]) + "\n")


if __name__ == "__main__":
    main(*sys.argv[1:4])
