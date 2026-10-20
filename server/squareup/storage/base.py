"""Storage boundary. Services depend on this interface, never on Datastore directly.

Records are JSON-compatible dictionaries grouped by *kind* and addressed by string key. A few
top-level scalar fields may be indexed for queries (``indexed``); everything else is an unindexed
payload. All reads and writes inside :meth:`Store.run_in_transaction` commit atomically, which is
how room revisions, idempotency records, and invitations stay consistent under concurrent writers.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from collections.abc import Callable
from typing import Any, TypeVar

T = TypeVar("T")

ROOM = "ReceiptRoom"
INVITATION = "RoomInvitation"
GUEST = "GuestCredential"
IDEMPOTENCY = "IdempotencyRecord"
RATE = "RateCounter"
ASSET = "ReceiptAsset"
#: Receipt-intelligence results and in-flight leases (structured proposals only, never images).
INTELLIGENCE = "ReceiptParse"
#: Keyed by the SHA-256 of a room invitation's short code, indexed by ``roomId`` and ``expiresAt``:
#: points at the invitation (by its token hash). Holds no code and no token.
ROOM_CODE = "RoomInvitationCode"

# Milestone 7: shared P2P groups.
#: Keyed by Firebase uid: display name, stable member ID, payment destinations.
ACCOUNT = "AccountProfile"
#: Keyed by group ID: the whole group ledger (see ``ledger.group``).
SHARED_GROUP = "SharedGroup"
#: Keyed by ``<uid>:<groupId>``, indexed by ``uid``: which groups an account belongs to.
GROUP_MEMBERSHIP = "GroupMembership"
#: Keyed by ``<groupId>:<page>``: the append-only event history, 100 events per page.
GROUP_EVENT_PAGE = "GroupEventPage"
#: Keyed by ``<groupId>:<expenseId>:<revision>``: immutable expense revisions.
EXPENSE_REVISION = "ExpenseRevision"
#: Keyed by the SHA-256 of the invitation code, indexed by ``groupId`` and ``expiresAt``.
GROUP_INVITATION = "GroupInvitation"
#: Keyed by ``<uid>:<publicationId>``: the result of publishing one local group (idempotent retry).
GROUP_PUBLICATION = "GroupPublication"
#: Keyed by ``<groupId>:<receiptId>``: one receipt posted into a shared group for asynchronous
#: allocation (the room format, ``kind: groupReceipt``). The group holds a small summary of each.
GROUP_RECEIPT = "GroupReceipt"

# Direct invitations ("Find a person", October 2026).
#: Keyed by a digest of one verified identifier (``directory_key``: kind and normalized value,
#: never the value itself): ``{"uid", "kind"}``. Lets a group member find an existing account by an
#: email address or phone number they already know. Written only for accounts with a profile.
ACCOUNT_DIRECTORY = "AccountDirectory"
#: Keyed by ``<groupId>:<recipient uid>`` (at most one per person per group), indexed by
#: ``groupId``, ``recipientUid``, and ``expiresAt``: one invitation sent to a specific account,
#: waiting for them to accept or decline.
DIRECT_INVITATION = "GroupDirectInvitation"

# Demo workspaces ("Enter Demo", October 2026).
#: Keyed by the SHA-256 of a demo credential, indexed by ``subject`` and ``expiresAt``: one device's
#: demo account (``demo-<random>``) and when it ends. Holds no credential.
DEMO_SESSION = "DemoSession"

# Deleting an account (October 2026).
#: Keyed by group ID, indexed by ``requestedBy`` (a uid) and ``createdAt``: a group nobody else had
#: joined, whose record is already gone (nobody can open or join it), and the keys of what's left to
#: delete. Removed once that's done; the hourly cleanup finishes any a deletion left behind.
GROUP_REMOVAL = "GroupRemoval"


class Transaction(ABC):
    @abstractmethod
    def get(self, kind: str, key: str) -> dict[str, Any] | None: ...

    @abstractmethod
    def put(self, kind: str, key: str, value: dict[str, Any], indexed: dict[str, Any] | None = None) -> None: ...

    @abstractmethod
    def delete(self, kind: str, key: str) -> None: ...


class Store(ABC):
    @abstractmethod
    def run_in_transaction(self, body: Callable[[Transaction], T]) -> T:
        """Run ``body`` atomically, retrying on contention. Raises ``TransientStoreError`` if it can't commit."""

    @abstractmethod
    def get(self, kind: str, key: str) -> dict[str, Any] | None: ...

    @abstractmethod
    def query(self, kind: str, field: str, value: Any, limit: int = 100) -> list[tuple[str, dict[str, Any]]]:
        """Records whose indexed ``field`` equals ``value``."""

    @abstractmethod
    def query_before(self, kind: str, field: str, cutoff: Any, limit: int = 200) -> list[tuple[str, dict[str, Any]]]:
        """Records whose indexed ``field`` is earlier than ``cutoff`` (cleanup)."""

    @abstractmethod
    def query_page(
        self, kind: str, field: str, value: Any, *, cursor: str | None = None, limit: int = 200, before: bool = False
    ) -> tuple[list[tuple[str, dict[str, Any]]], str | None]:
        """One page of :meth:`query` — or, with ``before``, of :meth:`query_before` with ``value`` as
        the cutoff — and the cursor of the next page (``None`` after the last one)."""

    def query_all(
        self, kind: str, field: str, value: Any, *, before: bool = False, page_size: int = 200
    ) -> list[tuple[str, dict[str, Any]]]:
        """Every matching record, page by page, with no limit. Collected before the caller acts, so
        deleting what it found can't make a later page skip anything."""
        results: list[tuple[str, dict[str, Any]]] = []
        cursor: str | None = None
        while True:
            page, cursor = self.query_page(kind, field, value, cursor=cursor, limit=page_size, before=before)
            results.extend(page)
            if cursor is None:
                return results

    @abstractmethod
    def ping(self) -> bool:
        """Readiness probe."""


class TransientStoreError(Exception):
    """The store couldn't commit (contention or outage). Nothing was changed; the client may retry."""
