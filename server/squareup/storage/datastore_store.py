"""Firestore in Datastore mode via ``google-cloud-datastore``.

Each record is an entity whose JSON ``payload`` is excluded from indexes; only the explicitly
indexed scalar properties (e.g. ``roomId``, ``expiresAt``) are queryable. Transactions use
Datastore's serializable transactions and are retried on contention, so two writers racing on one
room can never both commit against the same revision.
"""

from __future__ import annotations

import json
import time
from collections.abc import Callable
from typing import Any, TypeVar

from google.api_core import exceptions as gexc
from google.cloud import datastore

from .base import Store, Transaction, TransientStoreError

T = TypeVar("T")

_RETRYABLE = (gexc.Aborted, gexc.Conflict, gexc.ServiceUnavailable, gexc.DeadlineExceeded, gexc.InternalServerError)


class _DatastoreTransaction(Transaction):
    def __init__(self, client: datastore.Client, transaction: Any, namespace: str | None) -> None:
        self._client = client
        self._transaction = transaction
        self._namespace = namespace

    def _key(self, kind: str, key: str) -> datastore.Key:
        return self._client.key(kind, key, namespace=self._namespace)

    def get(self, kind: str, key: str) -> dict[str, Any] | None:
        entity = self._client.get(self._key(kind, key), transaction=self._transaction)
        return None if entity is None else json.loads(entity["payload"])

    def put(self, kind: str, key: str, value: dict[str, Any], indexed: dict[str, Any] | None = None) -> None:
        entity = datastore.Entity(key=self._key(kind, key), exclude_from_indexes=("payload",))
        entity["payload"] = json.dumps(value, separators=(",", ":"), sort_keys=True)
        for name, field_value in (indexed or {}).items():
            entity[name] = field_value
        self._transaction.put(entity)

    def delete(self, kind: str, key: str) -> None:
        self._transaction.delete(self._key(kind, key))


class DatastoreStore(Store):
    def __init__(self, project: str | None, namespace: str | None = None, attempts: int = 5) -> None:
        self._client = datastore.Client(project=project, namespace=namespace)
        self._namespace = namespace
        self._attempts = attempts

    def run_in_transaction(self, body: Callable[[Transaction], T]) -> T:
        delay = 0.05
        for attempt in range(self._attempts):
            try:
                with self._client.transaction() as transaction:
                    return body(_DatastoreTransaction(self._client, transaction, self._namespace))
            except _RETRYABLE:
                if attempt == self._attempts - 1:
                    break
                time.sleep(delay)
                delay *= 2
        raise TransientStoreError("Datastore transaction could not commit")

    def get(self, kind: str, key: str) -> dict[str, Any] | None:
        try:
            entity = self._client.get(self._client.key(kind, key, namespace=self._namespace))
        except _RETRYABLE as error:
            raise TransientStoreError("Datastore read failed") from error
        return None if entity is None else json.loads(entity["payload"])

    def query(self, kind: str, field: str, value: Any, limit: int = 100) -> list[tuple[str, dict[str, Any]]]:
        query = self._client.query(kind=kind, namespace=self._namespace)
        query.add_filter(filter=datastore.query.PropertyFilter(field, "=", value))
        return [(entity.key.name, json.loads(entity["payload"])) for entity in query.fetch(limit=limit)]

    def query_before(self, kind: str, field: str, cutoff: Any, limit: int = 200) -> list[tuple[str, dict[str, Any]]]:
        query = self._client.query(kind=kind, namespace=self._namespace)
        query.add_filter(filter=datastore.query.PropertyFilter(field, "<", cutoff))
        return [(entity.key.name, json.loads(entity["payload"])) for entity in query.fetch(limit=limit)]

    def count(self, kind: str) -> int:
        """Number of records of ``kind`` (tests and diagnostics; not used on request paths)."""
        query = self._client.query(kind=kind, namespace=self._namespace)
        query.keys_only()
        return sum(1 for _ in query.fetch())

    def ping(self) -> bool:
        try:
            self._client.get(self._client.key("Readiness", "probe", namespace=self._namespace))
            return True
        except Exception:
            return False
