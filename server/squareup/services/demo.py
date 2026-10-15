"""Demo workspaces ("Enter Demo" on the Welcome screen).

Each "Enter Demo" creates one isolated, server-backed workspace for that device: its own demo
account (``demo-<random>``), reached only with a random credential (``Demo <token>``, of which the
server keeps only the SHA-256 hash), and three shared groups of fictional people, expenses, a
confirmed payment, and weeks of history — kept simple: nothing in the seed is waiting for the demo
person. There is no shared demo login: two devices never see or change each other's demo.

The seed is written by replaying ordinary group commands (``GroupService.command``) as the
fictional people, on a clock that steps through the past four weeks. So every balance, settlement
plan, and event is produced and checked by the same rules as real data.

Isolation from real accounts:

- A demo account is never in the account directory, so "Find a person" can't reach it; it can't
  look anyone up, create group invitation links, or join a group with an invitation
  (``AccountService.refuse_demo``).
- Receipt scanning uses the same AI pipeline as everyone, on its own daily budget (per workspace
  and for all demos together) that never counts toward real accounts' AI limits (``IntelligenceService``).
- A demo can host live receipt rooms ("Split with people now"). Guests and other demo accounts may
  join them; real accounts may not, and a demo account can't join a real room
  (``RoomService.require_same_world``). Rooms it hosts are deleted with the workspace.
- The fictional people's seats are bound to random ``sample-<random>`` identifiers that no
  credential can ever present (Firebase chooses real user IDs; development IDs start with ``dev-``).
- Every group the demo account creates or publishes is marked ``demo`` and is deleted with the
  workspace. Nothing here touches real groups, real payment records, or AI limits.

A workspace lasts ``demo_ttl_hours`` (a week) and is then deleted by the hourly cleanup. "Reset
demo data" deletes the workspace's groups and seeds them again; "Leave demo" deletes everything.
"""

from __future__ import annotations

import secrets
import uuid
from dataclasses import dataclass, replace
from datetime import datetime, timedelta
from typing import Any

from ..auth.identity import Principal, new_secret_token, token_hash
from ..domain.errors import DomainError
from ..ledger import group as model
from ..ledger.rules import recompute_split, settlement_plan
from ..logging_setup import log_event, redact
from ..storage.base import (
    ACCOUNT,
    DEMO_SESSION,
    EXPENSE_REVISION,
    GROUP_EVENT_PAGE,
    GROUP_MEMBERSHIP,
    GROUP_RECEIPT,
    SHARED_GROUP,
    Transaction,
)
from .accounts import AccountService
from .context import ServiceContext, iso, parse_iso
from .groups import EVENT_PAGE_SIZE, GroupService
from .rooms import RoomService

#: The demo person's name. Everyone else's is below; every one of them is fictional.
DEMO_NAME = "Avery Lee"
#: Deletions per store transaction (well under Datastore's 500 mutations).
_DELETE_BATCH = 200
#: The seed's times of day are written as Pacific daylight time (UTC−7), where the demo is shown.
_PACIFIC_OFFSET_HOURS = 7


@dataclass(frozen=True)
class _Person:
    name: str
    member_id: str
    uid: str

    @property
    def principal(self) -> Principal:
        return Principal("user", self.uid, recoverable=True, demo=True)


class _SeedClock:
    """The seed's "now": steps forward through the past weeks, never past the real present."""

    def __init__(self, present: datetime) -> None:
        self.present = present
        self.moment = present - timedelta(days=28)

    def __call__(self) -> datetime:
        return self.moment

    def at(self, days_ago: float, hour: int, minute: int = 0) -> None:
        """A Pacific time of day ``days_ago`` days back (each group's steps are written in order),
        always in the past."""
        midnight = (self.present - timedelta(days=days_ago)).replace(hour=0, minute=0, second=0, microsecond=0)
        self.moment = min(midnight + timedelta(hours=hour + _PACIFIC_OFFSET_HOURS, minutes=minute), self.present - timedelta(minutes=5))


class DemoService:
    def __init__(self, ctx: ServiceContext, accounts: AccountService, rooms: RoomService) -> None:
        self.ctx = ctx
        self.accounts = accounts
        self.rooms = rooms

    # MARK: - Credentials

    def resolve(self, token: str) -> Principal | None:
        """The demo account for a credential that exists and hasn't ended, or ``None``."""
        if not token or len(token) > 128:
            return None
        record = self.ctx.store.get(DEMO_SESSION, token_hash(token))
        if record is None or parse_iso(record["expiresAt"]) <= self.ctx.now():
            return None
        return Principal("user", record["subject"], recoverable=True, demo=True)

    @staticmethod
    def require_demo(principal: Principal | None) -> Principal:
        if principal is None or not principal.demo:
            raise DomainError("unauthenticated", "This is only for the demo")
        return principal

    # MARK: - Starting, resetting, and leaving

    def start(self) -> dict[str, Any]:
        """A new workspace for this device: its account, its credential (returned once), its seed."""
        if not self.ctx.config.demo_enabled:
            raise DomainError("demo_unavailable", "The demo isn't available right now")
        token = new_secret_token()
        subject = f"demo-{secrets.token_hex(16)}"
        now = self.ctx.now_iso()
        expires_at = self.ctx.expires_in(self.ctx.config.demo_ttl_hours)
        profile: dict[str, Any] = {
            "memberId": str(uuid.uuid4()),
            "displayName": DEMO_NAME,
            "locale": "en_US",
            "currency": "USD",
            "destinations": [],
            "createdAt": now,
            "updatedAt": now,
        }

        def body_fn(transaction: Transaction) -> None:
            transaction.put(ACCOUNT, subject, profile)
            transaction.put(
                DEMO_SESSION,
                token_hash(token),
                {"subject": subject, "createdAt": now, "expiresAt": expires_at},
                indexed={"subject": subject, "expiresAt": expires_at},
            )

        self.ctx.store.run_in_transaction(body_fn)
        self._seed(subject, profile["memberId"])
        log_event("demo.started", account=redact(subject))
        return {"token": token, "userId": subject, "expiresAt": expires_at, "profile": AccountService.profile_view(profile)}

    def reset(self, principal: Principal | None) -> dict[str, Any]:
        """Back to the original seed: this workspace's groups go, the seed comes back, and the name
        and payment methods return to the demo's own. Nothing outside the workspace is touched."""
        caller = self.require_demo(principal)
        removed = self._delete_groups(caller.subject)
        now = self.ctx.now_iso()

        def body_fn(transaction: Transaction) -> dict[str, Any]:
            profile = transaction.get(ACCOUNT, caller.subject)
            if profile is None:
                raise DomainError("unauthenticated", "This demo ended. Enter the demo again for a fresh copy")
            profile.update({"displayName": DEMO_NAME, "locale": "en_US", "currency": "USD", "destinations": [], "updatedAt": now})
            transaction.put(ACCOUNT, caller.subject, profile)
            return profile

        profile = self.ctx.store.run_in_transaction(body_fn)
        self._seed(caller.subject, profile["memberId"])
        log_event("demo.reset", account=redact(caller.subject), groupsRemoved=removed)
        return {"profile": AccountService.profile_view(profile)}

    def end(self, principal: Principal | None) -> None:
        """ "Leave demo": the workspace, its account, and its credential are deleted now."""
        caller = self.require_demo(principal)
        self._delete_workspace(caller.subject)
        log_event("demo.ended", account=redact(caller.subject))

    def purge_expired(self) -> int:
        """Cleanup: workspaces past their end, with everything in them."""
        expired = self.ctx.store.query_before(DEMO_SESSION, "expiresAt", iso(self.ctx.now()), limit=50)
        for _, record in expired:
            self._delete_workspace(record["subject"])
        return len(expired)

    # MARK: - Deleting

    def _delete_workspace(self, subject: str) -> None:
        self._delete_groups(subject)
        self.rooms.delete_hosted_by(subject)
        keys = [(DEMO_SESSION, key) for key, _ in self.ctx.store.query(DEMO_SESSION, "subject", subject, limit=50)]
        self._delete_all([*keys, (ACCOUNT, subject)])

    def _delete_groups(self, subject: str) -> int:
        """Every demo group this demo account belongs to, with its history, revisions, receipts, and
        memberships. A group not marked ``demo`` is never deleted here (a demo account can't join
        one, so there's none to find)."""
        removed = 0
        for _, membership in self.ctx.store.query(GROUP_MEMBERSHIP, "uid", subject, limit=200):
            group = self.ctx.store.get(SHARED_GROUP, membership["groupId"])
            if group is None:
                self._delete_all([(GROUP_MEMBERSHIP, f"{subject}:{membership['groupId']}")])
                continue
            if not group.get("demo") or not any(member.get("uid") == subject for member in group["members"]):
                continue
            group_id = group["id"]
            keys: list[tuple[str, str]] = [(SHARED_GROUP, group_id)]
            keys += [
                (GROUP_EVENT_PAGE, f"{group_id}:{page:06d}")
                for page in range((group["eventSequence"] + EVENT_PAGE_SIZE - 1) // EVENT_PAGE_SIZE)
            ]
            for expense in group["expenses"]:
                keys += [(EXPENSE_REVISION, f"{group_id}:{expense['id']}:{revision}") for revision in range(1, expense["revision"] + 1)]
            keys += [(GROUP_RECEIPT, f"{group_id}:{entry['id']}") for entry in group.get("receipts", [])]
            keys += [(GROUP_MEMBERSHIP, f"{member['uid']}:{group_id}") for member in group["members"] if member.get("uid")]
            self._delete_all(keys)
            removed += 1
        return removed

    def _delete_all(self, keys: list[tuple[str, str]]) -> None:
        for start in range(0, len(keys), _DELETE_BATCH):
            batch = keys[start : start + _DELETE_BATCH]

            def body_fn(transaction: Transaction, batch: list[tuple[str, str]] = batch) -> None:
                for kind, key in batch:
                    transaction.delete(kind, key)

            self.ctx.store.run_in_transaction(body_fn)

    # MARK: - The seed

    def _seed(self, subject: str, member_id: str) -> None:
        clock = _SeedClock(self.ctx.now())
        seeder = _Seeder(replace(self.ctx, clock=clock), clock)
        you = _Person(DEMO_NAME, member_id, subject)

        def person(name: str) -> _Person:
            return _Person(name, str(uuid.uuid4()), f"sample-{secrets.token_hex(12)}")

        maya, jordan, priya = person("Maya Chen"), person("Jordan Brooks"), person("Priya Natarajan")
        sam, lena, dev = person("Sam Okafor"), person("Lena Fischer"), person("Dev Kapoor")
        riley, noor = person("Riley Park"), person("Noor Haddad")

        # Apartment 4B: roommates sharing household costs, with one payment to you already confirmed.
        clock.at(27, 18, 10)
        apartment = seeder.group(you, "Apartment 4B", "house.fill", "Sample household · fictional roommates and amounts")
        clock.at(27, 19, 2)
        seeder.join(apartment, maya)
        clock.at(27, 20, 45)
        seeder.join(apartment, jordan)
        clock.at(26, 9, 30)
        seeder.join(apartment, priya)
        everyone = [you, maya, jordan, priya]
        clock.at(25, 17, 40)
        seeder.expense(apartment, you, "Costco run", 18_640, everyone, category="groceries", merchant="Costco")
        clock.at(22, 8, 15)
        seeder.expense(apartment, jordan, "Internet bill", 6_500, everyone, category="utilities")
        clock.at(18, 21, 5)
        seeder.expense(apartment, maya, "Electricity bill", 14_218, everyone, category="utilities")
        clock.at(15, 12, 20)
        seeder.expense(apartment, priya, "Cleaning supplies", 3_872, everyone, category="supplies")
        clock.at(11, 20, 30)
        seeder.expense(apartment, you, "Pizza night", 5_400, [you, maya, jordan], category="food", shares={you: 1, maya: 2, jordan: 1})
        clock.at(6, 10, 0)
        seeder.pay(apartment, jordan, you, "venmo", confirm=True, reference="Thanks for the Costco run!")

        # Tahoe Ski Weekend: a trip where you're owed the most.
        clock.at(20, 11, 0)
        tahoe = seeder.group(you, "Tahoe Ski Weekend", "mountain.2.fill", "Sample trip · fictional friends and amounts")
        clock.at(20, 11, 20)
        seeder.join(tahoe, sam)
        clock.at(20, 13, 5)
        seeder.join(tahoe, lena)
        clock.at(19, 9, 45)
        seeder.join(tahoe, dev)
        trip = [you, sam, lena, dev]
        clock.at(17, 16, 0)
        seeder.expense(tahoe, you, "Cabin — 2 nights", 64_000, trip, category="travel")
        clock.at(9, 8, 30)
        seeder.expense(tahoe, sam, "Lift tickets", 46_800, [you, sam, dev], category="entertainment")
        clock.at(9, 18, 50)
        seeder.expense(tahoe, lena, "Gas & parking", 8_450, trip, category="transport")

        # Friday Dinner Crew: dinners out, where you owe a little (try Settle up).
        clock.at(16, 19, 0)
        dinner = seeder.group(you, "Friday Dinner Crew", "fork.knife", "Sample group · fictional friends and amounts")
        clock.at(16, 19, 30)
        seeder.join(dinner, maya)
        clock.at(16, 20, 10)
        seeder.join(dinner, riley)
        clock.at(15, 18, 0)
        seeder.join(dinner, noor)
        friends = [you, maya, riley, noor]
        clock.at(14, 21, 30)
        seeder.expense(dinner, riley, "Taqueria Los Altos", 8_640, friends, category="food", merchant="Taqueria Los Altos")
        clock.at(7, 22, 10)
        seeder.expense(
            dinner,
            maya,
            "Sushi Kaito",
            13_280,
            friends,
            category="food",
            merchant="Sushi Kaito",
            exact={you: 3_240, maya: 4_120, riley: 2_960, noor: 2_960},
        )
        clock.at(2, 21, 45)
        seeder.expense(dinner, noor, "Bowling", 7_200, friends, category="entertainment")


class _Seeder:
    """Ordinary group commands, sent as each fictional person on the seed clock."""

    def __init__(self, ctx: ServiceContext, clock: _SeedClock) -> None:
        self.ctx = ctx
        self.clock = clock
        self.groups = GroupService(ctx, AccountService(ctx))

    def group(self, owner: _Person, name: str, symbol: str, details: str) -> str:
        group_id = str(uuid.uuid4())
        self.groups.create(owner.principal, {"groupId": group_id, "name": name, "details": details, "symbol": symbol, "currency": "USD"})
        return group_id

    def join(self, group_id: str, person: _Person) -> None:
        """Seats a fictional person exactly as accepting an invitation would (``memberJoined``)."""
        now = self.ctx.now_iso()

        def body_fn(transaction: Transaction) -> None:
            group = GroupService._load(transaction, group_id)
            seat = model.new_seat(person.member_id, person.name, now, uid=person.uid)
            group["members"].append(seat)
            self.groups._record_join(transaction, group, seat, person.uid, now)

        self.ctx.store.run_in_transaction(body_fn)

    def _send(self, group_id: str, person: _Person, kind: str, payload: dict[str, Any]) -> dict[str, Any]:
        envelope = {
            "commandId": str(uuid.uuid4()),
            "idempotencyKey": uuid.uuid4().hex,
            "expectedRevision": self._revision(group_id),
            "type": kind,
            "payload": payload,
        }
        response: dict[str, Any] = self.groups.command(person.principal, group_id, envelope)
        return response

    def _revision(self, group_id: str) -> int:
        group = self.ctx.store.get(SHARED_GROUP, group_id)
        return int(group["revision"]) if group else 0

    def expense(
        self,
        group_id: str,
        payer: _Person,
        title: str,
        total: int,
        people: list[_Person],
        *,
        category: str,
        merchant: str | None = None,
        shares: dict[_Person, int] | None = None,
        exact: dict[_Person, int] | None = None,
    ) -> None:
        split: dict[str, Any] | None
        if exact is not None:
            method, split = "exact", None
            allocations = [(person.member_id, amount) for person, amount in exact.items()]
        elif shares is not None:
            method = "shares"
            split = {"method": "shares", "weights": [{"memberId": p.member_id, "weight": w} for p, w in shares.items()]}
            allocations = recompute_split(total, split)
        else:
            method = "equal"
            split = {"method": "equal", "participants": [person.member_id for person in people]}
            allocations = recompute_split(total, split)
        expense = {
            "id": str(uuid.uuid4()),
            "title": title,
            "merchant": merchant,
            "date": self.ctx.now_iso(),
            "total": total,
            "currency": "USD",
            "category": category,
            "splitMethod": method,
            "payments": [{"memberId": payer.member_id, "amount": total}],
            "allocations": [{"memberId": member, "amount": amount} for member, amount in allocations if amount],
        }
        payload: dict[str, Any] = {"expense": expense}
        if split is not None:
            payload["split"] = split
        self._send(group_id, payer, "addExpense", payload)

    def pay(self, group_id: str, payer: _Person, recipient: _Person, provider: str, *, confirm: bool, reference: str | None = None) -> None:
        """What the payer owes the recipient in the plan now: started, opened, reported — and, with
        ``confirm``, confirmed by the recipient an hour later. Skipped if the plan has no such payment."""
        group = self.ctx.store.get(SHARED_GROUP, group_id)
        if group is None:
            return
        plan = settlement_plan(
            model.member_ids(group), group["expenses"], group["settlements"], group["attempts"], bool(group["simplifiesDebts"])
        )
        payment = plan.payment(payer.member_id, recipient.member_id)
        if payment is None:
            return
        attempt_id = str(uuid.uuid4())
        self._send(
            group_id,
            payer,
            "startPayment",
            {"attemptId": attempt_id, "recipientId": recipient.member_id, "amount": payment.amount, "provider": provider},
        )
        self._advance(group_id, payer, attempt_id, "openHandoff", minutes=3)
        report: dict[str, Any] = {"attemptId": attempt_id, "action": "reportSent"}
        if reference:
            report["externalReference"] = reference[: model.MAX_REFERENCE]
        self.clock.moment += timedelta(minutes=2)
        self._send(group_id, payer, "advancePayment", report)
        if confirm:
            self._advance(group_id, recipient, attempt_id, "confirm", minutes=55)

    def _advance(self, group_id: str, person: _Person, attempt_id: str, action: str, *, minutes: int) -> None:
        self.clock.moment += timedelta(minutes=minutes)
        self._send(group_id, person, "advancePayment", {"attemptId": attempt_id, "action": action})
