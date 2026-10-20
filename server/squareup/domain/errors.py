"""Stable, machine-readable domain errors (API v1 error codes)."""

from __future__ import annotations

from typing import Any

#: HTTP status for each stable error code. Codes are part of the public API contract.
STATUS_FOR_CODE: dict[str, int] = {
    "invalid_payload": 400,
    "payload_too_large": 413,
    "unauthenticated": 401,
    "credential_expired": 401,
    "forbidden": 403,
    "host_only": 403,
    "not_a_participant": 403,
    "room_not_found": 404,
    "not_found": 404,
    "invitation_invalid": 404,
    "invitation_expired": 410,
    "invitation_revoked": 410,
    "invitation_full": 409,
    "room_finalized": 409,
    "room_cancelled": 409,
    "revision_conflict": 409,
    "idempotency_key_reused": 422,
    "not_allowed_in_state": 409,
    "item_not_found": 404,
    "item_not_claimable": 422,
    "charge_not_found": 404,
    "dispute_not_found": 404,
    "item_already_claimed": 409,
    "item_has_custom_split": 409,
    "no_claim_to_remove": 409,
    "cannot_include_others": 403,
    "cannot_remove_others": 403,
    "invalid_split": 422,
    "invalid_allocation": 422,
    "dispute_already_resolved": 409,
    "note_required": 422,
    "note_too_long": 422,
    "receipt_not_ready": 422,
    "currency_change_after_open": 422,
    "participant_not_in_room": 422,
    "participants_required": 422,
    "seat_taken": 409,
    "not_ready_to_finalize": 409,
    "unresolved_dispute": 409,
    "asset_not_found": 404,
    # Unit claims, reviews, and temporary rooms (receipt split, October 2026).
    "item_quantity_unknown": 422,
    "units_unavailable": 409,
    "unreviewed_shares": 409,
    "room_expired": 410,
    "room_closed": 409,
    "no_payment_due": 409,
    "payment_not_found": 404,
    # Group receipt allocations.
    "receipt_not_found": 404,
    "receipt_limit": 409,
    "receipt_conflict": 409,
    "member_has_open_receipt": 409,
    "group_has_open_receipts": 409,
    "unsupported_media": 415,
    "rate_limited": 429,
    "temporarily_unavailable": 503,
    # Shared groups (milestone 7).
    "account_required": 403,
    "profile_required": 409,
    "owner_only": 403,
    "group_not_found": 404,
    "not_a_member": 403,
    "group_archived": 410,
    "group_full": 409,
    "entity_exists": 409,
    "expense_not_found": 404,
    "expense_deleted": 409,
    "expense_not_deleted": 409,
    "expense_conflict": 409,
    "invalid_expense": 422,
    "invalid_receipt": 422,
    "inactive_participant": 422,
    "currency_mismatch": 422,
    "currency_locked": 409,
    "pending_payment_conflict": 409,
    "member_has_balance": 409,
    "group_has_balances": 409,
    "group_has_open_payments": 409,
    "member_has_open_payment": 409,
    "member_has_open_room": 409,
    "cannot_remove_yourself": 409,
    "owner_must_transfer": 409,
    "cannot_pay_self": 422,
    "recipient_not_joined": 409,
    "no_obligation": 409,
    "exceeds_obligation": 409,
    "destination_unavailable": 409,
    "destination_not_found": 404,
    "invalid_destination": 422,
    "reveal_not_allowed": 403,
    "attempt_not_found": 404,
    "room_not_adoptable": 409,
    "guests_not_matched": 422,
    "invitation_used": 409,
    "already_member": 409,
    "seat_unavailable": 409,
    "publication_invalid": 422,
    # Direct invitations ("Find a person").
    "invitee_not_found": 404,
    "invitee_already_member": 409,
    "cannot_invite_yourself": 409,
    "invitation_exists": 409,
    "invitation_declined": 409,
    "cursor_invalid": 400,
    # Demo workspaces ("Enter Demo").
    "demo_restricted": 403,
    "demo_unavailable": 503,
    # Receipt intelligence (milestone 5). Every one of these makes the app use its on-device parser.
    "ai_consent_required": 403,
    "ai_in_progress": 409,
    "ai_invalid_output": 502,
    "ai_refused": 502,
    "ai_provider_error": 502,
    "ai_unavailable": 503,
    "email_not_verified": 403,
    "ai_timeout": 504,
    # A demo workspace used its (or all demos') AI receipt reading for today; the app reads on device.
    "ai_demo_limit": 429,
    # Deleting an account: it needs a sign-in from the last few minutes, and nothing left to settle.
    "recent_sign_in_required": 401,
    "account_has_obligations": 409,
}


class DomainError(Exception):
    """A rule violation. Nothing was changed."""

    def __init__(self, code: str, message: str, details: dict[str, Any] | None = None) -> None:
        super().__init__(message)
        if code not in STATUS_FOR_CODE:
            raise ValueError(f"Unknown error code {code}")
        self.code = code
        self.message = message
        self.details = details or {}

    @property
    def status(self) -> int:
        return STATUS_FOR_CODE[self.code]
