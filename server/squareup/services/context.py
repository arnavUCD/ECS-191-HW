"""Shared service dependencies (configuration, storage, clock) and small helpers."""

from __future__ import annotations

import hashlib
import json
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any

from ..auth.identity import TokenVerifier
from ..config import Config
from ..storage.base import Store
from ..storage.blobs import BlobStore


def utc_now() -> datetime:
    return datetime.now(UTC)


def iso(moment: datetime) -> str:
    return moment.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def parse_iso(text: str) -> datetime:
    return datetime.strptime(text, "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=UTC)


def fingerprint(value: Any) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


@dataclass
class ServiceContext:
    config: Config
    store: Store
    blobs: BlobStore
    verify_firebase: TokenVerifier | None
    clock: Callable[[], datetime] = utc_now

    def now(self) -> datetime:
        return self.clock()

    def now_iso(self) -> str:
        return iso(self.clock())

    def expires_in(self, hours: int) -> str:
        return iso(self.clock() + timedelta(hours=hours))
