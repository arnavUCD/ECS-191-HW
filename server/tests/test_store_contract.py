"""The storage contract every backend must satisfy (milestone 4 §9.4).

Runs against ``MemoryStore`` always, and against the real ``DatastoreStore`` adapter when the
Datastore emulator is reachable (``DATASTORE_EMULATOR_HOST``; see ``server/README.md``).
"""

from __future__ import annotations

import os
import threading
import uuid
from collections.abc import Callable

import pytest

from squareup.storage.base import Store, Transaction
from squareup.storage.memory import MemoryStore

KIND = "ContractRecord"


def _memory() -> Store:
    return MemoryStore()


def _datastore() -> Store:
    from squareup.storage.datastore_store import DatastoreStore

    return DatastoreStore(os.environ.get("DATASTORE_PROJECT_ID", "squareup-emulator"), namespace=f"t{uuid.uuid4().hex}")


BACKENDS: list[object] = [pytest.param(_memory, id="memory")]
BACKENDS.append(
    pytest.param(
        _datastore,
        id="datastore",
        marks=pytest.mark.skipif(not os.environ.get("DATASTORE_EMULATOR_HOST"), reason="Datastore emulator not running"),
    )
)


@pytest.fixture(params=BACKENDS)
def store(request: pytest.FixtureRequest) -> Store:
    factory: Callable[[], Store] = request.param
    return factory()


def test_put_get_query_and_delete(store: Store) -> None:
    def write(transaction: Transaction) -> None:
        transaction.put(
            KIND,
            "a",
            {"roomId": "r1", "nested": {"x": [1, 2]}, "expiresAt": "2026-01-01"},
            indexed={"roomId": "r1", "expiresAt": "2026-01-01"},
        )
        transaction.put(KIND, "b", {"roomId": "r2"}, indexed={"roomId": "r2", "expiresAt": "2027-01-01"})

    store.run_in_transaction(write)
    assert store.get(KIND, "a") == {"roomId": "r1", "nested": {"x": [1, 2]}, "expiresAt": "2026-01-01"}
    assert [key for key, _ in store.query(KIND, "roomId", "r2")] == ["b"]
    assert [key for key, _ in store.query_before(KIND, "expiresAt", "2026-06-01")] == ["a"]
    store.run_in_transaction(lambda transaction: transaction.delete(KIND, "a"))
    assert store.get(KIND, "a") is None
    assert store.get(KIND, "missing") is None
    assert store.ping()


def test_failed_transaction_writes_nothing(store: Store) -> None:
    def write_then_fail(transaction: Transaction) -> None:
        transaction.put(KIND, "partial", {"value": 1})
        raise RuntimeError("boom")

    with pytest.raises(RuntimeError):
        store.run_in_transaction(write_then_fail)
    assert store.get(KIND, "partial") is None


def test_concurrent_read_modify_write_never_loses_updates(store: Store) -> None:
    store.run_in_transaction(lambda transaction: transaction.put(KIND, "counter", {"value": 0}))
    barrier = threading.Barrier(4)

    def increment(transaction: Transaction) -> None:
        current = transaction.get(KIND, "counter")
        assert current is not None
        transaction.put(KIND, "counter", {"value": current["value"] + 1})

    def worker() -> None:
        barrier.wait()
        for _ in range(3):
            store.run_in_transaction(increment)

    threads = [threading.Thread(target=worker) for _ in range(4)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    assert store.get(KIND, "counter") == {"value": 12}
