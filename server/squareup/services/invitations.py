"""Invitations and room-scoped guest identities (milestone 4 §6, §8.2).

- The public token is 256 random bits; only its SHA-256 hash is stored (as the record key), and
  lookups re-check it with a constant-time comparison.
- The URL ``{PUBLIC_BASE_URL}/r/{token}`` contains nothing else: no room ID, names, or amounts.
- Every invitation also has a short code (12 Crockford Base32 characters, 60 bits) that people can
  read across a table and type into the app when a link or QR code isn't convenient. Only its hash
  is stored, as an index record pointing at the invitation; the code travels in request bodies,
  never in a URL path, so it never reaches a request log.
- Invalid and unknown tokens and codes are indistinguishable (``invitation_invalid``); expired,
  revoked, finalized, cancelled, and ended states are explicit and reveal no room contents.
- A guest gets a separate 256-bit credential bound to one participant in one room. Re-opening the
  invitation with that credential restores the same participant instead of creating a new one.
"""

from __future__ import annotations

from typing import Any

from ..auth.identity import Principal, hashes_match, new_secret_token, token_hash
from ..domain.errors import DomainError
from ..domain.room import MAX_DISPLAY_NAME, HistoryEntry, Participant, Room, new_id, require_int, require_text, require_uuid
from ..domain.wire import room_from_storage, room_snapshot
from ..logging_setup import log_event, redact
from ..storage.base import GUEST, INVITATION, ROOM, ROOM_CODE, Transaction
from .codes import ROOM_CODE_LENGTH, display_code, new_code, normalize_code
from .context import ServiceContext, parse_iso
from .rooms import RoomService

_TOKEN_CHARS = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")


def _well_formed(token: str) -> bool:
    return 20 <= len(token) <= 64 and set(token) <= _TOKEN_CHARS


class InvitationService:
    def __init__(self, ctx: ServiceContext, rooms: RoomService) -> None:
        self.ctx = ctx
        self.rooms = rooms

    def invitation_url(self, token: str) -> str:
        return f"{self.ctx.config.public_base_url}/r/{token}"

    # MARK: - Host management

    def create(self, principal: Principal | None, room_id: str, body: object) -> dict[str, Any]:
        room = self.rooms.load(room_id)
        actor = self.rooms.actor_for(room, principal)
        if not actor.is_host:
            raise DomainError("host_only", "Only the host can invite people")
        if room.state in ("finalized", "cancelled"):
            raise DomainError("room_finalized" if room.state == "finalized" else "room_cancelled", "This room is closed")
        self._require_open(room)
        options = body if isinstance(body, dict) else {}
        hours = options.get("expiresInHours", self.ctx.config.invitation_ttl_hours)
        hours = require_int(hours, "expiresInHours", low=1, high=24 * 14)
        max_guests = options.get("maxGuests")
        if max_guests is not None:
            max_guests = require_int(max_guests, "maxGuests", low=1, high=50)
        revoke_existing = bool(options.get("revokeExisting", False))
        token = new_secret_token()
        now = self.ctx.now_iso()
        record = {
            "invitationId": new_id(),
            "roomId": room.id,
            "createdBy": actor.participant_id,
            "createdAt": now,
            "expiresAt": self.ctx.expires_in(hours),
            "revokedAt": None,
            "capabilities": ["participate"],
            "maxGuests": max_guests,
            "guestCount": 0,
            "tokenHash": token_hash(token),
        }

        # Datastore transactions can't contain non-ancestor queries: find candidates first, then
        # re-read and revoke each one inside the transaction.
        to_revoke = [key for key, _ in self.ctx.store.query(INVITATION, "roomId", room.id)] if revoke_existing else []

        def body_fn(transaction: Transaction) -> str:
            for key in to_revoke:
                existing = transaction.get(INVITATION, key)
                if existing is not None and not existing.get("revokedAt"):
                    existing["revokedAt"] = now
                    transaction.put(INVITATION, key, existing, indexed={"roomId": room.id, "expiresAt": existing["expiresAt"]})
            code = new_code(ROOM_CODE_LENGTH)
            while transaction.get(ROOM_CODE, token_hash(code)) is not None:  # pragma: no cover - 60-bit collision
                code = new_code(ROOM_CODE_LENGTH)
            transaction.put(INVITATION, token_hash(token), record, indexed={"roomId": room.id, "expiresAt": record["expiresAt"]})
            transaction.put(
                ROOM_CODE,
                token_hash(code),
                {"invitationKey": token_hash(token), "roomId": room.id, "expiresAt": record["expiresAt"]},
                indexed={"roomId": room.id, "expiresAt": record["expiresAt"]},
            )
            return code

        code = self.ctx.store.run_in_transaction(body_fn)
        log_event("invitation.created", room=redact(room.id))
        # The token, link, and code are returned once; the server keeps only their hashes.
        return {**self._public(record), "url": self.invitation_url(token), "token": token, "code": display_code(code)}

    def list(self, principal: Principal | None, room_id: str) -> list[dict[str, Any]]:
        room = self.rooms.load(room_id)
        if not self.rooms.actor_for(room, principal).is_host:
            raise DomainError("host_only", "Only the host can see invitations")
        return [self._public(record) for _, record in self.ctx.store.query(INVITATION, "roomId", room.id)]

    def revoke(self, principal: Principal | None, room_id: str, invitation_id: str) -> dict[str, Any]:
        room = self.rooms.load(room_id)
        if not self.rooms.actor_for(room, principal).is_host:
            raise DomainError("host_only", "Only the host can revoke invitations")
        invitation_id = require_uuid(invitation_id, "invitationId")
        now = self.ctx.now_iso()
        matches = [
            (key, record) for key, record in self.ctx.store.query(INVITATION, "roomId", room.id) if record["invitationId"] == invitation_id
        ]
        if not matches:
            raise DomainError("invitation_invalid", "That invitation doesn't exist")
        key, record = matches[0]

        def body_fn(transaction: Transaction) -> dict[str, Any]:
            current = transaction.get(INVITATION, key) or record
            if not current.get("revokedAt"):
                current["revokedAt"] = now
                transaction.put(INVITATION, key, current, indexed={"roomId": room.id, "expiresAt": current["expiresAt"]})
            return current

        updated = self.ctx.store.run_in_transaction(body_fn)
        log_event("invitation.revoked", room=redact(room.id))
        return self._public(updated)

    @staticmethod
    def _public(record: dict[str, Any]) -> dict[str, Any]:
        return {
            "invitationId": record["invitationId"],
            "createdAt": record["createdAt"],
            "expiresAt": record["expiresAt"],
            "revokedAt": record.get("revokedAt"),
            "maxGuests": record.get("maxGuests"),
            "guestCount": record.get("guestCount", 0),
            "capabilities": record.get("capabilities", ["participate"]),
        }

    def _require_open(self, room: Room) -> None:
        """A temporary room that ended (square, cancelled, or expired) takes nobody new."""
        if self.rooms.is_expired(room):
            raise DomainError("room_expired", "This room expired")
        if room.closed_at is not None:
            raise DomainError("room_closed", "This room has ended")

    # MARK: - Validation

    def _validated(self, record: dict[str, Any] | None, matches: bool) -> tuple[dict[str, Any], Room]:
        if record is None or not matches:
            raise DomainError("invitation_invalid", "This invitation link isn't valid")
        if record.get("revokedAt"):
            raise DomainError("invitation_revoked", "The host turned off this invitation")
        if parse_iso(record["expiresAt"]) <= self.ctx.now():
            raise DomainError("invitation_expired", "This invitation has expired. Ask the host for a new one")
        room_record = self.ctx.store.get(ROOM, record["roomId"])
        if room_record is None:
            raise DomainError("invitation_invalid", "This invitation link isn't valid")
        room = room_from_storage(room_record)
        if self.rooms.past_retention(room):  # past its retention, a temporary room no longer exists
            raise DomainError("invitation_invalid", "This invitation link isn't valid")
        return record, room

    def lookup(self, token: str) -> tuple[str, dict[str, Any], Room]:
        """``(invitation key, invitation, room)`` for a link token."""
        if not _well_formed(token):
            raise DomainError("invitation_invalid", "This invitation link isn't valid")
        key = token_hash(token)
        record = self.ctx.store.get(INVITATION, key)
        invitation, room = self._validated(record, record is not None and hashes_match(str(record.get("tokenHash", "")), token))
        return key, invitation, room

    def lookup_code(self, raw: object) -> tuple[str, dict[str, Any], Room]:
        """``(invitation key, invitation, room)`` for a short code typed or pasted by someone."""
        code = normalize_code(raw, ROOM_CODE_LENGTH) if isinstance(raw, str) else None
        if code is None:
            raise DomainError("invitation_invalid", "That code isn't valid. Check it with the host")
        alias = self.ctx.store.get(ROOM_CODE, token_hash(code))
        if alias is None:
            raise DomainError("invitation_invalid", "That code isn't valid. Check it with the host")
        record = self.ctx.store.get(INVITATION, alias["invitationKey"])
        invitation, room = self._validated(record, record is not None and record.get("roomId") == alias.get("roomId"))
        return alias["invitationKey"], invitation, room

    # MARK: - Preview

    def preview(self, token: str, principal: Principal | None) -> dict[str, Any]:
        _, invitation, room = self.lookup(token)
        return self._preview(invitation, room, principal)

    def preview_code(self, body: object, principal: Principal | None) -> dict[str, Any]:
        _, invitation, room = self.lookup_code(body.get("code") if isinstance(body, dict) else None)
        return self._preview(invitation, room, principal)

    def _preview(self, invitation: dict[str, Any], room: Room, principal: Principal | None) -> dict[str, Any]:
        """What the invitation allows a not-yet-joined person to see: who invited them, the merchant,
        the date, and the open seats. No items, amounts per person, or other participants' data."""
        host = room.participant(room.host_participant_id)
        you = None
        if principal is not None:
            try:
                you = self.rooms.actor_for(room, principal).participant_id
            except DomainError:
                you = None
        return {
            "status": "valid",
            "roomState": room.state,
            "kind": room.kind,
            "ended": room.closed_at is not None or self.rooms.is_expired(room),
            "expiresAt": invitation["expiresAt"],
            "host": {"displayName": host.display_name if host else ""},
            "merchant": room.receipt.merchant,
            "date": room.receipt.date,
            "currency": room.receipt.currency,
            "openSeats": [
                {"id": p.id, "displayName": p.display_name}
                for p in room.participants
                if p.kind == "member" and p.bound_subject is None and p.is_active
            ],
            "youAreParticipantId": you,
        }

    # MARK: - Joining

    def join(self, token: str, principal: Principal | None, body: object) -> dict[str, Any]:
        invitation_key, _, room = self.lookup(token)
        return self._join(invitation_key, room, principal, body)

    def join_code(self, principal: Principal | None, body: object) -> dict[str, Any]:
        invitation_key, _, room = self.lookup_code(body.get("code") if isinstance(body, dict) else None)
        return self._join(invitation_key, room, principal, body)

    def _join(self, invitation_key: str, room: Room, principal: Principal | None, body: object) -> dict[str, Any]:
        options = body if isinstance(body, dict) else {}
        now = self.ctx.now_iso()

        # Restoration: the same credential or account comes back to the same participant — also
        # after the room ended, to its read-only summary.
        if principal is not None:
            try:
                actor = self.rooms.actor_for(room, principal)
                if room.state not in ("finalized", "cancelled") and principal.kind == "guest":
                    self._extend_guest(principal.subject)
                return {
                    "participantId": actor.participant_id,
                    "restored": True,
                    "credential": None,
                    "room": room_snapshot(room, actor.participant_id, actor.is_host, expired=self.rooms.is_expired(room)),
                }
            except DomainError:
                pass
        if room.state == "finalized":
            raise DomainError("room_finalized", "This receipt was already saved as an expense")
        if room.state == "cancelled":
            raise DomainError("room_cancelled", "The host closed this room")
        self._require_open(room)

        seat_id = options.get("seatId")
        seat_id = require_uuid(seat_id, "seatId") if seat_id is not None else None
        # Claiming a seat keeps the seat's name; a new participant must give one.
        raw_name = options.get("displayName")
        display_name = (
            None if seat_id is not None and raw_name is None else require_text(raw_name, "displayName", max_length=MAX_DISPLAY_NAME)
        )
        is_account = principal is not None and principal.kind == "user"
        if is_account and principal is not None:
            self.rooms.require_full_account(principal)
            self.rooms.require_same_world(room, principal)
        credential: str | None = None if is_account else new_secret_token()
        binding = principal.binding if is_account and principal else f"guest:{token_hash(credential or '')}"
        # In a temporary room a guest has no other way back: their access lasts as long as the
        # room's data does (claiming, paying, then the read-only summary), and goes with it.
        guest_expiry = self.rooms.retain_until(room) or self.ctx.expires_in(self.ctx.config.guest_ttl_hours)

        def body_fn(transaction: Transaction) -> tuple[Room, str]:
            current_invitation = transaction.get(INVITATION, invitation_key)
            record = transaction.get(ROOM, room.id)
            if current_invitation is None or record is None:
                raise DomainError("invitation_invalid", "This invitation link isn't valid")
            if current_invitation.get("revokedAt"):
                raise DomainError("invitation_revoked", "The host turned off this invitation")
            fresh = room_from_storage(record)
            if fresh.state in ("finalized", "cancelled"):
                raise DomainError("room_finalized" if fresh.state == "finalized" else "room_cancelled", "This room is closed")
            self._require_open(fresh)
            max_guests = current_invitation.get("maxGuests")
            if max_guests is not None and current_invitation.get("guestCount", 0) >= max_guests:
                raise DomainError("invitation_full", "This invitation has reached its limit")
            if seat_id is not None:
                seat = fresh.participant(seat_id)
                if seat is None or seat.kind != "member" or not seat.is_active:
                    raise DomainError("participant_not_in_room", "That seat isn't in this room")
                if seat.bound_subject is not None:
                    raise DomainError("seat_taken", "Someone already joined as that person")
                seat.bound_subject = binding
                seat.account_backed = is_account
                participant_id = seat.id
            else:
                if display_name is None:
                    raise DomainError("invalid_payload", "displayName is required")
                participant_id = new_id()
                fresh.participants.append(
                    Participant(
                        id=participant_id,
                        display_name=display_name,
                        kind="guest",
                        joined_at=now,
                        bound_subject=binding,
                        account_backed=is_account,
                    )
                )
            fresh.revision += 1
            fresh.updated_at = now
            fresh.history.append(
                HistoryEntry(
                    fresh.history[-1].sequence + 1 if fresh.history else 1,
                    fresh.revision,
                    participant_id,
                    now,
                    "joined",
                    {"participantId": participant_id},
                )
            )
            self.rooms._put_room(transaction, fresh)
            current_invitation["guestCount"] = current_invitation.get("guestCount", 0) + 1
            transaction.put(
                INVITATION, invitation_key, current_invitation, indexed={"roomId": fresh.id, "expiresAt": current_invitation["expiresAt"]}
            )
            if credential is not None:
                transaction.put(
                    GUEST,
                    token_hash(credential),
                    {
                        "roomId": fresh.id,
                        "participantId": participant_id,
                        "invitationId": current_invitation["invitationId"],
                        "createdAt": now,
                        "expiresAt": guest_expiry,
                        "revokedAt": None,
                    },
                    indexed={"roomId": fresh.id, "expiresAt": guest_expiry},
                )
            return fresh, participant_id

        joined, participant_id = self.ctx.store.run_in_transaction(body_fn)
        log_event("invitation.joined", room=redact(joined.id), kind="account" if is_account else "guest", seat=seat_id is not None)
        return {
            "participantId": participant_id,
            "restored": False,
            "credential": credential,
            "credentialExpiresAt": None if credential is None else guest_expiry,
            "room": room_snapshot(joined, participant_id, False),
        }

    def _extend_guest(self, credential_hash: str) -> None:
        """Sliding expiry while a guest keeps using a live room."""
        expires = self.ctx.expires_in(self.ctx.config.guest_ttl_hours)

        def body_fn(transaction: Transaction) -> None:
            record = transaction.get(GUEST, credential_hash)
            if record is not None and not record.get("revokedAt"):
                record["expiresAt"] = expires
                transaction.put(GUEST, credential_hash, record, indexed={"roomId": record["roomId"], "expiresAt": expires})

        self.ctx.store.run_in_transaction(body_fn)
