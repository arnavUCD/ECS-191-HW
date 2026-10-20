"""Deleting an account (Profile → Delete account).

The product rules (decided with the product owner, October 2026):

- The person settles first. Deletion is refused while they have a balance, a payment in progress,
  or a receipt still being split in any shared group (exactly the rule for leaving one), or own a
  group someone else has joined (they hand it over first). Someone who's owed money can settle it
  themselves with "Mark as settled" (``recordSettlement``). Other members' ledgers never change.
- A group nobody else joined (only the person, plus names they added) is deleted with the account.
- Every other group the person leaves (``leaveGroup``, recorded as ``memberLeft``). Afterwards, in
  every group and room they were ever in, they appear as "Former member": their name is removed and
  the others' history, expenses, payments, and balances stay exactly as they were.
- Live rooms. Refused while a room they host is still open or waiting for a payment, and while
  they're in someone else's room that's still being split or where they still owe. Ended rooms they
  hosted are deleted with their invitations, codes, guest access, and receipt images. Their place
  in someone else's room stays in its summary (as "Former member") until the room's normal deletion.
- Then their AI results, "Find a person" entries, invitations sent to them, their own group records,
  and last their profile with its payment methods.

How it stays safe:

- Every record is found with paginated queries (no silent limits). Rooms are found through indexes
  every room already has, old ones included: active rooms are those in a state before finalization
  plus temporary rooms that haven't closed (``expiresAt``). Nothing depends on a backfill.
- Each group is read again when it's acted on. A group that was private at the check but that
  someone has joined since is never deleted: the same transaction that removes the group's record
  checks that nobody else is in it, so a join and the removal can't both commit. Once the record is
  gone nobody can open or join the group; a ``GROUP_REMOVAL`` job then deletes the rest of it (the
  next attempt, or the hourly cleanup, finishes a job that stopped part-way).
- Nothing is reported as deleted until every step succeeded and a final check finds nothing left.
  The profile goes last, so an attempt that stopped part-way (offline, a conflict) is found and
  finished by the next one, which repeats harmlessly.
- It needs a sign-in from the last few minutes (Firebase's ``auth_time``). The app deletes the
  Firebase sign-in only after this succeeds.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass, field
from datetime import timedelta
from typing import Any

from ..auth.identity import Principal
from ..domain.errors import DomainError
from ..domain.room import ROOM_STATES, TERMINAL_STATES, Room
from ..domain.wire import room_from_storage
from ..ledger import group as model
from ..ledger.commands import leave_blocker
from ..logging_setup import log_event, redact
from ..storage.base import (
    ACCOUNT,
    ACCOUNT_DIRECTORY,
    DIRECT_INVITATION,
    EXPENSE_REVISION,
    GROUP_EVENT_PAGE,
    GROUP_INVITATION,
    GROUP_MEMBERSHIP,
    GROUP_PUBLICATION,
    GROUP_RECEIPT,
    GROUP_REMOVAL,
    ROOM,
    SHARED_GROUP,
    Store,
    Transaction,
)
from .context import ServiceContext, iso
from .groups import EVENT_PAGE_SIZE, FORMER_MEMBER, GroupService
from .intelligence import IntelligenceService
from .rooms import RoomService

#: Firebase's own limit for deleting a sign-in: the person signed in again within the last 5 minutes.
RECENT_SIGN_IN = timedelta(minutes=5)
#: A removal job older than this was left behind (the deletion that started it stopped).
ABANDONED_REMOVAL = timedelta(minutes=10)

_DELETE_BATCH = 20
_ATTEMPTS = 3
#: Rooms in these states are still being split (claiming or reviewing).
_SPLITTING_STATES = tuple(state for state in ROOM_STATES if state not in TERMINAL_STATES)
#: Later than any deadline: every temporary room that hasn't closed has an ``expiresAt`` before it.
_FAR_FUTURE = "9999-12-31T00:00:00Z"

#: What stops a member leaving a group (``leaveGroup``), as the app explains it.
_GROUP_BLOCKERS = {
    "member_has_balance": "groupBalance",
    "member_has_open_payment": "groupPayment",
    "member_has_open_receipt": "groupReceipt",
}


@dataclass
class _Plan:
    blockers: list[dict[str, Any]] = field(default_factory=list)
    leave: list[dict[str, Any]] = field(default_factory=list)
    archived: list[dict[str, Any]] = field(default_factory=list)
    delete_groups: list[dict[str, Any]] = field(default_factory=list)
    delete_rooms: list[str] = field(default_factory=list)

    @property
    def has_work(self) -> bool:
        return bool(self.leave or self.delete_groups or self.delete_rooms)


class AccountDeletionService:
    def __init__(self, ctx: ServiceContext, groups: GroupService, rooms: RoomService, intelligence: IntelligenceService) -> None:
        self.ctx = ctx
        self.groups = groups
        self.rooms = rooms
        self.intelligence = intelligence
        self.removals = GroupRemovals(ctx)

    @staticmethod
    def _caller(principal: Principal | None) -> Principal:
        if principal is None or principal.kind != "user":
            raise DomainError("unauthenticated", "Sign in to delete your account")
        if principal.demo:
            raise DomainError("demo_restricted", "The demo has no account to delete. Leave the demo instead")
        return principal

    # MARK: - Checking

    def check(self, principal: Principal | None) -> dict[str, Any]:
        """What deleting would do now, and anything that has to happen first."""
        caller = self._caller(principal)
        plan = self._plan(caller.subject)
        return {
            "blockers": plan.blockers,
            "groupsDeleted": [_summary(group) for group in plan.delete_groups],
            "groupsLeft": [_summary(group) for group in plan.leave + plan.archived],
            "roomsDeleted": len(plan.delete_rooms),
        }

    def _plan(self, uid: str) -> _Plan:
        plan = _Plan()
        for _, membership in self.ctx.store.query_all(GROUP_MEMBERSHIP, "uid", uid):
            if not membership.get("active"):
                continue
            group = self.ctx.store.get(SHARED_GROUP, membership["groupId"])
            seat = model.member_for_uid(group, uid) if group is not None else None
            if group is None or seat is None:
                continue
            decision = _decide(group, seat, uid)
            if isinstance(decision, dict):
                plan.blockers.append(decision)
            elif decision == "delete":
                plan.delete_groups.append(group)
            elif decision == "keep":
                plan.archived.append(group)
            else:
                plan.leave.append(group)
        for room_id, record in self.ctx.store.query_all(ROOM, "hostUid", uid):
            room = room_from_storage(record)
            if self.rooms.has_ended(room):
                plan.delete_rooms.append(room_id)
            else:
                plan.blockers.append({"kind": "roomHosted", "roomId": room_id, "name": room.receipt.merchant})
        binding = f"user:{uid}"
        for room_id, room in self._active_rooms():
            you = next((p for p in room.participants if p.bound_subject == binding and p.is_active), None)
            if room.host_uid == uid or you is None:
                continue
            if room.state in _SPLITTING_STATES:
                plan.blockers.append({"kind": "roomJoined", "roomId": room_id, "name": room.receipt.merchant})
            elif any(payment["participantId"] == you.id and payment["state"] != "confirmed" for payment in room.payments):
                plan.blockers.append({"kind": "roomOwed", "roomId": room_id, "name": room.receipt.merchant})
        return plan

    def _rooms_with_account(self, uid: str) -> list[str]:
        """Every room this account took part in without hosting, ended or not: rooms that finished
        (``finishedAt``), are being split (``state``), or haven't closed (``expiresAt``). These indexes
        are on every room, old ones included."""
        found: dict[str, Room] = {}
        for room_id, record in self.ctx.store.query_all(ROOM, "finishedAt", _FAR_FUTURE, before=True):
            found[room_id] = room_from_storage(record)
        for state in _SPLITTING_STATES:
            for room_id, record in self.ctx.store.query_all(ROOM, "state", state):
                found.setdefault(room_id, room_from_storage(record))
        for room_id, record in self.ctx.store.query_all(ROOM, "expiresAt", _FAR_FUTURE, before=True):
            found.setdefault(room_id, room_from_storage(record))
        binding = f"user:{uid}"
        return sorted(
            room_id
            for room_id, room in found.items()
            if room.host_uid != uid and any(p.bound_subject == binding for p in room.participants)
        )

    def _anonymize(self, uid: str) -> int:
        """ "Former member" in every group (memberships active or not) and room the account was in."""
        changed = 0
        group_ids = sorted({membership["groupId"] for _, membership in self.ctx.store.query_all(GROUP_MEMBERSHIP, "uid", uid)})
        for group_id in group_ids:
            changed += self.groups.anonymize_former_member(group_id, uid)
        for room_id in self._rooms_with_account(uid):
            changed += self.rooms.anonymize_participant(room_id, f"user:{uid}", FORMER_MEMBER)
        return changed

    def _active_rooms(self) -> list[tuple[str, Room]]:
        """Every room that hasn't ended: still being split (any kind), or a temporary room that's
        still collecting payments. Both come from indexes every room has had from the start."""
        found: dict[str, Room] = {}
        for state in _SPLITTING_STATES:
            for room_id, record in self.ctx.store.query_all(ROOM, "state", state):
                found[room_id] = room_from_storage(record)
        for room_id, record in self.ctx.store.query_all(ROOM, "expiresAt", _FAR_FUTURE, before=True):
            found.setdefault(room_id, room_from_storage(record))
        return [(room_id, room) for room_id, room in found.items() if not self.rooms.has_ended(room)]

    # MARK: - Deleting

    def delete(self, principal: Principal | None) -> dict[str, Any]:
        caller = self._caller(principal)
        self._require_recent_sign_in(caller)
        uid = caller.subject
        left = deleted_groups = deleted_rooms = 0
        # Act, then check again: whatever changed meanwhile (a group someone joined, a room started on
        # another iPhone) is handled or refused before anything is reported as deleted.
        for _ in range(_ATTEMPTS):
            plan = self._plan(uid)
            if plan.blockers:
                raise DomainError(
                    "account_has_obligations", "Settle up, hand over your groups, and finish live rooms first", {"blockers": plan.blockers}
                )
            if not plan.has_work:
                break
            for group in plan.leave:
                left += self._leave(caller, group["id"])
            for group in plan.delete_groups:
                deleted_groups += self._remove_private_group(uid, group["id"])
            for room_id in plan.delete_rooms:
                self.rooms.delete_room(room_id)
                deleted_rooms += 1
        else:
            raise DomainError("revision_conflict", "Your groups changed while your account was being deleted. Try again")
        self.removals.finish_pending(requested_by=uid)
        anonymized = self._anonymize(uid)
        ai_results = self.intelligence.delete_cache(caller)
        self._delete_account_records(uid)
        log_event(
            "account.deleted",
            account=redact(uid),
            groupsLeft=left,
            groupsDeleted=deleted_groups,
            roomsDeleted=deleted_rooms,
            anonymized=anonymized,
            aiResults=ai_results,
        )
        return {"deleted": True}

    def _require_recent_sign_in(self, caller: Principal) -> None:
        if self.ctx.config.allow_dev_auth and caller.subject.startswith("dev-"):
            return  # local development and automated tests (``Dev <uid>``)
        signed_in = caller.auth_time
        if signed_in is None or self.ctx.now().timestamp() - signed_in > RECENT_SIGN_IN.total_seconds():
            raise DomainError("recent_sign_in_required", "Sign in again to delete your account")

    def _leave(self, caller: Principal, group_id: str) -> int:
        """``leaveGroup`` through the normal command path, against the group as it is now. A group
        that changed since the check is decided again: refused if it now has something open or the
        person became its owner, deleted if everyone else has left."""
        for _ in range(_ATTEMPTS):
            group = self.ctx.store.get(SHARED_GROUP, group_id)
            seat = model.member_for_uid(group, caller.subject) if group is not None else None
            if group is None or seat is None:
                return 0
            decision = _decide(group, seat, caller.subject)
            if decision == "delete":
                return self._remove_private_group(caller.subject, group_id)
            if decision == "keep":
                return 0
            if isinstance(decision, dict):
                raise DomainError("account_has_obligations", "Something changed in one of your groups", {"blockers": [decision]})
            body = {
                "commandId": str(uuid.uuid4()),
                "idempotencyKey": f"delete-account-{uuid.uuid4().hex}",
                "expectedRevision": group["revision"],
                "type": "leaveGroup",
                "payload": {},
            }
            try:
                self.groups.command(caller, group_id, body)
                return 1
            except DomainError as error:
                if error.code != "revision_conflict":
                    raise
        raise DomainError("revision_conflict", "A group changed while your account was being deleted. Try again")

    def _remove_private_group(self, uid: str, group_id: str) -> int:
        """Removes the group's record — only if nobody else is in it, checked in the same transaction —
        then deletes everything else stored about it."""
        now = self.ctx.now_iso()

        def body_fn(transaction: Transaction) -> str:
            group = transaction.get(SHARED_GROUP, group_id)
            if group is None:
                return "gone"
            if model.member_for_uid(group, uid) is None:
                return "notMember"
            if not _is_private(group, uid):
                return "shared"
            transaction.delete(SHARED_GROUP, group_id)
            transaction.put(GROUP_REMOVAL, group_id, _removal_job(group, uid, now), indexed={"requestedBy": uid, "createdAt": now})
            return "removed"

        outcome = self.ctx.store.run_in_transaction(body_fn)
        if outcome == "shared":
            # Someone joined after the check: it's a shared group now, so it isn't deleted.
            group = self.ctx.store.get(SHARED_GROUP, group_id) or {"id": group_id, "name": ""}
            raise DomainError(
                "account_has_obligations", "Someone joined one of your groups", {"blockers": [{"kind": "groupOwner", **_summary(group)}]}
            )
        self.removals.finish(group_id)
        return 1 if outcome == "removed" else 0

    def _delete_account_records(self, uid: str) -> None:
        """The person's own records: invitations sent to them, their group index, publications of
        groups they shared from their iPhone, "Find a person" entries, and the profile (last, so an
        attempt that stopped earlier still finds the rest next time)."""
        store = self.ctx.store
        keys = [(DIRECT_INVITATION, key) for key, _ in store.query_all(DIRECT_INVITATION, "recipientUid", uid)]
        for key, membership in store.query_all(GROUP_MEMBERSHIP, "uid", uid):
            group = store.get(SHARED_GROUP, membership["groupId"])
            if group is not None and group.get("createdByUid") == uid and group.get("publicationId"):
                keys.append((GROUP_PUBLICATION, f"{uid}:{group['publicationId']}"))
            keys.append((GROUP_MEMBERSHIP, key))
        profile = store.get(ACCOUNT, uid) or {}
        for directory_key in profile.get("directory", {}).values():
            entry = store.get(ACCOUNT_DIRECTORY, directory_key)
            if entry is not None and entry.get("uid") == uid:
                keys.append((ACCOUNT_DIRECTORY, directory_key))
        delete_all(store, keys)
        delete_all(store, [(ACCOUNT, uid)])


class GroupRemovals:
    """Deletes what's left of groups whose record is already gone (``GROUP_REMOVAL`` jobs)."""

    def __init__(self, ctx: ServiceContext) -> None:
        self.ctx = ctx

    def finish(self, group_id: str) -> None:
        job = self.ctx.store.get(GROUP_REMOVAL, group_id)
        if job is None:
            return
        keys = [(kind, key) for kind, key in job["keys"]]
        keys += [
            (kind, key) for kind in (GROUP_INVITATION, DIRECT_INVITATION) for key, _ in self.ctx.store.query_all(kind, "groupId", group_id)
        ]
        delete_all(self.ctx.store, keys)
        delete_all(self.ctx.store, [(GROUP_REMOVAL, group_id)])

    def finish_pending(self, *, requested_by: str | None = None) -> int:
        """This account's unfinished jobs, or (cleanup) any left behind for a while."""
        if requested_by is not None:
            jobs = self.ctx.store.query_all(GROUP_REMOVAL, "requestedBy", requested_by)
        else:
            jobs = self.ctx.store.query_all(GROUP_REMOVAL, "createdAt", iso(self.ctx.now() - ABANDONED_REMOVAL), before=True)
        for group_id, _ in jobs:
            self.finish(group_id)
        return len(jobs)


def delete_all(store: Store, keys: list[tuple[str, str]]) -> None:
    for start in range(0, len(keys), _DELETE_BATCH):
        batch = keys[start : start + _DELETE_BATCH]

        def body_fn(transaction: Transaction, batch: list[tuple[str, str]] = batch) -> None:
            for kind, key in batch:
                transaction.delete(kind, key)

        store.run_in_transaction(body_fn)


def _is_private(group: dict[str, Any], uid: str) -> bool:
    """Nobody else has joined: every other seat is a name without an account, or someone who left."""
    return not any(member.get("uid") not in (None, uid) and member["status"] == "active" for member in group["members"])


def _decide(group: dict[str, Any], seat: dict[str, Any], uid: str) -> str | dict[str, Any]:
    """``delete`` (private), ``keep`` (archived: the seat stays), ``leave``, or what stops it."""
    if _is_private(group, uid):
        return "delete"
    if group.get("archivedAt"):
        return "keep"
    if group["ownerMemberId"] == seat["id"]:
        return {"kind": "groupOwner", **_summary(group)}
    problem = leave_blocker(group, seat["id"])
    return "leave" if problem is None else _group_blocker(group, problem)


def _removal_job(group: dict[str, Any], uid: str, now: str) -> dict[str, Any]:
    group_id = group["id"]
    keys: list[tuple[str, str]] = [
        (GROUP_EVENT_PAGE, f"{group_id}:{page:06d}") for page in range((group["eventSequence"] + EVENT_PAGE_SIZE - 1) // EVENT_PAGE_SIZE)
    ]
    for expense in group["expenses"]:
        keys += [(EXPENSE_REVISION, f"{group_id}:{expense['id']}:{revision}") for revision in range(1, expense["revision"] + 1)]
    keys += [(GROUP_RECEIPT, f"{group_id}:{entry['id']}") for entry in group.get("receipts", [])]
    keys += [(GROUP_MEMBERSHIP, f"{member['uid']}:{group_id}") for member in group["members"] if member.get("uid")]
    if group.get("publicationId") and group.get("createdByUid"):
        keys.append((GROUP_PUBLICATION, f"{group['createdByUid']}:{group['publicationId']}"))
    return {"groupId": group_id, "requestedBy": uid, "createdAt": now, "keys": [list(key) for key in keys]}


def _summary(group: dict[str, Any]) -> dict[str, Any]:
    return {"groupId": group["id"], "name": group["name"]}


def _group_blocker(group: dict[str, Any], problem: DomainError) -> dict[str, Any]:
    blocker = {"kind": _GROUP_BLOCKERS.get(problem.code, "groupOther"), **_summary(group)}
    if "balance" in problem.details:
        blocker.update(balance=problem.details["balance"], currency=group["currency"])
    return blocker
