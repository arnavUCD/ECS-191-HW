"""Shared P2P groups (milestone 7): the server is the authority once a group is shared.

Every mutation runs in one store transaction that (1) loads the group, (2) authorizes the caller
as an active member (and owner where required), (3) checks the idempotency key, (4) checks the
expected revision for revision-strict commands, (5) runs the deterministic command
(``ledger.commands``), and (6) writes the group, its new events, immutable expense revisions,
membership changes, and the idempotency record together — or nothing.

Reads (snapshot, changes) also run inside a transaction, so a client never sees a group revision
whose events or entities are half-written.

Balances are never accepted from a client: every snapshot and change page carries the balances
the server derived from the authoritative expenses, confirmed settlements, and reserved
payments, and the app checks its own calculation against them.
"""

from __future__ import annotations

import contextlib
import json
import secrets
import uuid
from collections.abc import Callable
from datetime import timedelta
from typing import Any

from ..auth.identity import Principal, token_hash
from ..domain.errors import DomainError
from ..domain.room import require_int, require_text, require_uuid
from ..domain.wire import room_from_storage, room_snapshot
from ..ledger import group as model
from ..ledger import receipts as group_receipts
from ..ledger.commands import REVISION_STRICT, Context, run
from ..ledger.rules import settlement_plan, validate_expense
from ..logging_setup import log_event, redact
from ..storage.base import (
    ACCOUNT,
    EXPENSE_REVISION,
    GROUP_EVENT_PAGE,
    GROUP_INVITATION,
    GROUP_MEMBERSHIP,
    GROUP_PUBLICATION,
    GROUP_RECEIPT,
    IDEMPOTENCY,
    ROOM,
    SHARED_GROUP,
    Transaction,
)
from .accounts import AccountService, destination_summary
from .context import ServiceContext, fingerprint, iso, parse_iso
from .rooms import CommandEnvelope

#: Reads one stored record (a transaction's ``get``, or the store's outside one).
Reader = Callable[[str, str], dict[str, Any] | None]
#: Finished group receipts stay in snapshots this long, so every device sees how they ended.
RECENT_RECEIPTS = timedelta(days=7)
#: Group commands that act on one group receipt (responses carry its current view).
RECEIPT_COMMAND_TYPES = frozenset({"postReceipt", "receiptCommand", "finalizeReceipt", "cancelReceipt"})

EVENT_PAGE_SIZE = 100
#: A client further behind than this gets ``cursorExpired`` and fetches a full snapshot.
MAX_CHANGE_EVENTS = 300
#: History returned with a snapshot (most recent first when truncated).
MAX_SNAPSHOT_EVENTS = 2_000
MAX_IMPORTED_EVENTS = 1_500

#: Crockford Base32 without I, L, O, U: unambiguous when read aloud or typed.
CODE_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
CODE_LENGTH = 20  # 100 bits

EVENT_KINDS = frozenset(
    {
        "groupCreated",
        "groupPublished",
        "groupEdited",
        "groupArchived",
        "simplificationChanged",
        "memberAdded",
        "memberInvited",
        "memberJoined",
        "memberRemoved",
        "memberLeft",
        "ownershipTransferred",
        "expenseCreated",
        "expenseEdited",
        "expenseDeleted",
        "expenseRestored",
        "receiptRoomOpened",
        "receiptRoomFinalized",
        "receiptRoomCancelled",
        "receiptRoomAdopted",
        "settlementRecorded",
        "paymentStarted",
        "paymentHandoffOpened",
        "paymentReported",
        "paymentConfirmed",
        "paymentRejected",
        "paymentDisputed",
        "paymentCancelled",
    }
)


def new_invitation_code() -> str:
    return "".join(secrets.choice(CODE_ALPHABET) for _ in range(CODE_LENGTH))


def normalize_code(text: str) -> str | None:
    """Accepts the code with or without separators, in any case, with Crockford substitutions."""
    if len(text) > 64:
        return None
    cleaned = text.upper().replace("-", "").replace(" ", "").replace("O", "0").replace("I", "1").replace("L", "1")
    if len(cleaned) != CODE_LENGTH or any(character not in CODE_ALPHABET for character in cleaned):
        return None
    return cleaned


def display_code(code: str) -> str:
    return "-".join(code[index : index + 4] for index in range(0, len(code), 4))


class GroupService:
    def __init__(self, ctx: ServiceContext, accounts: AccountService) -> None:
        self.ctx = ctx
        self.accounts = accounts

    # MARK: - Loading and authorization

    @staticmethod
    def _load(transaction: Transaction, group_id: str) -> dict[str, Any]:
        group = transaction.get(SHARED_GROUP, group_id)
        if group is None:
            raise DomainError("group_not_found", "This group isn't available")
        return group

    @staticmethod
    def _seat(group: dict[str, Any], principal: Principal) -> dict[str, Any]:
        """The caller's active seat. Anyone else learns nothing about the group's contents."""
        seat = model.member_for_uid(group, principal.subject)
        if seat is not None:
            return seat
        former = next((m for m in group["members"] if m.get("uid") == principal.subject), None)
        if former is not None:
            raise DomainError("not_a_member", "You're no longer in this group")
        raise DomainError("group_not_found", "This group isn't available")

    def _caller(self, principal: Principal | None) -> Principal:
        return self.accounts.require_account(principal)

    @staticmethod
    def _put_group(transaction: Transaction, group: dict[str, Any]) -> None:
        if model.group_bytes(group) > model.MAX_GROUP_BYTES:
            raise DomainError("group_full", "This group has reached its size limit")
        transaction.put(SHARED_GROUP, group["id"], group, indexed={"updatedAt": group["updatedAt"]})

    @staticmethod
    def _put_membership(transaction: Transaction, uid: str, group_id: str, member_id: str, *, active: bool) -> None:
        transaction.put(
            GROUP_MEMBERSHIP,
            f"{uid}:{group_id}",
            {"groupId": group_id, "memberId": member_id, "active": active},
            indexed={"uid": uid, "active": active},
        )

    @staticmethod
    def _append_events(transaction: Transaction, group_id: str, events: list[dict[str, Any]]) -> None:
        """Appends to the paged history (100 events per page; pages are append-only)."""
        pages: dict[int, dict[str, Any]] = {}
        for event in events:
            page = (event["sequence"] - 1) // EVENT_PAGE_SIZE
            if page not in pages:
                pages[page] = transaction.get(GROUP_EVENT_PAGE, f"{group_id}:{page:06d}") or {"events": []}
            pages[page]["events"].append(event)
        for page, record in pages.items():
            transaction.put(GROUP_EVENT_PAGE, f"{group_id}:{page:06d}", record)

    @staticmethod
    def _events_after(transaction: Transaction, group: dict[str, Any], after: int, limit: int) -> list[dict[str, Any]]:
        last = group["eventSequence"]
        first = max(after + 1, last - limit + 1, 1)
        events: list[dict[str, Any]] = []
        for page in range((first - 1) // EVENT_PAGE_SIZE, (last - 1) // EVENT_PAGE_SIZE + 1 if last else 0):
            record = transaction.get(GROUP_EVENT_PAGE, f"{group['id']}:{page:06d}") or {"events": []}
            events.extend(event for event in record["events"] if first <= event["sequence"] <= last)
        return sorted(events, key=lambda event: event["sequence"])

    # MARK: - Views

    def _providers(self, group: dict[str, Any]) -> dict[str, list[str]]:
        """Enabled payment methods per joined member — provider names only."""
        providers: dict[str, list[str]] = {}
        for member in group["members"]:
            if member["status"] != "active" or not member.get("uid"):
                continue
            profile = self.ctx.store.get(ACCOUNT, member["uid"])
            if profile is not None:
                names: list[str] = []
                for destination in profile["destinations"]:
                    if destination["isEnabled"] and destination["provider"] not in names:
                        names.append(destination["provider"])
                providers[member["id"]] = names
        return providers

    def _receipt_view(self, read: Reader, group: dict[str, Any], seat: dict[str, Any], entry: dict[str, Any]) -> dict[str, Any]:
        """One pending (or recently finished) group receipt as this member may see it. The people on
        it get the whole receipt — items, claims, everyone's estimated share. Anyone else in the
        group sees only that it exists: who's splitting what, with how many people, and its state."""
        participates = seat["id"] in entry["participantIds"]
        view: dict[str, Any] = {
            key: entry.get(key)
            for key in ("id", "state", "hostMemberId", "payerId", "participantIds", "merchant", "date", "currency", "total", "revision")
        }
        view.update(
            {
                "createdAt": entry.get("createdAt"),
                "updatedAt": entry.get("updatedAt"),
                "expenseId": entry.get("expenseId"),
                "unreviewedCount": len(entry.get("unreviewed", [])),
                "viewerIsParticipant": participates,
                "room": None,
            }
        )
        if participates:
            record = read(GROUP_RECEIPT, f"{group['id']}:{entry['id']}")
            if record is not None:
                room = room_from_storage(record)
                view["room"] = room_snapshot(room, seat["id"], seat["id"] == room.host_participant_id)
        return view

    def _receipt_views(
        self, read: Reader, group: dict[str, Any], seat: dict[str, Any], only: set[str] | None = None
    ) -> list[dict[str, Any]]:
        """Pending receipts, plus finished ones for a week so every device sees how they ended
        (``only``: just these, for a change page)."""
        recent = iso(self.ctx.now() - RECENT_RECEIPTS)
        views: list[dict[str, Any]] = []
        for entry in group.get("receipts", []):
            if only is not None:
                if entry["id"] not in only:
                    continue
            elif entry["state"] in ("finalized", "cancelled") and (entry.get("updatedAt") or "") < recent:
                continue
            views.append(self._receipt_view(read, group, seat, entry))
        return views

    def _snapshot_view(
        self,
        group: dict[str, Any],
        seat: dict[str, Any],
        events: list[dict[str, Any]],
        complete: bool,
        receipt_views: list[dict[str, Any]] | None = None,
    ) -> dict[str, Any]:
        providers = self._providers(group)
        return {
            "schemaVersion": model.SCHEMA_VERSION,
            "serverTime": self.ctx.now_iso(),
            "revision": group["revision"],
            "cursor": group["eventSequence"],
            "group": model.header_view(group),
            "viewer": {"memberId": seat["id"], "isOwner": group["ownerMemberId"] == seat["id"]},
            "members": [model.member_view(member, providers.get(member["id"])) for member in group["members"]],
            "expenses": group["expenses"],
            "settlements": group["settlements"],
            "attempts": [model.attempt_view(attempt, seat["id"]) for attempt in group["attempts"]],
            "balances": model.balances_view(group),
            "receipts": receipt_views if receipt_views is not None else self._receipt_views(self.ctx.store.get, group, seat),
            "events": events,
            "eventsComplete": complete,
        }

    def snapshot(self, principal: Principal | None, group_id: str) -> dict[str, Any]:
        caller = self._caller(principal)
        group_id = require_uuid(group_id, "groupId")

        def body_fn(
            transaction: Transaction,
        ) -> tuple[dict[str, Any], dict[str, Any], list[dict[str, Any]], list[dict[str, Any]]]:
            group = self._load(transaction, group_id)
            seat = self._seat(group, caller)
            receipt_views = self._receipt_views(transaction.get, group, seat)
            return group, seat, self._events_after(transaction, group, 0, MAX_SNAPSHOT_EVENTS), receipt_views

        group, seat, events, receipt_views = self.ctx.store.run_in_transaction(body_fn)
        return self._snapshot_view(group, seat, events, complete=len(events) == group["eventSequence"], receipt_views=receipt_views)

    def _changes_view(
        self, read: Reader, group: dict[str, Any], seat: dict[str, Any], after: int, events: list[dict[str, Any]]
    ) -> dict[str, Any]:
        expenses = {event["data"]["expenseId"] for event in events if "expenseId" in event["data"]}
        attempts = {event["data"]["attemptId"] for event in events if "attemptId" in event["data"]}
        settlements = {event["data"]["settlementId"] for event in events if "settlementId" in event["data"]}
        receipt_ids = {event["data"]["receiptId"] for event in events if "receiptId" in event["data"]}
        providers = self._providers(group)
        return {
            "schemaVersion": model.SCHEMA_VERSION,
            "serverTime": self.ctx.now_iso(),
            "revision": group["revision"],
            "after": after,
            "cursor": group["eventSequence"],
            "cursorExpired": False,
            "group": model.header_view(group),
            "viewer": {"memberId": seat["id"], "isOwner": group["ownerMemberId"] == seat["id"]},
            "members": [model.member_view(member, providers.get(member["id"])) for member in group["members"]],
            "expenses": [expense for expense in group["expenses"] if expense["id"] in expenses],
            "settlements": [settlement for settlement in group["settlements"] if settlement["id"] in settlements],
            "attempts": [model.attempt_view(attempt, seat["id"]) for attempt in group["attempts"] if attempt["id"] in attempts],
            "balances": model.balances_view(group),
            "receipts": self._receipt_views(read, group, seat, only=receipt_ids),
            "events": events,
        }

    def _changes_in(self, transaction: Transaction, group: dict[str, Any], seat: dict[str, Any], after: int) -> dict[str, Any]:
        behind = group["eventSequence"] - after
        if after < 0 or behind < 0 or behind > MAX_CHANGE_EVENTS:
            # Too far behind, or a cursor from a different history: never guess missing events.
            return {
                "schemaVersion": model.SCHEMA_VERSION,
                "serverTime": self.ctx.now_iso(),
                "revision": group["revision"],
                "after": after,
                "cursor": group["eventSequence"],
                "cursorExpired": True,
            }
        return self._changes_view(transaction.get, group, seat, after, self._events_after(transaction, group, after, MAX_CHANGE_EVENTS))

    def changes(self, principal: Principal | None, group_id: str, after: int) -> dict[str, Any]:
        caller = self._caller(principal)
        group_id = require_uuid(group_id, "groupId")

        def body_fn(transaction: Transaction) -> dict[str, Any]:
            group = self._load(transaction, group_id)
            return self._changes_in(transaction, group, self._seat(group, caller), after)

        result: dict[str, Any] = self.ctx.store.run_in_transaction(body_fn)
        return result

    def list_groups(self, principal: Principal | None) -> list[dict[str, Any]]:
        caller = self._caller(principal)
        summaries: list[dict[str, Any]] = []
        for _, record in self.ctx.store.query(GROUP_MEMBERSHIP, "uid", caller.subject, limit=200):
            if not record["active"]:
                continue
            group = self.ctx.store.get(SHARED_GROUP, record["groupId"])
            if group is None:
                continue
            seat = model.member_for_uid(group, caller.subject)
            if seat is None:
                continue
            plan = settlement_plan(
                model.member_ids(group), group["expenses"], group["settlements"], group["attempts"], bool(group["simplifiesDebts"])
            )
            awaiting = [
                attempt["id"]
                for attempt in group["attempts"]
                if attempt["recipientId"] == seat["id"] and attempt["state"] in ("reportedSent", "disputed")
            ]
            # Pending receipts this person is on, and those waiting for them: their review, or — for
            # the host — finishing it.
            mine = [entry for entry in group_receipts.open_receipts(group) if seat["id"] in entry["participantIds"]]
            needing = [entry for entry in mine if entry["hostMemberId"] == seat["id"] or seat["id"] in entry.get("unreviewed", [])]
            summaries.append(
                {
                    "group": model.header_view(group),
                    "viewer": {"memberId": seat["id"], "isOwner": group["ownerMemberId"] == seat["id"]},
                    "cursor": group["eventSequence"],
                    "memberCount": sum(1 for member in group["members"] if member["status"] != "removed"),
                    "confirmedNet": plan.confirmed_nets.get(seat["id"], 0),
                    "awaitingYourConfirmation": len(awaiting),
                    "openReceipts": len(mine),
                    "receiptsNeedingYou": len(needing),
                }
            )
        return sorted(summaries, key=lambda summary: summary["group"]["name"].lower())

    # MARK: - Creating a shared group

    def create(self, principal: Principal | None, body: object) -> tuple[dict[str, Any], bool]:
        caller = self._caller(principal)
        body = model.require_dict(body, "group")
        group_id = require_uuid(body.get("groupId"), "groupId")
        fields = model.parse_group_fields(body)
        simplifies = body.get("simplifiesDebts", True)
        if not isinstance(simplifies, bool):
            raise DomainError("invalid_payload", "simplifiesDebts must be true or false")
        now = self.ctx.now_iso()

        def body_fn(transaction: Transaction) -> tuple[dict[str, Any], dict[str, Any], bool]:
            existing = transaction.get(SHARED_GROUP, group_id)
            if existing is not None:
                if existing.get("createdByUid") != caller.subject or existing.get("publicationId"):
                    raise DomainError("entity_exists", "A group with this identifier already exists")
                return existing, self._seat(existing, caller), False  # creating again is idempotent
            profile = self.accounts.require_profile(transaction, caller.subject)
            seat = model.new_seat(profile["memberId"], profile["displayName"], now, uid=caller.subject)
            group = {
                "id": group_id,
                **fields,
                "simplifiesDebts": simplifies,
                "ownerMemberId": seat["id"],
                "createdAt": now,
                "createdByUid": caller.subject,
                "updatedAt": now,
                "archivedAt": None,
                "revision": 1,
                "eventSequence": 0,
                "publicationId": None,
                "members": [seat],
                "expenses": [],
                "settlements": [],
                "attempts": [],
                "adoptedRooms": [],
                "invitations": [],
            }
            if caller.demo:
                group["demo"] = True  # removed with its demo workspace (``services.demo``)
            event = self._new_event(group, seat["id"], now, "groupCreated", {"name": group["name"]})
            self._put_group(transaction, group)
            self._append_events(transaction, group_id, [event])
            self._put_membership(transaction, caller.subject, group_id, seat["id"], active=True)
            return group, seat, True

        group, seat, created = self.ctx.store.run_in_transaction(body_fn)
        if created:
            log_event("group.created", group=redact(group_id))
        return self._snapshot_view(group, seat, self._history(group), complete=True), created

    @staticmethod
    def _new_event(group: dict[str, Any], actor: str, now: str, kind: str, data: dict[str, Any], at: str | None = None) -> dict[str, Any]:
        group["eventSequence"] += 1
        return {
            "id": str(uuid.uuid4()),
            "sequence": group["eventSequence"],
            "actorMemberId": actor,
            "at": at or now,
            "kind": kind,
            "data": data,
        }

    def _history(self, group: dict[str, Any]) -> list[dict[str, Any]]:
        def body_fn(transaction: Transaction) -> list[dict[str, Any]]:
            return self._events_after(transaction, group, 0, MAX_SNAPSHOT_EVENTS)

        events: list[dict[str, Any]] = self.ctx.store.run_in_transaction(body_fn)
        return events

    # MARK: - Publishing a local group (milestone 7 §8)

    def publish(self, principal: Principal | None, body: object) -> tuple[dict[str, Any], bool]:
        """Imports one eligible local P2P group, atomically and exactly once.

        The whole snapshot is validated before anything is written. A retry with the same
        ``publicationId`` returns the original result; a different snapshot under the same ID is
        refused. The group keeps every local identifier (group, members, expenses, settlements).
        """
        caller = self._caller(principal)
        body = model.require_dict(body, "publication")
        publication_id = require_uuid(body.get("publicationId"), "publicationId")
        request_fingerprint = fingerprint(body)
        now = self.ctx.now_iso()
        record_key = f"{caller.subject}:{publication_id}"

        def body_fn(transaction: Transaction) -> tuple[dict[str, Any], dict[str, Any], bool]:
            previous = transaction.get(GROUP_PUBLICATION, record_key)
            if previous is not None:
                if previous["fingerprint"] != request_fingerprint:
                    raise DomainError("idempotency_key_reused", "This publication was already used for a different group")
                group = self._load(transaction, previous["groupId"])
                return group, self._seat(group, caller), False
            profile = self.accounts.require_profile(transaction, caller.subject)
            group, events = self._imported_group(body, caller, profile, publication_id, now)
            if caller.demo:
                group["demo"] = True  # removed with its demo workspace (``services.demo``)
            if transaction.get(SHARED_GROUP, group["id"]) is not None:
                raise DomainError("entity_exists", "This group was already shared, possibly from another device")
            self._put_group(transaction, group)
            self._append_events(transaction, group["id"], events)
            owner = model.find_member(group, group["ownerMemberId"])
            if owner is None:  # pragma: no cover - _imported_group guarantees the publisher's seat
                raise DomainError("publication_invalid", "You aren't a member of this group", {"reason": "publisherMissing"})
            self._put_membership(transaction, caller.subject, group["id"], owner["id"], active=True)
            transaction.put(GROUP_PUBLICATION, record_key, {"fingerprint": request_fingerprint, "groupId": group["id"], "createdAt": now})
            return group, owner, True

        group, seat, created = self.ctx.store.run_in_transaction(body_fn)
        if created:
            log_event("group.published", group=redact(group["id"]), expenses=len(group["expenses"]), members=len(group["members"]))
        return self._snapshot_view(group, seat, self._history(group), complete=True), created

    def _imported_group(
        self, body: dict[str, Any], caller: Principal, profile: dict[str, Any], publication_id: str, now: str
    ) -> tuple[dict[str, Any], list[dict[str, Any]]]:
        def invalid(message: str, reason: str) -> DomainError:
            return DomainError("publication_invalid", message, {"reason": reason})

        raw_group = model.require_dict(body.get("group"), "group")
        # Defence in depth: the app never sends legacy organization data (``LegacyRecords``); if a
        # modified client does, nothing is imported.
        if raw_group.get("kind") not in (None, "personal") or "budget" in raw_group or "eventBudget" in raw_group:
            raise invalid("Organization groups can't be shared", "legacyOrganization")
        group_id = require_uuid(raw_group.get("id"), "group.id")
        fields = model.parse_group_fields(raw_group)
        simplifies = raw_group.get("simplifiesDebts", True)
        if not isinstance(simplifies, bool):
            raise DomainError("invalid_payload", "simplifiesDebts must be true or false")
        created_at = model.require_iso_datetime(raw_group.get("createdAt"), "group.createdAt")
        publisher = require_uuid(body.get("publisherMemberId"), "publisherMemberId")

        members: list[dict[str, Any]] = []
        for raw_value in model.require_list(body.get("members"), "members", max_count=model.MAX_SEATS):
            raw = model.require_dict(raw_value, "members")
            member_id = require_uuid(raw.get("id"), "member.id")
            if any(member["id"] == member_id for member in members):
                raise invalid("Someone appears twice in this group", "duplicateMember")
            is_publisher = member_id == publisher
            seat = model.new_seat(
                member_id, raw.get("displayName"), now, uid=caller.subject if is_publisher else None, handle=raw.get("handle")
            )
            if raw.get("removed") is True:
                if is_publisher:
                    raise invalid("You aren't an active member of this group", "publisherRemoved")
                seat["status"] = "removed"
                seat["removedAt"] = now
            if is_publisher:
                seat["displayName"] = profile["displayName"]
            members.append(seat)
        if not any(member["id"] == publisher for member in members):
            raise invalid("You aren't a member of this group", "publisherMissing")
        all_members = [member["id"] for member in members]

        expenses: list[dict[str, Any]] = []
        for raw_value in model.require_list(body.get("expenses"), "expenses", max_count=model.MAX_EXPENSES):
            raw = model.require_dict(raw_value, "expenses")
            if any(key in raw for key in ("funding", "organizationFunding")):
                raise invalid("Organization-funded expenses can't be shared", "legacyOrganization")
            expense = model.parse_expense(raw, currency=fields["currency"])
            if any(stored["id"] == expense["id"] for stored in expenses):
                raise invalid("An expense appears twice", "duplicateExpense")
            created_by = require_uuid(raw.get("createdBy"), "createdBy")
            if created_by not in all_members:
                raise invalid("An expense was added by someone who isn't in the group", "unknownCreator")
            # History may name people who were later removed; that's how it stays explainable.
            validate_expense(expense, group_member_ids=all_members, participating_ids=all_members)
            deleted_at = raw.get("deletedAt")
            deleted_by = raw.get("deletedBy")
            updated_by = raw.get("updatedBy")
            expenses.append(
                {
                    **expense,
                    "createdBy": created_by,
                    "createdAt": model.require_iso_datetime(raw.get("createdAt"), "createdAt"),
                    "revision": require_int(raw.get("revision", 1), "revision", low=1, high=1_000_000),
                    "updatedAt": None if raw.get("updatedAt") is None else model.require_iso_datetime(raw.get("updatedAt"), "updatedAt"),
                    "updatedBy": None if updated_by is None else require_uuid(updated_by, "updatedBy"),
                    "deletedAt": None if deleted_at is None else model.require_iso_datetime(deleted_at, "deletedAt"),
                    "deletedBy": None if deleted_by is None else require_uuid(deleted_by, "deletedBy"),
                    # Receipt images and item details stay on the publishing device (disclosed there).
                    "receipt": None,
                    "receiptOmitted": expense["splitMethod"] == "itemized",
                    "roomId": None,
                }
            )

        settlements: list[dict[str, Any]] = []
        for raw_value in model.require_list(body.get("settlements", []), "settlements", max_count=model.MAX_ATTEMPTS):
            raw = model.require_dict(raw_value, "settlements")
            settlement_id = require_uuid(raw.get("id"), "settlement.id")
            from_id = require_uuid(raw.get("fromId"), "fromId")
            to_id = require_uuid(raw.get("toId"), "toId")
            if from_id not in all_members or to_id not in all_members or from_id == to_id:
                raise invalid("A payment refers to someone who isn't in the group", "invalidSettlement")
            if any(stored["id"] == settlement_id for stored in settlements):
                raise invalid("A payment appears twice", "duplicateSettlement")
            provider = raw.get("provider")
            if provider is not None and provider not in model.PROVIDERS:
                raise DomainError("invalid_payload", "Unknown payment method")
            settlements.append(
                {
                    "id": settlement_id,
                    "fromId": from_id,
                    "toId": to_id,
                    "amount": model.require_amount(raw.get("amount"), "amount", allow_zero=False),
                    "date": model.require_iso_datetime(raw.get("date"), "date"),
                    "recordedBy": require_uuid(raw.get("recordedBy"), "recordedBy"),
                    "provider": provider,
                    "attemptId": None,
                    "confirmedAt": None,
                    "confirmedBy": None,
                    "imported": True,
                }
            )
        if model.require_list(body.get("openPayments", []), "openPayments", max_count=0):
            raise invalid("Finish or cancel payments in progress before sharing", "openPayments")

        group: dict[str, Any] = {
            "id": group_id,
            **fields,
            "simplifiesDebts": simplifies,
            "ownerMemberId": publisher,
            "createdAt": created_at,
            "createdByUid": caller.subject,
            "updatedAt": now,
            "archivedAt": None,
            "revision": 1,
            "eventSequence": 0,
            "publicationId": publication_id,
            "members": members,
            "expenses": expenses,
            "settlements": settlements,
            "attempts": [],
            "adoptedRooms": [],
            "invitations": [],
        }
        known_entities = {expense["id"] for expense in expenses} | {settlement["id"] for settlement in settlements}
        events: list[dict[str, Any]] = []
        for raw_value in model.require_list(body.get("events", []), "events", max_count=MAX_IMPORTED_EVENTS):
            raw = model.require_dict(raw_value, "events")
            kind = raw.get("kind")
            actor = raw.get("actorMemberId")
            data = model.require_dict(raw.get("data", {}), "event.data")
            if kind not in EVENT_KINDS or actor not in all_members or len(json.dumps(data)) > 4_096:
                raise invalid("Part of this group's history couldn't be read", "invalidEvent")
            for key in ("expenseId", "settlementId"):
                if key in data and data[key] not in known_entities:
                    # Payment drafts and other device-only records aren't shared; drop their references.
                    data = {k: v for k, v in data.items() if k != key}
            data.pop("note", None)
            data.pop("reason", None)
            events.append(
                self._new_event(group, str(actor), now, str(kind), data, at=model.require_iso_datetime(raw.get("at"), "event.at"))
            )
        events.append(
            self._new_event(
                group, publisher, now, "groupPublished", {"name": group["name"], "expenses": len(expenses), "members": len(members)}
            )
        )
        if model.group_bytes(group) > model.MAX_GROUP_BYTES:
            raise invalid("This group is too large to share", "tooLarge")
        return group, events

    # MARK: - Commands

    def command(self, principal: Principal | None, group_id: str, raw: object) -> dict[str, Any]:
        caller = self._caller(principal)
        group_id = require_uuid(group_id, "groupId")
        envelope = CommandEnvelope.parse(raw)
        known_cursor = raw.get("knownCursor") if isinstance(raw, dict) else None
        if known_cursor is not None:
            known_cursor = require_int(known_cursor, "knownCursor", low=0, high=100_000_000)
        idempotency_name = token_hash(f"group|{group_id}|{caller.binding}|{envelope.idempotency_key}")
        request_fingerprint = envelope.fingerprint()
        now = self.ctx.now_iso()

        def body_fn(transaction: Transaction) -> dict[str, Any]:
            group = self._load(transaction, group_id)
            seat = self._seat(group, caller)
            previous = transaction.get(IDEMPOTENCY, idempotency_name)
            if previous is not None:
                if previous["fingerprint"] != request_fingerprint:
                    raise DomainError("idempotency_key_reused", "That request key was already used for a different change")
                return self._command_result(group, previous["commandId"], previous["applied"], True, previous["result"])
            if envelope.type in REVISION_STRICT and envelope.expected_revision != group["revision"]:
                raise DomainError(
                    "revision_conflict",
                    "The group changed. Review the latest and try again",
                    {"currentRevision": group["revision"], "cursor": group["eventSequence"]},
                )
            context = Context(
                group,
                seat,
                now,
                destination_provider=self._destination_lookup(transaction, group),
                load_room=lambda room_id: transaction.get(ROOM, room_id),
                actor_uid=caller.subject,
                load_receipt=lambda receipt_id: transaction.get(GROUP_RECEIPT, f"{group_id}:{receipt_id}"),
            )
            try:
                outcome = run(context, envelope.type, envelope.payload)
            except DomainError as error:
                # A refused receipt change comes back with the receipt as it is now, so the person
                # sees the latest claims instead of guessing (like a room's conflict snapshot).
                receipt_id = self._receipt_id(envelope)
                entry = next((e for e in group.get("receipts", []) if e["id"] == receipt_id), None)
                if entry is not None:
                    view = self._receipt_view(transaction.get, group, seat, entry)
                    if view["room"] is not None:
                        error.details["room"] = view["room"]
                raise
            if outcome.changed:
                group["revision"] += 1
                group["updatedAt"] = now
                self._after_command(transaction, group, envelope.type, outcome.result, now)
                self._put_group(transaction, group)
                self._append_events(transaction, group_id, outcome.events)
                for revision in outcome.revisions:
                    transaction.put(EXPENSE_REVISION, f"{group_id}:{revision['expenseId']}:{revision['revision']}", revision)
                for receipt_id, record in outcome.receipts.items():
                    transaction.put(GROUP_RECEIPT, f"{group_id}:{receipt_id}", record, indexed={"groupId": group_id})
            result = {key: value for key, value in outcome.result.items() if key != "removedUid"}
            transaction.put(
                IDEMPOTENCY,
                idempotency_name,
                {
                    "fingerprint": request_fingerprint,
                    "commandId": envelope.command_id,
                    "applied": outcome.changed,
                    "result": result,
                    "createdAt": now,
                },
                indexed={"createdAt": now},
            )
            return self._command_result(group, envelope.command_id, outcome.changed, False, result)

        response: dict[str, Any] = self.ctx.store.run_in_transaction(body_fn)
        if known_cursor is not None:
            # A fresh read of what's committed: everything since the client's cursor, including
            # this command's events (a transaction can't read its own writes).
            # The caller may just have left the group; the result alone is still authoritative.
            with contextlib.suppress(DomainError):
                response["changes"] = self.changes(caller, group_id, known_cursor)
        receipt_id = self._receipt_id(envelope)
        if receipt_id is not None:
            # The receipt as it is now (committed), for the screen that sent the change.
            with contextlib.suppress(DomainError):
                response["receipt"] = self.receipt(caller, group_id, receipt_id)
        log_event(
            "group.command",
            group=redact(group_id),
            type=envelope.type,
            applied=response["applied"],
            replayed=response["replayed"],
            revision=response["revision"],
        )
        return response

    @staticmethod
    def _receipt_id(envelope: CommandEnvelope) -> str | None:
        if envelope.type not in RECEIPT_COMMAND_TYPES:
            return None
        value = envelope.payload.get("receiptId")
        try:
            return require_uuid(value, "receiptId")
        except DomainError:
            return None

    def receipt(self, principal: Principal | None, group_id: str, receipt_id: str) -> dict[str, Any]:
        """One group receipt as the caller may see it (participants: the whole receipt)."""
        caller = self._caller(principal)
        group_id = require_uuid(group_id, "groupId")
        receipt_id = require_uuid(receipt_id, "receiptId")

        def body_fn(transaction: Transaction) -> dict[str, Any]:
            group = self._load(transaction, group_id)
            seat = self._seat(group, caller)
            entry = next((e for e in group.get("receipts", []) if e["id"] == receipt_id), None)
            if entry is None:
                raise DomainError("receipt_not_found", "That receipt isn't in this group")
            return self._receipt_view(transaction.get, group, seat, entry)

        view: dict[str, Any] = self.ctx.store.run_in_transaction(body_fn)
        return view

    @staticmethod
    def _command_result(group: dict[str, Any], command_id: str, applied: bool, replayed: bool, result: dict[str, Any]) -> dict[str, Any]:
        return {
            "commandId": command_id,
            "applied": applied,
            "replayed": replayed,
            "revision": group["revision"],
            "cursor": group["eventSequence"],
            "result": result,
        }

    def _after_command(self, transaction: Transaction, group: dict[str, Any], command_type: str, result: dict[str, Any], now: str) -> None:
        """Side records a command implies: memberships of removed people and invitation revocation."""
        removed_uid = result.get("removedUid")
        if removed_uid:
            member = next(m for m in group["members"] if m.get("uid") == removed_uid)
            self._put_membership(transaction, removed_uid, group["id"], member["id"], active=False)
        if command_type in ("archiveGroup", "transferOwnership", "removeMember", "leaveGroup"):
            # Invitations stop working when the group is archived or their creator can no longer invite.
            owner = group["ownerMemberId"]
            for invitation in group["invitations"]:
                if invitation.get("revokedAt"):
                    continue
                if command_type == "archiveGroup" or invitation["createdByMemberId"] != owner:
                    self._revoke_invitation_record(transaction, group, invitation, now)

    def _destination_lookup(self, transaction: Transaction, group: dict[str, Any]) -> Callable[[str, str], str | None]:
        def lookup(member_id: str, destination_id: str) -> str | None:
            member = model.find_member(group, member_id)
            if member is None or not member.get("uid"):
                return None
            profile = transaction.get(ACCOUNT, member["uid"])
            destination = next((d for d in (profile or {}).get("destinations", []) if d["id"] == destination_id and d["isEnabled"]), None)
            return None if destination is None else str(destination["provider"])

        return lookup

    # MARK: - Payment destinations (milestone 7 §10.1)

    def reveal_destinations(self, principal: Principal | None, group_id: str, member_id: str) -> dict[str, Any]:
        """A member's full payment destinations — only for someone who currently owes them in the
        group's plan, or who has a payment in progress to them. Everyone else sees method names."""
        caller = self._caller(principal)
        group_id = require_uuid(group_id, "groupId")
        member_id = require_uuid(member_id, "memberId")

        def body_fn(transaction: Transaction) -> dict[str, Any]:
            group = self._load(transaction, group_id)
            seat = self._seat(group, caller)
            recipient = model.find_member(group, member_id)
            if recipient is None or recipient["status"] != "active" or not recipient.get("uid"):
                raise DomainError("reveal_not_allowed", "Their payment details aren't available")
            plan = settlement_plan(
                model.member_ids(group), group["expenses"], group["settlements"], group["attempts"], bool(group["simplifiesDebts"])
            )
            owes = plan.payment(seat["id"], member_id) is not None
            in_progress = any(
                a["payerId"] == seat["id"] and a["recipientId"] == member_id and a["state"] not in ("confirmed", "rejected", "cancelled")
                for a in group["attempts"]
            )
            if member_id != seat["id"] and not (owes or in_progress):
                raise DomainError("reveal_not_allowed", "Their payment details are shown only while you owe them")
            profile = transaction.get(ACCOUNT, recipient["uid"]) or {"destinations": []}
            return {"memberId": member_id, "destinations": [d for d in profile["destinations"] if d["isEnabled"]]}

        result: dict[str, Any] = self.ctx.store.run_in_transaction(body_fn)
        log_event("group.destinationsRevealed", group=redact(group_id))
        return result

    def destination_summaries(self, profile: dict[str, Any]) -> list[dict[str, Any]]:
        return [destination_summary(d) for d in profile["destinations"] if d["isEnabled"]]

    # MARK: - Expense history

    def revisions(self, principal: Principal | None, group_id: str, expense_id: str) -> list[dict[str, Any]]:
        caller = self._caller(principal)
        group_id = require_uuid(group_id, "groupId")
        expense_id = require_uuid(expense_id, "expenseId")

        def body_fn(transaction: Transaction) -> list[dict[str, Any]]:
            group = self._load(transaction, group_id)
            self._seat(group, caller)
            expense = next((e for e in group["expenses"] if e["id"] == expense_id), None)
            if expense is None:
                raise DomainError("expense_not_found", "That expense isn't in this group")
            records = [transaction.get(EXPENSE_REVISION, f"{group_id}:{expense_id}:{n}") for n in range(1, expense["revision"] + 1)]
            return [record for record in records if record is not None]

        revisions: list[dict[str, Any]] = self.ctx.store.run_in_transaction(body_fn)
        return revisions

    # MARK: - Invitations (milestone 7 §4)

    def _invitation_status(self, invitation: dict[str, Any]) -> str:
        """``unused`` | ``accepted`` | ``expired`` | ``revoked`` (one state; acceptance wins)."""
        if invitation.get("acceptedAt"):
            return "accepted"
        if invitation.get("revokedAt"):
            return "revoked"
        if parse_iso(invitation["expiresAt"]) <= self.ctx.now():
            return "expired"
        return "unused"

    def _invitation_view(self, invitation: dict[str, Any]) -> dict[str, Any]:
        """What the owner sees about one invitation. Never the code, its hash, or any account ID."""
        return {
            "invitationId": invitation["id"],
            "status": self._invitation_status(invitation),
            "seatMemberId": invitation.get("seatMemberId"),
            "createdByMemberId": invitation.get("createdByMemberId"),
            "acceptedMemberId": invitation.get("acceptedMemberId"),
            "createdAt": invitation["createdAt"],
            "expiresAt": invitation["expiresAt"],
            "acceptedAt": invitation.get("acceptedAt"),
            "revokedAt": invitation.get("revokedAt"),
        }

    def create_invitation(self, principal: Principal | None, group_id: str, body: object) -> dict[str, Any]:
        self.accounts.refuse_demo(principal, "Inviting people with a link")
        caller = self._caller(principal)
        group_id = require_uuid(group_id, "groupId")
        body = body if isinstance(body, dict) else {}
        seat_id = body.get("seatMemberId")
        if seat_id is not None:
            seat_id = require_uuid(seat_id, "seatMemberId")
        hours = require_int(body.get("expiresInHours", self.ctx.config.group_invitation_ttl_hours), "expiresInHours", low=1, high=24 * 30)
        now = self.ctx.now_iso()
        code = new_invitation_code()
        code_hash = token_hash(code)

        def body_fn(transaction: Transaction) -> dict[str, Any]:
            group = self._load(transaction, group_id)
            seat = self._seat(group, caller)
            if group.get("archivedAt"):
                raise DomainError("group_archived", "This group was archived")
            if group["ownerMemberId"] != seat["id"]:
                raise DomainError("owner_only", "Only the group's owner can invite people")
            if seat_id is not None:
                target = model.find_member(group, seat_id)
                if target is None or target["status"] != "pending":
                    raise DomainError("seat_unavailable", "That person has already joined or isn't in this group")
                # One working invitation per seat: a new one replaces the old.
                for previous in group["invitations"]:
                    if previous.get("seatMemberId") == seat_id and not previous.get("revokedAt") and not previous.get("acceptedAt"):
                        self._revoke_invitation_record(transaction, group, previous, now)
            elif model.active_count(group) >= model.MAX_ACTIVE_MEMBERS:
                raise DomainError("group_full", "This group has reached its limit of 25 people", {"limit": model.MAX_ACTIVE_MEMBERS})
            invitation = {
                "id": str(uuid.uuid4()),
                "hash": code_hash,
                "groupId": group_id,
                "createdByMemberId": seat["id"],
                "createdByUid": caller.subject,
                "seatMemberId": seat_id,
                "createdAt": now,
                "expiresAt": self.ctx.expires_in(hours),
                "acceptedAt": None,
                "acceptedByUid": None,
                "revokedAt": None,
            }
            transaction.put(GROUP_INVITATION, code_hash, invitation, indexed={"groupId": group_id, "expiresAt": invitation["expiresAt"]})
            # The timeline shows that someone was invited (never the code).
            event = self._new_event(group, seat["id"], now, "memberInvited", {"seatMemberId": seat_id})
            group["revision"] += 1
            group["updatedAt"] = now
            self._append_events(transaction, group_id, [event])
            group["invitations"] = [i for i in group["invitations"] if not self._invitation_finished(i, now)] + [
                {
                    "id": invitation["id"],
                    "hash": code_hash,
                    "createdByMemberId": seat["id"],
                    "seatMemberId": seat_id,
                    "expiresAt": invitation["expiresAt"],
                }
            ]
            self._put_group(transaction, group)
            return invitation

        invitation = self.ctx.store.run_in_transaction(body_fn)
        log_event("group.invitationCreated", group=redact(group_id), seat=seat_id is not None)
        base = self.ctx.config.public_base_url
        return {
            **self._invitation_view(invitation),
            # Returned once: only the hash is stored.
            "code": display_code(code),
            "url": f"{base}/g/{code}",
            "appUrl": f"squp://join-group/{code}",
        }

    def _invitation_finished(self, summary: dict[str, Any], now: str) -> bool:
        return bool(summary.get("revokedAt") or summary.get("acceptedAt")) or summary["expiresAt"] <= now

    def _revoke_invitation_record(
        self, transaction: Transaction, group: dict[str, Any], summary: dict[str, Any], now: str
    ) -> dict[str, Any] | None:
        """Revokes one invitation. Returns the updated record (a transaction can't read its own writes)."""
        record = transaction.get(GROUP_INVITATION, summary["hash"])
        if record is not None and record.get("acceptedAt"):
            return record  # already used: nothing to turn off
        if record is not None and not record.get("revokedAt"):
            record["revokedAt"] = now
            transaction.put(GROUP_INVITATION, summary["hash"], record, indexed={"groupId": group["id"], "expiresAt": record["expiresAt"]})
        summary["revokedAt"] = now
        return record

    def list_invitations(self, principal: Principal | None, group_id: str) -> list[dict[str, Any]]:
        caller = self._caller(principal)
        group_id = require_uuid(group_id, "groupId")
        group = self.ctx.store.get(SHARED_GROUP, group_id)
        if group is None:
            raise DomainError("group_not_found", "This group isn't available")
        seat = self._seat(group, caller)
        if group["ownerMemberId"] != seat["id"]:
            raise DomainError("owner_only", "Only the group's owner can see invitations")
        records = [record for _, record in self.ctx.store.query(GROUP_INVITATION, "groupId", group_id, limit=200)]
        return [self._invitation_view(record) for record in sorted(records, key=lambda r: r["createdAt"])]

    def revoke_invitation(self, principal: Principal | None, group_id: str, invitation_id: str) -> dict[str, Any]:
        caller = self._caller(principal)
        group_id = require_uuid(group_id, "groupId")
        invitation_id = require_uuid(invitation_id, "invitationId")
        now = self.ctx.now_iso()

        def body_fn(transaction: Transaction) -> dict[str, Any]:
            group = self._load(transaction, group_id)
            seat = self._seat(group, caller)
            if group["ownerMemberId"] != seat["id"]:
                raise DomainError("owner_only", "Only the group's owner can revoke invitations")
            summary = next((i for i in group["invitations"] if i["id"] == invitation_id), None)
            if summary is None:
                raise DomainError("not_found", "That invitation isn't available")
            if summary.get("acceptedAt"):
                raise DomainError("invitation_used", "This invitation was already used")
            record = self._revoke_invitation_record(transaction, group, summary, now)
            self._put_group(transaction, group)
            if record is None:
                raise DomainError("not_found", "That invitation isn't available")
            return record

        record = self.ctx.store.run_in_transaction(body_fn)
        log_event("group.invitationRevoked", group=redact(group_id))
        return self._invitation_view(record)

    def _invitation(self, code: str) -> tuple[str, dict[str, Any]]:
        normalized = normalize_code(code)
        if normalized is None:
            raise DomainError("invitation_invalid", "This invitation isn't valid")
        code_hash = token_hash(normalized)
        record = self.ctx.store.get(GROUP_INVITATION, code_hash)
        if record is None:
            raise DomainError("invitation_invalid", "This invitation isn't valid")
        return code_hash, record

    def _check_invitation(self, record: dict[str, Any], uid: str | None) -> None:
        if record.get("revokedAt"):
            raise DomainError("invitation_revoked", "This invitation was turned off. Ask for a new one")
        if record.get("acceptedAt") and record.get("acceptedByUid") != uid:
            raise DomainError("invitation_used", "This invitation was already used. Ask for a new one")
        if not record.get("acceptedAt") and parse_iso(record["expiresAt"]) <= self.ctx.now():
            raise DomainError("invitation_expired", "This invitation expired. Ask for a new one")

    def preview_invitation(self, code: str, principal: Principal | None) -> dict[str, Any]:
        """A safe preview: group name, symbol, inviter's and owner's names, member count, currency, and
        expiry only — no ledger, balances, emails, or payment methods before joining."""
        _, record = self._invitation(code)
        uid = principal.subject if principal is not None and principal.kind == "user" else None
        self._check_invitation(record, uid)
        group = self.ctx.store.get(SHARED_GROUP, record["groupId"])
        if group is None or group.get("demo"):
            raise DomainError("invitation_invalid", "This invitation isn't valid")
        if group.get("archivedAt"):
            raise DomainError("group_archived", "This group was archived")
        inviter = model.find_member(group, record["createdByMemberId"])
        owner = model.find_member(group, group["ownerMemberId"])
        return {
            "groupName": group["name"],
            "symbol": group["symbol"],
            "currency": group["currency"],
            "inviterName": inviter["displayName"] if inviter else "",
            "ownerName": owner["displayName"] if owner else "",
            "memberCount": model.active_count(group),
            "expiresAt": record["expiresAt"],
            "isSeatInvitation": record.get("seatMemberId") is not None,
            "alreadyMember": uid is not None and model.member_for_uid(group, uid) is not None,
        }

    def accept_invitation(self, code: str, principal: Principal | None, body: object) -> tuple[dict[str, Any], bool]:
        """Joins with this account, exactly once. A seat invitation binds the account to that seat
        (its history and identifier stay); otherwise a new seat is created."""
        self.accounts.refuse_demo(principal, "Joining a group with an invitation")
        caller = self._caller(principal)
        code_hash, record = self._invitation(code)
        body = body if isinstance(body, dict) else {}
        display_name = body.get("displayName")
        now = self.ctx.now_iso()

        def body_fn(transaction: Transaction) -> tuple[dict[str, Any], dict[str, Any], bool]:
            invitation = transaction.get(GROUP_INVITATION, code_hash)
            if invitation is None:
                raise DomainError("invitation_invalid", "This invitation isn't valid")
            group = self._load(transaction, invitation["groupId"])
            if group.get("demo"):
                raise DomainError("invitation_invalid", "This invitation isn't valid")
            existing = model.member_for_uid(group, caller.subject)
            if existing is not None:
                if invitation.get("acceptedByUid") == caller.subject:
                    return group, existing, False  # accepting again is idempotent
                raise DomainError("already_member", "You're already in this group")
            self._check_invitation(invitation, caller.subject)
            if group.get("archivedAt"):
                raise DomainError("group_archived", "This group was archived")
            profile = self.accounts.require_profile(transaction, caller.subject)
            name = require_text(
                display_name if display_name is not None else profile["displayName"], "displayName", max_length=model.MAX_MEMBER_NAME
            )
            self._require_room(group)
            seat_id = invitation.get("seatMemberId")
            if seat_id is not None:
                seat = model.find_member(group, seat_id)
                if seat is None or seat["status"] != "pending" or seat.get("uid"):
                    raise DomainError("seat_unavailable", "That place in the group is no longer available")
                seat.update({"uid": caller.subject, "status": "active", "joinedAt": now, "displayName": name})
            else:
                seat = self._new_member(group, caller.subject, profile, name, now)
            invitation.update({"acceptedAt": now, "acceptedByUid": caller.subject, "acceptedMemberId": seat["id"]})
            transaction.put(GROUP_INVITATION, code_hash, invitation, indexed={"groupId": group["id"], "expiresAt": invitation["expiresAt"]})
            for summary in group["invitations"]:
                if summary["hash"] == code_hash:
                    summary["acceptedAt"] = now
            self._record_join(transaction, group, seat, caller.subject, now)
            return group, seat, True

        group, seat, joined = self.ctx.store.run_in_transaction(body_fn)
        if joined:
            log_event("group.joined", group=redact(group["id"]), seat=record.get("seatMemberId") is not None)
        return self._snapshot_view(group, seat, self._history(group), complete=True), joined

    # MARK: - Joining (shared by every kind of invitation)

    @staticmethod
    def _require_room(group: dict[str, Any]) -> None:
        if model.active_count(group) >= model.MAX_ACTIVE_MEMBERS:
            raise DomainError("group_full", "This group has reached its limit of 25 people", {"limit": model.MAX_ACTIVE_MEMBERS})

    @staticmethod
    def _new_member(group: dict[str, Any], uid: str, profile: dict[str, Any], name: str, now: str) -> dict[str, Any]:
        """A new seat for this account (its profile's member ID unless the group already uses it)."""
        if len(group["members"]) >= model.MAX_SEATS:
            raise DomainError("group_full", "This group has reached its member limit")
        member_id = profile["memberId"]
        if model.find_member(group, member_id) is not None:
            member_id = str(uuid.uuid4())
        seat = model.new_seat(member_id, name, now, uid=uid)
        group["members"].append(seat)
        return seat

    def _record_join(self, transaction: Transaction, group: dict[str, Any], seat: dict[str, Any], uid: str, now: str) -> None:
        """Writes a join: the group (a new revision), its ``memberJoined`` event, and the membership."""
        event = self._new_event(group, seat["id"], now, "memberJoined", {"memberId": seat["id"]})
        group["revision"] += 1
        group["updatedAt"] = now
        self._put_group(transaction, group)
        self._append_events(transaction, group["id"], [event])
        self._put_membership(transaction, uid, group["id"], seat["id"], active=True)
