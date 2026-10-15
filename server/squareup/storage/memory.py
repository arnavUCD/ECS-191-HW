"""In-memory store for tests and local development. Transactions are serializable: a global lock
plus copy-on-write staging, so a failing body leaves no partial writes. As in Datastore, a read
inside a transaction never sees that transaction's own uncommitted writes."""

from __future__ import annotations

import copy
import threading
from collections.abc import Callable
from typing import Any, TypeVar

from .base import Store, Transaction

T = TypeVar("T")


class _MemoryTransaction(Transaction):
    def __init__(self, data: dict[tuple[str, str], tuple[dict[str, Any], dict[str, Any]]]) -> None:
        self._data = data
        self._staged: dict[tuple[str, str], tuple[dict[str, Any], dict[str, Any]] | None] = {}

    def get(self, kind: str, key: str) -> dict[str, Any] | None:
        # Like Datastore, reads inside a transaction see the committed state, never this
        # transaction's own uncommitted writes — so code relying on that fails here too.
        record = self._data.get((kind, key))
        return None if record is None else copy.deepcopy(record[0])

    def put(self, kind: str, key: str, value: dict[str, Any], indexed: dict[str, Any] | None = None) -> None:
        self._staged[(kind, key)] = (copy.deepcopy(value), dict(indexed or {}))

    def delete(self, kind: str, key: str) -> None:
        self._staged[(kind, key)] = None

    def commit(self) -> None:
        for location, record in self._staged.items():
            if record is None:
                self._data.pop(location, None)
            else:
                self._data[location] = record


class MemoryStore(Store):
    def __init__(self) -> None:
        self._data: dict[tuple[str, str], tuple[dict[str, Any], dict[str, Any]]] = {}
        self._lock = threading.RLock()
        #: Test hook: called inside each transaction before the body (simulates interleaving).
        self.before_body: Callable[[], None] | None = None

    def run_in_transaction(self, body: Callable[[Transaction], T]) -> T:
        with self._lock:
            if self.before_body:
                self.before_body()
            transaction = _MemoryTransaction(self._data)
            result = body(transaction)
            transaction.commit()
            return result

    def get(self, kind: str, key: str) -> dict[str, Any] | None:
        with self._lock:
            record = self._data.get((kind, key))
            return None if record is None else copy.deepcopy(record[0])

    def query(self, kind: str, field: str, value: Any, limit: int = 100) -> list[tuple[str, dict[str, Any]]]:
        with self._lock:
            matches = [
                (key, copy.deepcopy(record[0])) for (k, key), record in self._data.items() if k == kind and record[1].get(field) == value
            ]
            return matches[:limit]

    def query_before(self, kind: str, field: str, cutoff: Any, limit: int = 200) -> list[tuple[str, dict[str, Any]]]:
        with self._lock:
            matches = [
                (key, copy.deepcopy(record[0]))
                for (k, key), record in self._data.items()
                if k == kind and record[1].get(field) is not None and record[1][field] < cutoff
            ]
            return matches[:limit]

    def ping(self) -> bool:
        return True

    def count(self, kind: str) -> int:
        with self._lock:
            return sum(1 for (k, _) in self._data if k == kind)
