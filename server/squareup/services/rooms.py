"""Authoritative Receipt Rooms: publish, read, revisioned idempotent commands, finalize, link guests.

Handlers stay thin; every rule lives here or in ``domain``. Each mutation runs in one store
transaction that (1) loads the room, (2) authorizes the caller from their credential, (3) checks
idempotency, (4) checks the expected revision, (5) applies the command through the pure engine,
and (6) writes the room and the idempotency record together — or writes nothing.
"""

from __future__ import annotations

import json
import uuid
from dataclasses import dataclass
from datetime import timedelta
from typing import Any

from ..auth.identity import Principal, token_hash
from ..domain.engine import Actor, apply_command
from ..domain.errors import DomainError
from ..domain.readiness import receipt_blocking_issues
from ..domain.room import (
    MAX_DISPLAY_NAME,
    MAX_PARTICIPANTS,
    Claim,
    HistoryEntry,
    Participant,
    Room,
    require_int,
    require_text,
    require_uuid,
)
from ..domain.wire import claim_mode_from_wire, receipt_from_wire, room_from_storage, room_snapshot, room_to_storage
from ..logging_setup import log_event, redact
from ..storage.base import ACCOUNT, ASSET, GUEST, IDEMPOTENCY, INVITATION, ROOM, ROOM_CODE, Transaction
from .context import ServiceContext, fingerprint, iso, parse_iso

MAX_IDEMPOTENCY_KEY = 64
#: Datastore entities are limited to 1 MiB; refuse growth well before that instead of failing the write.
MAX_ROOM_BYTES = 900_000
#: A guest credential's sliding expiry is pushed forward at most this often (one small write).
GUEST_EXTENSION_STEP = timedelta(hours=1)


@dataclass
class CommandEnvelope:
    command_id: str
    idempotency_key: str
    expected_revision: int
    type: str
    payload: dict[str, Any]

    @staticmethod
    def parse(raw: object, forced_type: str | None = None) -> CommandEnvelope:
        if not isinstance(raw, dict):
            raise DomainError("invalid_payload", "Body must be a JSON object")
        key = raw.get("idempotencyKey")
        if not isinstance(key, str) or not 8 <= len(key) <= MAX_IDEMPOTENCY_KEY or not key.isascii():
            raise DomainError("invalid_payload", "idempotencyKey must be 8–64 ASCII characters")
        command_type = forced_type or raw.get("type")
        if not isinstance(command_type, str):
            raise DomainError("invalid_payload", "type is required")
        payload = raw.get("payload", {})
        if not isinstance(payload, dict):
            raise DomainError("invalid_payload", "payload must be an object")
        return CommandEnvelope(
            command_id=require_uuid(raw.get("commandId"), "commandId"),
            idempotency_key=key,
            expected_revision=require_int(raw.get("expectedRevision"), "expectedRevision", low=0, high=10_000_000),
            type=command_type,
            payload=payload,
        )

    def fingerprint(self) -> str:
        return fingerprint({"type": self.type, "payload": self.payload, "expectedRevision": self.expected_revision})


class RoomService:
    def __init__(self, ctx: ServiceContext) -> None:
        self.ctx = ctx

    # MARK: - Identity

    def resolve_guest(self, token: str) -> Principal | None:
        """A valid, unexpired, unrevoked guest credential, or ``None``."""
        if len(token) > 128:
            return None
        hashed = token_hash(token)
        record = self.ctx.store.get(GUEST, hashed)
        if record is None or record.get("revokedAt") or parse_iso(record["expiresAt"]) <= self.ctx.now():
            return None
        return Principal("guest", hashed, room_id=record["roomId"], participant_id=record["participantId"])

    @staticmethod
    def require_full_account(principal: Principal) -> None:
        """A signed-in user (not a room guest) must be an email or phone account Firebase reports as
        verified. Guests keep using their room-scoped credential."""
        if principal.kind != "user" or principal.demo:
            return
        if not principal.recoverable:
            raise DomainError("account_required", "Create an account with your email or phone number to use receipt rooms with an account")
        if not principal.verified:
            raise DomainError("email_not_verified", "Verify your email address to use receipt rooms with your account")

    def actor_for(self, room: Room, principal: Principal | None) -> Actor:
        if principal is None:
            raise DomainError("unauthenticated", "Open the invitation again to rejoin this room")
        self.require_full_account(principal)
        if principal.kind == "user" and principal.subject == room.host_uid:
            return Actor(room.host_participant_id, is_host=True)
        if principal.kind == "guest" and principal.room_id != room.id:
            raise DomainError("room_not_found", "This receipt isn't available")
        participant = next((p for p in room.participants if p.bound_subject == principal.binding), None)
        if participant is None:
            # Never confirm a room exists to someone who was never in it.
            raise DomainError("room_not_found", "This receipt isn't available")
        if not participant.is_active:
            raise DomainError("not_a_participant", "The host removed you from this room")
        return Actor(participant.id, is_host=False)

    # MARK: - Publish

    def publish(self, principal: Principal | None, body: object) -> tuple[dict[str, Any], bool]:
        if principal is None or principal.kind != "user":
            raise DomainError("unauthenticated", "Sign in to share a receipt room")
        self.require_full_account(principal)
        if not isinstance(body, dict):
            raise DomainError("invalid_payload", "Body must be a JSON object")
        room_id = require_uuid(body.get("roomId"), "roomId")
        receipt = receipt_from_wire(body.get("receipt"))
        issues = receipt_blocking_issues(receipt)
        if issues:
            raise DomainError("receipt_not_ready", "Finish reviewing the receipt first", {"issues": issues})
        participants_raw = body.get("participants")
        if not isinstance(participants_raw, list) or not participants_raw or len(participants_raw) > MAX_PARTICIPANTS:
            raise DomainError("participants_required", "Choose who's at the table")
        host_pid = require_uuid(body.get("hostParticipantId"), "hostParticipantId")
        payer_id = require_uuid(body.get("payerId"), "payerId")
        now = self.ctx.now_iso()
        participants: list[Participant] = []
        for entry in participants_raw:
            if not isinstance(entry, dict):
                raise DomainError("invalid_payload", "participants entries must be objects")
            pid = require_uuid(entry.get("id"), "participant.id")
            if any(p.id == pid for p in participants):
                raise DomainError("invalid_payload", "Duplicate participant")
            is_host = pid == host_pid
            participants.append(
                Participant(
                    id=pid,
                    display_name=require_text(entry.get("displayName"), "displayName", max_length=MAX_DISPLAY_NAME),
                    kind="host" if is_host else "member",
                    joined_at=now,
                    bound_subject=principal.binding if is_host else None,
                    account_backed=is_host,
                )
            )
        if not any(p.id == host_pid for p in participants):
            raise DomainError("invalid_payload", "The host must be a participant")
        participants.sort(key=lambda p: 0 if p.id == host_pid else 1)
        if not any(p.id == payer_id for p in participants):
            raise DomainError("participant_not_in_room", "The payer must be a participant")
        claims = self._parse_claims(body.get("claims", []), receipt, {p.id for p in participants})
        accepts = body.get("payerAcceptsFullReceipt", False)
        if not isinstance(accepts, bool):
            raise DomainError("invalid_payload", "payerAcceptsFullReceipt must be true or false")
        kind = body.get("kind", "group")
        if kind not in ("group", "temporary"):
            raise DomainError("invalid_payload", "kind must be group or temporary")
        destination_ids: list[str] = []
        expires_at: str | None = None
        if kind == "temporary":
            # "Split with people now": no group and no seats. The person who scanned the receipt
            # hosts it and paid for it; everyone else joins by invitation.
            if len(participants) != 1 or payer_id != host_pid:
                raise DomainError("invalid_payload", "A temporary room starts with only its host, who paid")
            destination_ids = self._host_destinations(principal.subject, body.get("paymentDestinationIds", []))
            expires_at = self.ctx.expires_in(self.ctx.config.temporary_room_ttl_hours)
        room = Room(
            id=room_id,
            host_uid=principal.subject,
            host_participant_id=host_pid,
            payer_id=payer_id,
            state="open",
            receipt=receipt,
            participants=participants,
            claims=claims,
            payer_accepts_full_receipt=accepts,
            revision=1,
            history=[HistoryEntry(1, 1, host_pid, now, "published", {})],
            created_at=now,
            updated_at=now,
            kind=kind,
            expires_at=expires_at,
            destination_ids=destination_ids,
        )

        def body_fn(transaction: Transaction) -> tuple[Room, bool]:
            existing = transaction.get(ROOM, room_id)
            if existing is not None:
                stored = room_from_storage(existing)
                if stored.host_uid != principal.subject:
                    raise DomainError("room_not_found", "This receipt isn't available")
                return stored, False  # publishing again is idempotent
            self._put_room(transaction, room)
            return room, True

        stored, created = self.ctx.store.run_in_transaction(body_fn)
        if created:
            log_event("room.published", room=redact(room_id), items=len(receipt.items), participants=len(participants))
        return room_snapshot(stored, stored.host_participant_id, True), created

    @staticmethod
    def _parse_claims(raw: object, receipt: Any, participants: set[str]) -> list[Claim]:
        if not isinstance(raw, list) or len(raw) > 2000:
            raise DomainError("invalid_payload", "claims is invalid")
        claims: list[Claim] = []
        for entry in raw:
            if not isinstance(entry, dict):
                raise DomainError("invalid_payload", "claims entries must be objects")
            item_id = require_uuid(entry.get("itemId"), "claim.itemId")
            pid = require_uuid(entry.get("participantId"), "claim.participantId")
            if receipt.item(item_id) is None or pid not in participants:
                raise DomainError("invalid_payload", "A claim refers to an unknown item or person")
            if any(c.item_id == item_id and c.participant_id == pid for c in claims):
                raise DomainError("invalid_payload", "Duplicate claim")
            claims.append(Claim(item_id, pid, claim_mode_from_wire(entry.get("mode"), 100_000_000_000)))
        return claims

    def _host_destinations(self, uid: str, raw: object) -> list[str]:
        """The payment methods the host chose to show people who'll owe them (enabled ones only)."""
        if not isinstance(raw, list) or len(raw) > 12:
            raise DomainError("invalid_payload", "paymentDestinationIds must be a list")
        chosen: list[str] = []
        for value in raw:
            destination_id = require_uuid(value, "paymentDestinationIds")
            if destination_id not in chosen:
                chosen.append(destination_id)
        if not chosen:
            return []
        profile = self.ctx.store.get(ACCOUNT, uid) or {"destinations": []}
        enabled = {d["id"] for d in profile.get("destinations", []) if d.get("isEnabled")}
        if any(destination_id not in enabled for destination_id in chosen):
            raise DomainError("destination_unavailable", "That payment method isn't available anymore")
        return chosen

    # MARK: - Temporary-room lifetime

    def is_expired(self, room: Room) -> bool:
        """A temporary room past its deadline that hasn't been closed yet (cleanup closes it)."""
        return room.is_temporary and room.closed_at is None and room.expires_at is not None and parse_iso(room.expires_at) <= self.ctx.now()

    def has_ended(self, room: Room) -> bool:
        """Nothing more can happen in the room: a temporary room that closed (square, cancelled) or
        passed its deadline, or any other room once it's finalized or cancelled."""
        if room.is_temporary:
            return room.closed_at is not None or self.is_expired(room)
        return room.state in ("finalized", "cancelled")

    def retain_until(self, room: Room) -> str | None:
        """When everything about a temporary room — including its read-only summary — is deleted."""
        if not room.is_temporary:
            return None
        ended = room.closed_at or room.expires_at
        if ended is None:
            return None
        return iso(parse_iso(ended) + timedelta(days=self.ctx.config.temporary_room_retention_days))

    def past_retention(self, room: Room) -> bool:
        retain = self.retain_until(room)
        return retain is not None and (room.closed_at is not None or self.is_expired(room)) and parse_iso(retain) <= self.ctx.now()

    # MARK: - Read

    def load(self, room_id: str) -> Room:
        record = self.ctx.store.get(ROOM, require_uuid(room_id, "roomId"))
        if record is None:
            raise DomainError("room_not_found", "This receipt isn't available")
        room = room_from_storage(record)
        if self.past_retention(room):
            # The summary's retention ended; cleanup deletes it shortly. Nothing is shown meanwhile.
            raise DomainError("room_not_found", "This receipt isn't available")
        return room

    def snapshot(self, principal: Principal | None, room_id: str) -> dict[str, Any]:
        room = self.load(room_id)
        actor = self.actor_for(room, principal)
        self.touch_guest(principal, room)
        return room_snapshot(room, actor.participant_id, actor.is_host, expired=self.is_expired(room))

    def touch_guest(self, principal: Principal | None, room: Room) -> None:
        """Slides a guest credential's expiry while it's in use (at most hourly), never past the
        room's retention. Legacy rooms keep their sliding window without a cap."""
        if principal is None or principal.kind != "guest":
            return
        retain = self.retain_until(room)
        # A temporary room's guests keep access exactly as long as the room's data exists (their
        # only way back to pay and see the summary); elsewhere it slides while in use.
        target = parse_iso(retain) if retain is not None else self.ctx.now() + timedelta(hours=self.ctx.config.guest_ttl_hours)

        def body_fn(transaction: Transaction) -> None:
            record = transaction.get(GUEST, principal.subject)
            if record is None or record.get("revokedAt"):
                return
            if parse_iso(record["expiresAt"]) + GUEST_EXTENSION_STEP > target:
                return
            record["expiresAt"] = iso(target)
            transaction.put(GUEST, principal.subject, record, indexed={"roomId": record["roomId"], "expiresAt": record["expiresAt"]})

        self.ctx.store.run_in_transaction(body_fn)

    def payment_destinations(self, principal: Principal | None, room_id: str) -> dict[str, Any]:
        """The payer's chosen payment methods in a temporary room — only for someone who still owes
        them after finalization (and the host). Nothing else about the payer's account is shared."""
        room = self.load(room_id)
        actor = self.actor_for(room, principal)
        if not room.is_temporary:
            raise DomainError("not_found", "Payment details aren't shared for this receipt")
        if not actor.is_host:
            payment = next((p for p in room.payments if p["participantId"] == actor.participant_id), None)
            if room.state != "finalized" or room.closed_at or self.is_expired(room) or payment is None or payment["state"] == "confirmed":
                raise DomainError("reveal_not_allowed", "Payment details are shown only while you owe the payer")
        profile = self.ctx.store.get(ACCOUNT, room.host_uid) or {"destinations": []}
        by_id = {d["id"]: d for d in profile.get("destinations", []) if d.get("isEnabled")}
        payer = room.participant(room.payer_id) if room.payer_id else None
        log_event("room.destinationsRevealed", room=redact(room.id))
        return {
            "recipient": {"participantId": room.payer_id, "displayName": payer.display_name if payer else ""},
            "destinations": [by_id[destination_id] for destination_id in room.destination_ids if destination_id in by_id],
        }

    def history(self, principal: Principal | None, room_id: str) -> list[dict[str, Any]]:
        room = self.load(room_id)
        self.actor_for(room, principal)
        return [entry.to_wire() for entry in room.history]

    # MARK: - Commands

    def command(self, principal: Principal | None, room_id: str, raw: object, forced_type: str | None = None) -> dict[str, Any]:
        envelope = CommandEnvelope.parse(raw, forced_type)
        room_id = require_uuid(room_id, "roomId")
        now = self.ctx.now_iso()
        binding = principal.binding if principal else "anonymous"
        idempotency_name = token_hash(f"{room_id}|{binding}|{envelope.idempotency_key}")
        request_fingerprint = envelope.fingerprint()

        def body_fn(transaction: Transaction) -> dict[str, Any]:
            record = transaction.get(ROOM, room_id)
            if record is None:
                raise DomainError("room_not_found", "This receipt isn't available")
            room = room_from_storage(record)
            if self.past_retention(room):
                raise DomainError("room_not_found", "This receipt isn't available")
            actor = self.actor_for(room, principal)
            previous = transaction.get(IDEMPOTENCY, idempotency_name)
            if previous is not None:
                if previous["fingerprint"] != request_fingerprint:
                    raise DomainError("idempotency_key_reused", "That request key was already used for a different change")
                return self._result(room, actor, previous["commandId"], applied=previous["applied"], replayed=True)
            if envelope.type == "finalize" and room.state == "finalized":
                if not actor.is_host:
                    raise DomainError("host_only", "Only the host can do that")
                return self._result(room, actor, envelope.command_id, applied=False, replayed=False)
            if self.is_expired(room):
                raise DomainError("room_expired", "This room expired. Nothing more can change")
            if envelope.expected_revision != room.revision:
                raise DomainError(
                    "revision_conflict", "The room changed. Review the latest and try again", {"currentRevision": room.revision}
                )
            updated, changed = apply_command(room, actor, envelope.type, envelope.payload, now, max_amount=100_000_000_000)
            if changed and updated.is_temporary and envelope.type == "finalize" and updated.closed_at is None:
                # Finalized: people now have the payment window to pay and be confirmed.
                updated.expires_at = self.ctx.expires_in(self.ctx.config.temporary_room_payment_days * 24)
            if changed:
                self._put_room(transaction, updated)
                if envelope.type == "removeParticipant":
                    self._revoke_bound_guest(transaction, updated, envelope.payload.get("participantId"), now)
            transaction.put(
                IDEMPOTENCY,
                idempotency_name,
                {"fingerprint": request_fingerprint, "commandId": envelope.command_id, "applied": changed, "createdAt": now},
                indexed={"createdAt": now},
            )
            return self._result(updated, actor, envelope.command_id, applied=changed, replayed=False)

        result: dict[str, Any] = self.ctx.store.run_in_transaction(body_fn)
        if result["applied"] and envelope.type == "finalize" and result["room"].get("kind") == "temporary":
            # Paying takes longer than claiming: guests' access now lasts until the room's new end.
            self._extend_guests(room_id)
        log_event(
            "room.command",
            room=redact(room_id),
            type=envelope.type,
            applied=result["applied"],
            replayed=result["replayed"],
            revision=result["revision"],
        )
        return result

    def _extend_guests(self, room_id: str) -> None:
        record = self.ctx.store.get(ROOM, room_id)
        retain = self.retain_until(room_from_storage(record)) if record is not None else None
        if retain is None:
            return
        for key, _ in self.ctx.store.query(GUEST, "roomId", room_id, limit=500):

            def body_fn(transaction: Transaction, key: str = key) -> None:
                guest = transaction.get(GUEST, key)
                if guest is None or guest.get("revokedAt") or guest["expiresAt"] >= retain:
                    return
                guest["expiresAt"] = retain
                transaction.put(GUEST, key, guest, indexed={"roomId": room_id, "expiresAt": retain})

            self.ctx.store.run_in_transaction(body_fn)

    def conflict_snapshot(self, principal: Principal | None, room_id: str) -> dict[str, Any] | None:
        """The current snapshot for a caller entitled to see it (attached to conflict responses)."""
        try:
            return self.snapshot(principal, room_id)
        except DomainError:
            return None

    def _result(self, room: Room, actor: Actor, command_id: str, *, applied: bool, replayed: bool) -> dict[str, Any]:
        return {
            "commandId": command_id,
            "applied": applied,
            "replayed": replayed,
            "revision": room.revision,
            "room": room_snapshot(room, actor.participant_id, actor.is_host, expired=self.is_expired(room)),
        }

    def _put_room(self, transaction: Transaction, room: Room) -> None:
        if room.is_temporary:
            # A temporary room is finished when it ends (square, cancelled, or expired), not at
            # finalization: its images stay viewable while people are still paying.
            finished_at = room.closed_at
        else:
            finished_at = room.finalization.finalized_at if room.finalization else (room.updated_at if room.state == "cancelled" else None)
        stored = room_to_storage(room)
        if len(json.dumps(stored, separators=(",", ":"))) > MAX_ROOM_BYTES:
            raise DomainError("payload_too_large", "This room has reached its size limit")
        indexed: dict[str, Any] = {"hostUid": room.host_uid, "state": room.state, "updatedAt": room.updated_at, "finishedAt": finished_at}
        # Cleanup of temporary rooms: close them at their deadline, delete them after retention.
        # Written only when set, so no other room can ever match these range queries.
        if room.is_temporary and room.closed_at is None and room.expires_at:
            indexed["expiresAt"] = room.expires_at
        if room.is_temporary and room.closed_at:
            indexed["purgeAt"] = self.retain_until(room)
        transaction.put(ROOM, room.id, stored, indexed=indexed)

    def _revoke_bound_guest(self, transaction: Transaction, room: Room, participant_id: object, now: str) -> None:
        participant = room.participant(participant_id) if isinstance(participant_id, str) else None
        if participant is None or not participant.bound_subject or not participant.bound_subject.startswith("guest:"):
            return
        credential_hash = participant.bound_subject.removeprefix("guest:")
        record = transaction.get(GUEST, credential_hash)
        if record is not None and not record.get("revokedAt"):
            record["revokedAt"] = now
            transaction.put(GUEST, credential_hash, record, indexed={"roomId": record["roomId"], "expiresAt": record["expiresAt"]})

    # MARK: - Retention of temporary rooms (cleanup job)

    def close_expired(self) -> int:
        """Ends temporary rooms whose deadline passed: claiming never finished, or people didn't
        finish paying. They become a read-only summary until their retention ends."""
        now = self.ctx.now_iso()
        closed = 0
        for room_id, _ in self.ctx.store.query_before(ROOM, "expiresAt", now, limit=200):

            def body_fn(transaction: Transaction, room_id: str = room_id) -> bool:
                record = transaction.get(ROOM, room_id)
                if record is None:
                    return False
                room = room_from_storage(record)
                if not self.is_expired(room):
                    return False
                room.closed_at = room.expires_at
                room.end_reason = "expired"
                room.revision += 1
                room.updated_at = now
                room.history.append(
                    HistoryEntry(
                        room.history[-1].sequence + 1 if room.history else 1, room.revision, room.host_participant_id, now, "expired", {}
                    )
                )
                self._put_room(transaction, room)
                return True

            if self.ctx.store.run_in_transaction(body_fn):
                closed += 1
        if closed:
            log_event("room.temporaryClosed", count=closed)
        return closed

    def purge_ended(self) -> int:
        """Deletes temporary rooms whose summary retention ended, with everything tied to them:
        invitations, short codes, guest credentials, and receipt images (objects and records)."""
        now = self.ctx.now_iso()
        purged = 0
        for room_id, _ in self.ctx.store.query_before(ROOM, "purgeAt", now, limit=100):
            # Non-ancestor queries can't run inside a transaction: find what's tied to the room first.
            related = [
                (kind, key)
                for kind in (INVITATION, ROOM_CODE, GUEST, ASSET)
                for key, _ in self.ctx.store.query(kind, "roomId", room_id, limit=500)
            ]
            for _, asset in self.ctx.store.query(ASSET, "roomId", room_id, limit=50):
                self.ctx.blobs.delete(asset["objectName"])
            for kind, key in related:

                def delete(transaction: Transaction, kind: str = kind, key: str = key) -> None:
                    transaction.delete(kind, key)

                self.ctx.store.run_in_transaction(delete)

            def delete_room(transaction: Transaction, room_id: str = room_id) -> bool:
                record = transaction.get(ROOM, room_id)
                if record is None:
                    return False
                room = room_from_storage(record)
                retain = self.retain_until(room)
                if room.closed_at is None or retain is None or parse_iso(retain) > self.ctx.now():
                    return False
                transaction.delete(ROOM, room_id)
                return True

            if self.ctx.store.run_in_transaction(delete_room):
                purged += 1
        if purged:
            log_event("room.temporaryDeleted", count=purged)
        return purged

    # MARK: - Demo workspaces

    @staticmethod
    def is_demo_room(room: Room) -> bool:
        """Hosted by a demo account. Only the server issues ``demo-`` subjects (``services.demo``);
        Firebase user IDs never contain a hyphen and development IDs start with ``dev-``."""
        return room.host_uid.startswith("demo-")

    @classmethod
    def require_same_world(cls, room: Room, principal: Principal) -> None:
        """An account joins (or links a guest place in) a room only on its own side: demo accounts in
        demo rooms, real accounts in real rooms. Guests without an account may join either."""
        if principal.kind != "user" or principal.demo == cls.is_demo_room(room):
            return
        if principal.demo:
            raise DomainError("demo_restricted", "Joining a live room outside the demo isn't available in the demo")
        raise DomainError("demo_restricted", "This live room is part of a demo with sample data, so it can't be joined with an account")

    def anonymize_participant(self, room_id: str, binding: str, name: str) -> bool:
        """A deleted account's place in a room keeps its claims and payments under ``name``.
        Returns whether anything changed; repeating is harmless."""
        now = self.ctx.now_iso()

        def body_fn(transaction: Transaction) -> bool:
            record = transaction.get(ROOM, room_id)
            if record is None:
                return False
            room = room_from_storage(record)
            renamed = [p for p in room.participants if p.bound_subject == binding and p.display_name != name]
            if not renamed:
                return False
            for participant in renamed:
                participant.display_name = name
            room.revision += 1
            room.updated_at = now
            self._put_room(transaction, room)
            return True

        changed: bool = self.ctx.store.run_in_transaction(body_fn)
        return changed

    def delete_hosted_by(self, uid: str) -> int:
        """Every room this (demo) account hosts, with its invitations, short codes, guest credentials,
        and receipt images — when its demo workspace ends."""
        rooms = self.ctx.store.query(ROOM, "hostUid", uid, limit=200)
        for room_id, _ in rooms:
            self.delete_room(room_id)
        return len(rooms)

    def delete_room(self, room_id: str) -> None:
        """One room with its invitations, short codes, guest credentials, and receipt images. Safe to
        repeat (deleting a missing image or record is a no-op)."""
        found = {kind: self.ctx.store.query_all(kind, "roomId", room_id) for kind in (INVITATION, ROOM_CODE, GUEST, ASSET)}
        # Images first, the room record last: a deletion that stops part-way is found and finished again.
        for _, asset in found[ASSET]:
            self.ctx.blobs.delete(asset["objectName"])
        for kind, key in [*((kind, key) for kind, records in found.items() for key, _ in records), (ROOM, room_id)]:

            def delete(transaction: Transaction, kind: str = kind, key: str = key) -> None:
                transaction.delete(kind, key)

            self.ctx.store.run_in_transaction(delete)

    # MARK: - Linking a guest to a full-app account (milestone 4 §13)

    def link_guest(self, principal: Principal | None, room_id: str, body: object) -> dict[str, Any]:
        if principal is None or principal.kind != "user":
            raise DomainError("unauthenticated", "Sign in to keep your place in this room")
        self.require_full_account(principal)
        if not isinstance(body, dict) or not isinstance(body.get("guestToken"), str):
            raise DomainError("invalid_payload", "guestToken is required")
        guest = self.resolve_guest(body["guestToken"])
        room_id = require_uuid(room_id, "roomId")
        if guest is None or guest.room_id != room_id:
            raise DomainError("credential_expired", "That guest access ended, so it can't be linked")
        now = self.ctx.now_iso()

        def body_fn(transaction: Transaction) -> dict[str, Any]:
            record = transaction.get(ROOM, room_id)
            if record is None:
                raise DomainError("room_not_found", "This receipt isn't available")
            room = room_from_storage(record)
            self.require_same_world(room, principal)
            if any(p.bound_subject == principal.binding for p in room.participants) or principal.subject == room.host_uid:
                raise DomainError("seat_taken", "Your account is already in this room as someone else")
            participant = next((p for p in room.participants if p.bound_subject == guest.binding), None)
            if participant is None:
                raise DomainError("room_not_found", "This receipt isn't available")
            participant.bound_subject = principal.binding
            participant.account_backed = True
            room.revision += 1
            room.updated_at = now
            room.history.append(
                HistoryEntry(room.history[-1].sequence + 1 if room.history else 1, room.revision, participant.id, now, "guestLinked", {})
            )
            self._put_room(transaction, room)
            credential = transaction.get(GUEST, guest.subject)
            if credential is not None:
                credential["revokedAt"] = now
                transaction.put(GUEST, guest.subject, credential, indexed={"roomId": room_id, "expiresAt": credential["expiresAt"]})
            return room_snapshot(room, participant.id, False)

        snapshot: dict[str, Any] = self.ctx.store.run_in_transaction(body_fn)
        log_event("room.guestLinked", room=redact(room_id))
        return snapshot


def new_command_id() -> str:
    return str(uuid.uuid4())
