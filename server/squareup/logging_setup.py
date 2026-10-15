"""Privacy-safe structured logging and request identifiers.

Log lines are single JSON objects (App Engine parses them into Cloud Logging fields). They carry
the request ID, route *template*, status, latency, and coarse actor kind — never tokens, names,
receipt text, item names, amounts, image URLs, or raw identifiers. Identifiers that help
correlate events are logged as short salted hashes.
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
import sys
import uuid
from typing import Any

_SALT = os.environ.get("SQUAREUP_LOG_SALT", "squareup")
_REQUEST_ID_CHARS = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        entry: dict[str, Any] = {"severity": record.levelname, "message": record.getMessage(), "logger": record.name}
        fields = getattr(record, "fields", None)
        if isinstance(fields, dict):
            entry.update(fields)
        return json.dumps(entry, separators=(",", ":"))


def configure() -> logging.Logger:
    logger = logging.getLogger("squareup")
    if not logger.handlers:
        handler = logging.StreamHandler(sys.stdout)
        handler.setFormatter(JsonFormatter())
        logger.addHandler(handler)
        logger.setLevel(logging.INFO)
        logger.propagate = False
    return logger


def redact(identifier: str | None) -> str | None:
    """A short, salted, non-reversible tag for correlating an identifier across log lines."""
    if not identifier:
        return None
    return hashlib.sha256(f"{_SALT}:{identifier}".encode()).hexdigest()[:10]


def request_id_from(header: str | None) -> str:
    if header and 8 <= len(header) <= 64 and set(header) <= _REQUEST_ID_CHARS:
        return header
    return uuid.uuid4().hex


def log_event(message: str, **fields: Any) -> None:
    configure().info(message, extra={"fields": fields})
