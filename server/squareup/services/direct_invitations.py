"""Direct invitations ("Find a person", October 2026).

Any active member of a shared group can find an existing Square Up account by an email address or
phone number they already know, and invite that account. Nothing about the group changes until the
person accepts in their own Groups tab: they don't see its ledger, balances, or members before
then, and the group doesn't list them. Declining, the sender cancelling, the group being archived,
the sender leaving the group, or 30 days passing ends the invitation. There is at most one
invitation per person per group (the record's key), so a second one can't be sent while one waits.
Link and code invitations (``GroupService``) are separate and unchanged.

Privacy and enumeration:

- Only verified identifiers of accounts with a profile can be found (``AccountService.find``),
  through a directory keyed by a digest; the store never holds an address or number.
- The identifier travels in a POST body, never a URL, so it never reaches a request log. Finding
  someone needs an active membership in a group that isn't archived and is limited per account per
  minute and per day; inviting looks the person up again and counts the same way.
- No match, an unverified identifier, and an account without a profile all return the same
  ``{"match": null}``. A match shows only the name the person chose and the identifier masked —
  never their account ID, member ID, or anything else about them.
- Logs carry no identifier, digest, name, or account ID of the person looked up.
"""

from __future__ import annotations

import uuid
from typing import Any

from ..auth.identity import Principal
from ..domain.errors import DomainError
from ..domain.room import require_text, require_uuid
from ..ledger import group as model
from ..logging_setup import log_event, redact
from ..storage.base import DIRECT_INVITATION, SHARED_GROUP, Transaction
from .accounts import AccountService, masked_identifier, parse_identifier
from .context import ServiceContext, parse_iso
from .groups import GroupService

#: The neutral answer when nobody can be invited with what was entered (no account, an unverified
#: one, or one that hasn't chosen a name yet look the same).
NO_MATCH = "No Square Up account matches that. Check it, or share an invitation link instead"
#: The most invitations one person sees waiting at once (newest first).
MAX_RECEIVED = 50


class DirectInvitationService:
    def __init__(self, ctx: ServiceContext, accounts: AccountService, groups: GroupService) -> None:
        self.ctx = ctx
        self.accounts = accounts
        self.groups = groups

    # MARK: - State

    def _status(self, record: dict[str, Any], group: dict[str, Any] | None) -> str:
        """``pending`` | ``accepted`` | ``declined`` | ``cancelled`` | ``expired``. A waiting invitation
        is cancelled once the group is archived or its sender is no longer in it, and counts as
        accepted once the person is in the group some other way."""
        status = str(record["status"])
        if status != "pending":
            return status
        if group is None or group.get("archivedAt"):
            return "cancelled"
        if model.member_for_uid(group, record["recipientUid"]) is not None:
            return "accepted"
        sender = model.find_member(group, record["inviterMemberId"])
        if sender is None or sender["status"] != "active":
            return "cancelled"
        if parse_iso(record["expiresAt"]) <= self.ctx.now():
            return "expired"
        return "pending"

    def _sent_view(self, record: dict[str, Any], group: dict[str, Any] | None) -> dict[str, Any]:
        """What the sender (and the group's owner) see: the person's name and masked identifier."""
        return {
            "invitationId": record["id"],
            "status": self._status(record, group),
            "displayName": record["recipientName"],
            "maskedIdentifier": record["maskedIdentifier"],
            "invitedByMemberId": record["inviterMemberId"],
            "createdAt": record["createdAt"],
            "expiresAt": record["expiresAt"],
            "respondedAt": record.get("respondedAt"),
        }

    def _received_view(self, record: dict[str, Any], group: dict[str, Any]) -> dict[str, Any]:
        """What the invited person sees before answering — the same as a code invitation's preview:
        the group's name, symbol, and currency, who invited them, and how many people are in it."""
        sender = model.find_member(group, record["inviterMemberId"])
        return {
            "invitationId": record["id"],
            "status": self._status(record, group),
            "groupName": group["name"],
            "symbol": group["symbol"],
            "currency": group["currency"],
            "inviterName": sender["displayName"] if sender else "",
            "memberCount": model.active_count(group),
            "createdAt": record["createdAt"],
            "expiresAt": record["expiresAt"],
        }

    @staticmethod
    def _put(transaction: Transaction, key: str, record: dict[str, Any]) -> None:
        transaction.put(
            DIRECT_INVITATION,
            key,
            record,
            indexed={"groupId": record["groupId"], "recipientUid": record["recipientUid"], "expiresAt": record["expiresAt"]},
        )

    # MARK: - Finding and inviting someone (any member)

    def lookup(self, principal: Principal | None, group_id: str, body: object) -> dict[str, Any]:
        """The account an email address or phone number belongs to, as an invitation would show it,
        and whether it can be invited (``available``, ``invited``, ``member``, or ``you``)."""
        self.accounts.refuse_demo(principal, "Find a person")
        caller = self.groups._caller(principal)
        group_id = require_uuid(group_id, "groupId")
        kind, value = parse_identifier(body)
        group = self.ctx.store.get(SHARED_GROUP, group_id)
        if group is None:
            raise DomainError("group_not_found", "This group isn't available")
        self.groups._seat(group, caller)
        if group.get("archivedAt"):
            raise DomainError("group_archived", "This group was archived")
        found = self.accounts.find(kind, value)
        log_event("group.personLookup", group=redact(group_id), found=found is not None)
        if found is None:
            return {"match": None}
        uid, profile = found
        if uid == caller.subject:
            status = "you"
        elif model.member_for_uid(group, uid) is not None:
            status = "member"
        else:
            existing = self.ctx.store.get(DIRECT_INVITATION, f"{group_id}:{uid}")
            status = "invited" if existing is not None and self._status(existing, group) == "pending" else "available"
        return {"match": {"displayName": profile["displayName"], "maskedIdentifier": masked_identifier(kind, value), "status": status}}

    def invite(self, principal: Principal | None, group_id: str, body: object) -> dict[str, Any]:
        """Sends an invitation to the account this identifier belongs to. It waits for them to accept;
        they aren't added to the group until they do."""
        self.accounts.refuse_demo(principal, "Find a person")
        caller = self.groups._caller(principal)
        group_id = require_uuid(group_id, "groupId")
        kind, value = parse_identifier(body)
        found = self.accounts.find(kind, value)
        if found is None:
            raise DomainError("invitee_not_found", NO_MATCH)
        uid, profile = found
        if uid == caller.subject:
            raise DomainError("cannot_invite_yourself", "That's you. You're already in this group")
        key = f"{group_id}:{uid}"
        now = self.ctx.now_iso()

        def body_fn(transaction: Transaction) -> tuple[dict[str, Any], dict[str, Any]]:
            group = self.groups._load(transaction, group_id)
            seat = self.groups._seat(group, caller)
            if group.get("archivedAt"):
                raise DomainError("group_archived", "This group was archived")
            if model.member_for_uid(group, uid) is not None:
                raise DomainError("invitee_already_member", "They're already in this group")
            self.groups._require_room(group)
            existing = transaction.get(DIRECT_INVITATION, key)
            if existing is not None and self._status(existing, group) == "pending":
                raise DomainError("invitation_exists", "They already have an invitation to this group")
            record = {
                "id": str(uuid.uuid4()),
                "groupId": group_id,
                "recipientUid": uid,
                "recipientName": profile["displayName"],
                "maskedIdentifier": masked_identifier(kind, value),
                "inviterMemberId": seat["id"],
                "inviterUid": caller.subject,
                "createdAt": now,
                "expiresAt": self.ctx.expires_in(self.ctx.config.direct_invitation_ttl_hours),
                "status": "pending",
                "respondedAt": None,
                "acceptedMemberId": None,
            }
            # A new invitation replaces one that ended (declined, cancelled, expired): one per person.
            self._put(transaction, key, record)
            return record, group

        record, group = self.ctx.store.run_in_transaction(body_fn)
        log_event("group.directInvitationCreated", group=redact(group_id))
        return self._sent_view(record, group)

    def sent(self, principal: Principal | None, group_id: str) -> list[dict[str, Any]]:
        """Invitations sent to specific people: the owner sees every one, anyone else their own."""
        caller = self.groups._caller(principal)
        group_id = require_uuid(group_id, "groupId")
        group = self.ctx.store.get(SHARED_GROUP, group_id)
        if group is None:
            raise DomainError("group_not_found", "This group isn't available")
        seat = self.groups._seat(group, caller)
        is_owner = group["ownerMemberId"] == seat["id"]
        records = [
            record
            for _, record in self.ctx.store.query(DIRECT_INVITATION, "groupId", group_id, limit=200)
            if is_owner or record["inviterMemberId"] == seat["id"]
        ]
        return [self._sent_view(record, group) for record in sorted(records, key=lambda r: r["createdAt"], reverse=True)]

    def cancel(self, principal: Principal | None, group_id: str, invitation_id: str) -> dict[str, Any]:
        """The sender or the group's owner takes back an invitation nobody has answered yet."""
        caller = self.groups._caller(principal)
        group_id = require_uuid(group_id, "groupId")
        invitation_id = require_uuid(invitation_id, "invitationId")
        records = self.ctx.store.query(DIRECT_INVITATION, "groupId", group_id, limit=200)
        key = next((key for key, record in records if record["id"] == invitation_id), None)
        now = self.ctx.now_iso()

        def body_fn(transaction: Transaction) -> tuple[dict[str, Any], dict[str, Any]]:
            group = self.groups._load(transaction, group_id)
            seat = self.groups._seat(group, caller)
            record = transaction.get(DIRECT_INVITATION, key) if key is not None else None
            if record is None or record["id"] != invitation_id:
                raise DomainError("not_found", "That invitation isn't available")
            if record["inviterMemberId"] != seat["id"] and group["ownerMemberId"] != seat["id"]:
                raise DomainError("forbidden", "Only the person who sent this invitation, or the group's owner, can cancel it")
            status = self._status(record, group)
            if status in ("accepted", "declined"):
                raise DomainError("invitation_used", "They already answered this invitation")
            if record["status"] == "pending":
                record.update({"status": "cancelled", "respondedAt": now})
                self._put(transaction, str(key), record)
            return record, group

        record, group = self.ctx.store.run_in_transaction(body_fn)
        log_event("group.directInvitationCancelled", group=redact(group_id))
        return self._sent_view(record, group)

    # MARK: - Answering (the invited person)

    def received(self, principal: Principal | None) -> list[dict[str, Any]]:
        """Invitations waiting for this account, newest first. Ones that ended aren't listed."""
        caller = self.accounts.require_account(principal)
        waiting: list[dict[str, Any]] = []
        for _, record in self.ctx.store.query(DIRECT_INVITATION, "recipientUid", caller.subject, limit=200):
            if record["status"] != "pending":
                continue
            group = self.ctx.store.get(SHARED_GROUP, record["groupId"])
            if group is not None and self._status(record, group) == "pending":
                waiting.append(self._received_view(record, group))
        return sorted(waiting, key=lambda view: view["createdAt"], reverse=True)[:MAX_RECEIVED]

    def _own_key(self, caller: Principal, invitation_id: str) -> str:
        """The key of this account's own invitation. Anyone else's looks like one that doesn't exist."""
        records = self.ctx.store.query(DIRECT_INVITATION, "recipientUid", caller.subject, limit=200)
        key = next((key for key, record in records if record["id"] == invitation_id), None)
        if key is None:
            raise DomainError("not_found", "This invitation isn't available")
        return key

    def accept(self, principal: Principal | None, invitation_id: str, body: object) -> tuple[dict[str, Any], bool]:
        """Joins the group with this account, exactly once: a new member with their profile's name,
        recorded in the group's history. Only now do they see the group and its balances."""
        caller = self.accounts.require_account(principal)
        invitation_id = require_uuid(invitation_id, "invitationId")
        key = self._own_key(caller, invitation_id)
        options = body if isinstance(body, dict) else {}
        display_name = options.get("displayName")
        now = self.ctx.now_iso()

        def body_fn(transaction: Transaction) -> tuple[dict[str, Any], dict[str, Any], bool]:
            record = transaction.get(DIRECT_INVITATION, key)
            if record is None or record["id"] != invitation_id or record["recipientUid"] != caller.subject:
                raise DomainError("not_found", "This invitation isn't available")
            group = self.groups._load(transaction, record["groupId"])
            existing = model.member_for_uid(group, caller.subject)
            if existing is not None:
                if record["status"] == "accepted":
                    return group, existing, False  # accepting again is idempotent
                raise DomainError("already_member", "You're already in this group")
            status = self._status(record, group)
            if status == "declined":
                raise DomainError("invitation_declined", "You declined this invitation. Ask for a new one")
            if status == "accepted":
                raise DomainError("invitation_used", "This invitation was already used. Ask for a new one")
            if group.get("archivedAt"):
                raise DomainError("group_archived", "This group was archived")
            if status == "cancelled":
                raise DomainError("invitation_revoked", "This invitation was cancelled. Ask for a new one")
            if status == "expired":
                raise DomainError("invitation_expired", "This invitation expired. Ask for a new one")
            profile = self.accounts.require_profile(transaction, caller.subject)
            name = require_text(
                display_name if display_name is not None else profile["displayName"], "displayName", max_length=model.MAX_MEMBER_NAME
            )
            self.groups._require_room(group)
            seat = self.groups._new_member(group, caller.subject, profile, name, now)
            record.update({"status": "accepted", "respondedAt": now, "acceptedMemberId": seat["id"]})
            self._put(transaction, key, record)
            self.groups._record_join(transaction, group, seat, caller.subject, now)
            return group, seat, True

        group, seat, joined = self.ctx.store.run_in_transaction(body_fn)
        if joined:
            log_event("group.joined", group=redact(group["id"]), seat=False, direct=True)
        snapshot = self.groups._snapshot_view(group, seat, self.groups._history(group), complete=True)
        return snapshot, joined

    def decline(self, principal: Principal | None, invitation_id: str) -> dict[str, Any]:
        """Says no. The sender sees it was declined; declining again changes nothing."""
        caller = self.accounts.require_account(principal)
        invitation_id = require_uuid(invitation_id, "invitationId")
        key = self._own_key(caller, invitation_id)
        now = self.ctx.now_iso()

        def body_fn(transaction: Transaction) -> dict[str, Any]:
            record = transaction.get(DIRECT_INVITATION, key)
            if record is None or record["id"] != invitation_id or record["recipientUid"] != caller.subject:
                raise DomainError("not_found", "This invitation isn't available")
            if record["status"] == "accepted":
                raise DomainError("invitation_used", "You already joined with this invitation")
            if record["status"] == "pending":
                record.update({"status": "declined", "respondedAt": now})
                self._put(transaction, key, record)
            return record

        record = self.ctx.store.run_in_transaction(body_fn)
        log_event("group.directInvitationDeclined", group=redact(record["groupId"]))
        # Cancelled by the sender meanwhile: it stays cancelled, and is gone from the list either way.
        return {"invitationId": record["id"], "status": record["status"], "respondedAt": record["respondedAt"]}
