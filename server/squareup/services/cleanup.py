"""Retention (milestone 4 §10–§11, milestone 7 §13.3): expired room, group, and direct invitations, guest credentials, idempotency records,
rate counters, cached receipt-intelligence results, and the receipt images of finished rooms are deleted on a schedule.
Temporary rooms ("Split with people now") are closed at their deadline and, once their read-only summary's
retention ends, deleted with their invitations, short codes, guest credentials, and images. Demo workspaces
("Enter Demo") are deleted, with everything in them, a week after they start.

Run by App Engine cron (``cron.yaml``) through ``/tasks/cleanup``, which only accepts requests
carrying App Engine's ``X-Appengine-Cron`` header (stripped from external traffic by App Engine).
"""

from __future__ import annotations

from datetime import timedelta

from ..storage.base import DIRECT_INVITATION, GROUP_INVITATION, GUEST, IDEMPOTENCY, INTELLIGENCE, INVITATION, RATE, ROOM_CODE, Transaction
from .assets import AssetService
from .context import ServiceContext, iso
from .demo import DemoService

#: Idempotency records only need to outlive client retries.
IDEMPOTENCY_RETENTION = timedelta(hours=48)
#: Expired invitations are kept briefly so a late tap still explains "expired" instead of "invalid".
INVITATION_GRACE = timedelta(days=7)


class CleanupService:
    def __init__(self, ctx: ServiceContext, assets: AssetService, demo: DemoService | None = None) -> None:
        self.ctx = ctx
        self.assets = assets
        self.demo = demo

    def run(self) -> dict[str, int]:
        now = self.ctx.now()
        return {
            "temporaryRoomsClosed": self.assets.rooms.close_expired(),
            "temporaryRoomsDeleted": self.assets.rooms.purge_ended(),
            "invitations": self._delete_before(INVITATION, "expiresAt", iso(now - INVITATION_GRACE)),
            # Short codes point at an invitation; they go with it.
            "roomCodes": self._delete_before(ROOM_CODE, "expiresAt", iso(now - INVITATION_GRACE)),
            # Milestone 7: shared-group invitations (expired, or used long ago), same grace period.
            "groupInvitations": self._delete_before(GROUP_INVITATION, "expiresAt", iso(now - INVITATION_GRACE)),
            # Direct invitations ("Find a person"), answered or not, once their 30 days and the grace are over.
            "directInvitations": self._delete_before(DIRECT_INVITATION, "expiresAt", iso(now - INVITATION_GRACE)),
            "guestCredentials": self._delete_before(GUEST, "expiresAt", iso(now)),
            "idempotencyRecords": self._delete_before(IDEMPOTENCY, "createdAt", iso(now - IDEMPOTENCY_RETENTION)),
            "rateCounters": self._delete_before(RATE, "expiresAt", iso(now)),
            # Cached AI proposals (milestone 5 §7.2): kept at most SQUAREUP_AI_CACHE_HOURS.
            "receiptIntelligence": self._delete_before(INTELLIGENCE, "expiresAt", iso(now)),
            "receiptImages": self.assets.expire(),
            # Demo workspaces past their week, with every group, receipt, and record in them.
            "demoWorkspaces": self.demo.purge_expired() if self.demo is not None else 0,
        }

    def _delete_before(self, kind: str, field: str, cutoff: str) -> int:
        stale = self.ctx.store.query_before(kind, field, cutoff, limit=500)
        for key, _ in stale:

            def delete(transaction: Transaction, key: str = key) -> None:
                transaction.delete(kind, key)

            self.ctx.store.run_in_transaction(delete)
        return len(stale)
