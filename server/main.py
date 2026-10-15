"""App Engine entry point (``gunicorn main:app``)."""

import os
from pathlib import Path

from squareup import create_app


def load_local_env(path: Path) -> None:
    """Local development only: read ``KEY=VALUE`` lines from the gitignored ``server/.env``.

    Values already in the environment win. Nothing is printed. On App Engine this never runs (and
    ``.env`` is excluded from deployment by ``.gcloudignore``); production secrets come from the
    deployment environment or Secret Manager.
    """
    if os.environ.get("GAE_ENV", "").startswith("standard") or not path.is_file():
        return
    # The automated test suite sets this so a developer's real key can never reach a test.
    if os.environ.get("SQUAREUP_SKIP_LOCAL_ENV") == "1":
        return
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


load_local_env(Path(__file__).with_name(".env"))
app = create_app()

if __name__ == "__main__":  # local development: python main.py
    # Loopback by default; set SQUAREUP_BIND_HOST=0.0.0.0 to reach the server from a device on the LAN.
    app.run(host=os.environ.get("SQUAREUP_BIND_HOST", "127.0.0.1"), port=int(os.environ.get("PORT", "8080")), debug=False)
