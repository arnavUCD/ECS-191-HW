# Square Up — Milestone 7

## Real Multi-User P2P Groups

**Status:** Planned implementation contract  
**Starting point:** Milestones 1–5 are implemented. Milestone 4 already provides a locally tested Flask server, Firebase-backed account sessions, remote Live Receipt Rooms, invitation security, revisioned commands, idempotency, and Swift/Python financial parity. Milestone 6 removed the active organization product path, but its current source tree has not yet received a successful post-cleanup build.  
**Primary objective:** Turn Square Up's complete local peer-to-peer ledger into a real shared ledger. Two people signed into different devices must be able to join the same personal group, see the same expenses and balances, participate in receipt splits, and complete the existing payment handoff and recipient-confirmation flow.

> **Product boundary:** This milestone is peer-to-peer only. Do not restore organization groups, budgets, reimbursements, funding sources, approval workflows, treasurer or administrator roles, or business-expense features.

> **Apple boundary:** The App Clip remains paused until the Apple Developer Program decision. Do not create or change an App Clip target, Associated Domains, an AASA file, App Store Connect records, or App Clip invocation. Group invitations must work in the installed full app and must also support copying or pasting a code or link when universal-link entitlements are unavailable.

> **Payment boundary:** Square Up coordinates and records obligations. It does not hold funds, initiate a bank transfer, verify a provider payment, or claim that money moved. PayPal, Apple Cash, Cash App, Zelle, Venmo, cash, and other methods remain handoff destinations only.

---

## 1. Milestone outcome

At the end of Milestone 7:

1. A person can create or recover a Firebase-authenticated Square Up account and maintain a server-backed P2P profile.
2. A signed-in person can create a shared personal group or publish an eligible local personal group.
3. The creator can invite another full-app user through an opaque, revocable invitation.
4. The invited person can preview the invitation, sign in or create an account, and explicitly join.
5. Both devices show the same group members, expenses, audit history, balances, and optimized settlement plan.
6. Either member can add a normal expense, including multiple payers and every existing split method.
7. Receipt scanning, Claude-assisted parsing, item allocation, and the server-backed Live Receipt Room continue to produce one authoritative group expense.
8. Edits, deletes, restores, membership changes, and payment actions synchronize without duplicate financial effects.
9. A payer can choose one of the recipient's available payment destinations, open or copy the appropriate handoff, and report the payment sent.
10. The recipient sees the pending payment on their own device and can confirm, reject, or dispute it. Only confirmation creates a settlement and changes balances.
11. Offline, retry, stale-revision, expired-invitation, and signed-out states are explicit and recoverable.
12. Local-only data remains safe unless the person deliberately publishes a group.

The primary end-to-end proof is:

> Riley creates or publishes a trip group → invites Maya → Maya joins on a second device → Riley adds a multi-payer expense → Maya sees the identical split → they complete a shared receipt → both receive the same settlement plan → Maya opens a payment handoff and reports it sent → Riley confirms it → both balances become identical again.

---

## 2. Locked decisions

### 2.1 One focused product stream

Every active group is a personal P2P group. The creator has limited group-management authority, but not authority over another person's money. Every member can inspect the records and balances that involve the group.

Use only two membership labels when a distinction is needed:

- **Owner:** created or accepted ownership of the group; can edit group details, create/revoke invitations, and manage membership under the safety rules below.
- **Member:** participates in expenses, receipt rooms, balances, and settlements.

Owner is an administrative capability, not a financial approval role. It must never be described as treasurer, administrator, approver, or organization owner.

### 2.2 Server-authoritative shared ledger

Once a group is shared, the server is the authority for:

- group metadata and membership;
- expense revisions, deletion, and restoration;
- receipt-room adoption into the group;
- payment destinations visible to eligible members;
- payment-attempt transitions and confirmed settlements;
- audit events;
- balances and settlement-plan inputs;
- group revision and synchronization cursors.

Clients may calculate previews and display reversible optimistic states, but they may not make a financial change authoritative locally. The server must run the canonical rules and return the resulting authoritative state.

### 2.3 Deterministic money stays deterministic

All money remains integer minor units. The Swift and Python implementations must agree on:

- equal, exact, percentage, shares, and item splits;
- multiple-payer contributions;
- largest-remainder allocation and tie-breaking;
- balance calculation;
- debt simplification;
- payment reservations;
- confirmed settlements;
- expense revision effects.

No LLM calculates an allocation, balance, debt, or settlement. Claude remains limited to proposing receipt fields under the Milestone 5 contract.

### 2.4 Existing infrastructure is extended, not replaced

Reuse the existing:

- Python 3.13, Flask, Gunicorn, App Engine, Datastore, and Cloud Storage server structure;
- Firebase Authentication REST integration and `AccountSession`;
- revision plus idempotency command design from remote Receipt Rooms;
- repository and `LedgerCommand` boundaries in Swift;
- `PaymentAttemptMachine` state model;
- receipt, room, and AI pipelines;
- exact-cent parity fixtures and privacy-safe logging conventions.

Do not introduce a second backend, a second ledger engine, CloudKit, a real-time database, or a new payment SDK in this milestone.

### 2.5 Full accounts for long-lived shared groups

Room-scoped guests remain valid for a single Live Receipt Room, but a guest cannot become a member of a long-lived group without a full account.

- Local-only use may remain device-only.
- Creating, publishing, or joining a shared group requires a recoverable Firebase email/password account.
- Upgrading an existing anonymous Firebase account must preserve its Firebase user ID and existing hosted room ownership.
- Signing into an existing account on another device restores server-backed groups.
- Password-reset support must use Firebase's supported flow; Square Up never handles password-reset tokens itself.

### 2.6 No silent merge or upload

Existing SwiftData groups are local until the person explicitly chooses **Share this group**. Publishing must be transactional, idempotent, and reversible only through an explicit archive/leave flow—not through silent replacement.

Legacy organization records excluded by `LegacyRecords` must never be uploaded, converted, or included in a shared ledger.

### 2.7 Honest payment states

Keep the existing state machine and user meaning:

```text
methodSelected → handoffOpened → reportedSent → confirmed
methodSelected/handoffOpened → reportedSent
reportedSent → rejected | disputed
disputed → confirmed | rejected
eligible pre-confirmation states → cancelled
```

- Opening a payment provider proves nothing.
- `reportedSent` is the payer's claim, not a verified payment.
- Only the recipient's `confirmed` action creates a `Settlement` and changes balances.
- A reported or disputed attempt reserves the obligation so it is not suggested twice.
- Retry or double-tap must never create a second attempt, transition, or settlement.

---

## 3. People, identity, and permissions

### 3.1 Account profile

The server-backed profile contains only what the product needs:

- Firebase user ID as the private account key;
- stable Square Up member ID;
- display name;
- optional initials/avatar presentation data;
- locale and preferred currency hints;
- enabled payment destinations and preferred destination;
- created/updated timestamps.

The Firebase user ID is never used as a visible group identity. Names that collide in a group must be disambiguated using existing UI rules.

### 3.2 Permission matrix

| Action | Owner | Member | Non-member / room guest |
|---|---:|---:|---:|
| View group, expenses, balances, and group activity | Yes | Yes | No |
| Add an expense | Yes | Yes | No |
| Edit/delete/restore own expense | Yes | Yes | No |
| Edit another member's expense | No by default | No | No |
| Open a receipt room for an expense they are recording | Yes | Yes | No |
| Manage own payment destinations | Yes | Yes | No |
| Start a payment they owe | Yes | Yes | No |
| Confirm/reject money owed to them | Yes | Yes | No |
| Edit group name, symbol, description, simplification | Yes | No | No |
| Create/revoke group invitations | Yes | No | No |
| Remove an eligible member | Yes | No | No |
| Transfer ownership | Yes | No | No |
| Delete/archive the group | Yes | No | No |

An expense creator may edit their own expense. If collaborative correction of another person's expense is later desired, it requires a separate proposal/acceptance design and is not part of this milestone.

### 3.3 Membership safety

- A member cannot be removed while they have a non-zero balance, an open payment attempt, or an unresolved receipt-room role.
- Removing a zero-balance member does not erase their historical identity from prior expenses or activity.
- The owner cannot leave until ownership is transferred or the group is archived.
- An invitation grants the right to request membership; it does not expose the full ledger before acceptance.
- A claimed invitation is bound to exactly one Firebase account and cannot be replayed by another account.

---

## 4. Group invitations

### 4.1 Invitation properties

Each group invitation has:

- an unguessable token, stored only as a hash on the server;
- group ID and inviter account ID;
- created, expiry, accepted, and revoked timestamps;
- optional intended seat/member ID when publishing a local group;
- single-use or explicitly configured reuse policy;
- a safe preview containing only group name, symbol, inviter display name, member count, and currency.

Do not put group IDs, names, member names, balances, totals, or account IDs in the URL.

### 4.2 Invitation forms on a free Apple team

Support all of the following without requiring Associated Domains:

- an HTTPS invitation page on the configured server domain;
- an in-app QR code containing the HTTPS invitation;
- a short invitation code that can be copied and pasted in Square Up;
- an installed-app custom URL such as `squp://join-group/<opaque-token>` where appropriate;
- a clear **Open Square Up** or copy-code fallback on the web page.

Do not describe the HTTPS link as a universal link unless the entitlement and domain association actually exist.

### 4.3 Join flow

1. Validate the invitation without revealing ledger contents.
2. Show who invited the person and the safe group preview.
3. Require sign-in or account creation if needed.
4. Let the person confirm the account display name that the group will see.
5. Accept the invitation once with an idempotency key.
6. Bind the account to the intended local member seat when one exists; otherwise create one stable member.
7. Fetch the authoritative group snapshot.
8. Show explicit expired, revoked, already-used, already-a-member, group-archived, and offline states.

---

## 5. Server domain and storage

### 5.1 Required records

Extend the existing storage interfaces with server equivalents for:

- `AccountProfile`
- `SharedGroup`
- `GroupMembership`
- `GroupInvitation`
- `Expense` and immutable `ExpenseRevision`
- `PaymentDestination`
- `PaymentAttempt` and transitions
- `Settlement`
- `AuditEvent`
- `IdempotencyRecord`
- per-group revision/event cursor
- local-group publication/import record

Receipt Rooms and receipt assets stay in their existing records and are linked to the shared group/expense through stable IDs.

### 5.2 Canonical record rules

- Store money as integer minor units plus ISO currency.
- A group has one currency; it locks after the first money record.
- Keep immutable revision history for expenses.
- Deletion is a tombstone with actor, timestamp, and revision; restoration creates a new event.
- Balances are derived from authoritative expenses and confirmed settlements. Never accept a client-supplied balance.
- Settlement plans are derived views, not financial records.
- Every mutation records actor, server timestamp, command ID, prior revision, resulting revision, and an audit event.
- Personally sensitive destination values and receipt assets must not appear in logs or unrestricted DTOs.

### 5.3 Transactions and concurrency

Each mutation must atomically:

1. authenticate the Firebase principal;
2. authorize membership and action;
3. check the expected group revision where required;
4. check or reserve the idempotency key;
5. load the records used for validation;
6. run the deterministic command;
7. write new records, audit event, and resulting revision;
8. store the idempotent response.

On a stale revision, return a structured conflict with the latest group revision and enough state or cursor information for the client to reconcile. Never silently apply a money mutation against an unexpected ledger.

---

## 6. Versioned API

Keep all routes under `/v1` and follow the existing error-envelope, request-ID, authentication, rate-limit, and logging conventions.

The exact internal filenames may follow the existing server layout, but the API must cover these capabilities:

### 6.1 Account and profile

- Fetch current profile and account status.
- Create/update display profile.
- List, create, update, disable, and select a preferred payment destination.
- Return destination values only to their owner or to an authenticated group member with a current payable obligation to that owner.

### 6.2 Groups and sync

- List the signed-in account's active shared groups.
- Create a new shared group.
- Publish/import one eligible local group.
- Fetch a full authoritative group snapshot.
- Fetch changes after an event cursor.
- Submit a revisioned group command.
- Archive a group, leave, remove an eligible member, or transfer ownership.

### 6.3 Invitations

- Create and revoke invitations.
- Fetch a safe invitation preview.
- Accept an invitation as an authenticated account.
- Make acceptance idempotent and resistant to token replay.

### 6.4 Expenses

Commands must support:

- add expense;
- add expense with multiple payers;
- edit expense by creating a revision;
- delete and restore;
- adopt exactly one finalized Receipt Room expense;
- preserve its receipt/allocation snapshot;
- reject any contribution or share total that does not reconcile exactly.

### 6.5 Payments and settlements

Commands must support the existing `PaymentAttemptAction`s with server authorization:

- start/select method;
- mark handoff opened;
- report sent;
- confirm;
- reject;
- dispute;
- cancel.

The server creates exactly one confirmed settlement for an attempt. It must recalculate the payable obligation before starting an attempt and reject an amount greater than the current available obligation.

### 6.6 Response design

Responses must carry:

- schema/API version;
- authoritative group revision;
- event cursor where applicable;
- server timestamp;
- resulting entity or snapshot;
- pending/conflict details through stable codes;
- no displayable raw server error text.

All input has explicit size, count, string-length, and pagination limits.

---

## 7. iOS architecture

### 7.1 Shared ledger repository

Add a remote shared-ledger implementation behind the existing repository boundaries. The feature views and pure calculators must not know whether a local or remote store supplied the snapshot.

The client needs one clear group source mode:

- `local`: existing SwiftData authority;
- `publishing`: a local snapshot is being validated/imported;
- `shared`: server authority with a protected local cache;
- `needsAttention`: publication or synchronization needs a person's decision.

Do not maintain two independently editable authoritative copies of a published group.

### 7.2 Local cache

Cache the last confirmed shared-group snapshot and event cursor so the group remains readable offline. The cache must:

- be namespaced by Firebase account ID;
- be cleared or made inaccessible on sign-out;
- never mix two accounts' data;
- distinguish confirmed server state from local pending presentation;
- keep protected receipt-file references consistent;
- survive ordinary relaunches.

### 7.3 Synchronization

Use revisioned REST and lifecycle-aware polling, extending the proven room approach:

- refresh when a shared group opens;
- poll quickly only while a collaborative screen or pending payment is active;
- back off on stable screens;
- stop polling in the background;
- refresh on foreground and pull-to-refresh;
- apply event pages in order;
- fall back to a full snapshot when a cursor expires or mapping fails.

The transport remains replaceable so push notifications or streaming can be added later without changing the domain or feature views.

### 7.4 Pending and offline actions

Every submitted mutation has a stable client command ID and idempotency key. The UI must distinguish:

- saved;
- sending;
- waiting for connection;
- needs review after conflict;
- failed with a safe retry;
- no longer allowed.

Safe optimistic presentation may be used for ordinary edits, but the app must not present a balance, settlement, membership, or recipient confirmation as final until the server confirms it.

High-consequence actions—accepting an invitation, removing a member, transferring ownership, confirming/rejecting a payment, or finalizing a room—require a live server response. If offline, explain that connection is required instead of pretending success.

Retries reuse the same idempotency key. A conflict screen must explain what changed, preserve the person's draft where possible, and offer **Review latest**, **Try again**, or **Discard my change** as appropriate.

### 7.5 Account experience

Profile must clearly show:

- Device-only account versus recoverable signed-in account.
- Add email/password without losing the existing Firebase identity.
- Sign in on another device.
- Password reset.
- Sign out with an explanation of what remains on the server and what local cached data becomes unavailable.
- The current display name and payment destinations.

Never imply that Firebase or Square Up stores a bank account.

---

## 8. Publishing an existing local group

### 8.1 Eligibility

Before upload, the client must verify:

- the group is an active P2P group visible through the current domain snapshot;
- no excluded legacy organization record or organization-funded expense is present;
- all IDs are stable and unique;
- every expense and settlement reconciles;
- currency rules hold;
- payment attempts have valid transitions;
- protected receipt assets referenced by adopted receipts exist or are explicitly omitted with disclosure;
- the current account can be mapped to exactly one member.

### 8.2 Member-seat binding

Local groups may initially contain named people without accounts. Publication creates pending member seats with stable `MemberID`s. The owner sends a distinct invitation for each seat. Accepting that invitation binds the Firebase account to that seat without changing historical IDs or splits.

Do not guess that an account is a local member from a matching name or email. Binding occurs only through the seat invitation and explicit acceptance.

### 8.3 Import transaction

- Generate one stable publication ID and reuse it on retry.
- Upload a canonical, bounded snapshot plus receipt assets through authorized endpoints.
- Validate the entire snapshot on the server before committing anything.
- Commit group, history, member seats, and import record atomically or leave no active shared group.
- Return the server revision and stable ID mapping.
- Mark the local group `shared` only after the authoritative response is stored.
- A retry returns the original result; it never duplicates the group or expenses.

If publication fails, the original local group remains usable and untouched.

### 8.4 Newly created shared groups

When signed in and online, a person may create a shared group directly. Keep **Create locally** available for demonstrations or offline use, but make the difference clear before creation.

---

## 9. Expenses, receipts, and balances

### 9.1 Expense behavior

All existing composer capabilities must work in shared groups:

- single or multiple payers;
- equal, exact, percentage, and shares splits;
- categories, date, note, and merchant;
- plain-language final review;
- edit as a new revision;
- delete and restore with history.

The server revalidates every amount and member reference. A client never sends a precomputed balance as the source of truth.

### 9.2 Receipt integration

- Capture and Vision OCR remain on device.
- Claude receipt intelligence still goes only through the existing server endpoint and consent rules.
- Confirmed receipt data can open the existing remote Live Receipt Room.
- When the room finalizes, adopt it into the shared group exactly once.
- Both devices receive the final item allocation and frozen receipt snapshot through group sync.
- Receipt asset access remains private to authorized room/group members and keeps its existing retention rules.

### 9.3 Balances and simplification

Derive balances from authoritative expenses and confirmed settlements on the server and reproduce them in Swift for parity checks. Both devices must agree on:

- each member's net position;
- each pairwise obligation when simplification is off;
- the optimized plan when simplification is on;
- amounts reserved by reported/disputed payment attempts;
- amounts remaining available to settle.

Never combine currencies. Never show these obligations as stored cash or a bank balance.

---

## 10. Payment destination and settlement experience

### 10.1 Destination sharing

Members maintain their own destinations. General member lists show provider names only. The destination identifier stays masked until another authenticated member has a current obligation to that recipient and deliberately opens the payment flow.

The server must never expose one member's destination to unrelated accounts, unrelated groups, former members without an active obligation, invitation previews, or room guests.

### 10.2 Payer flow

1. Open the authoritative settlement suggestion.
2. Choose one of the recipient's enabled destinations or cash/other.
3. Create a payment attempt on the server.
4. Open/copy the existing safe handoff.
5. Return to Square Up.
6. Answer **Did you send …?** with no option preselected.
7. On **Yes**, submit `reportSent`; show **Waiting for [recipient]** only after the server accepts it.
8. Allow the payer to cancel before confirmation or dispute after reporting under the existing state rules.

### 10.3 Recipient flow

The recipient sees a clear pending item on Home, Group Detail, Activity, and the payment detail screen. They can:

- confirm receipt, which creates the settlement and changes balances;
- say it was not received, producing `rejected` and making the obligation payable again;
- dispute it, preserving the reservation until resolved.

Every state shows actor and timestamp. Wording must say **reported sent**, **confirmed received**, **not received**, or **disputed**—never **verified by Square Up**.

---

## 11. Activity and audit history

The synchronized append-only timeline includes:

- group created, published, edited, archived;
- member invited, joined, removed, left, or ownership transferred;
- expense added, edited, deleted, and restored;
- Receipt Room opened, finalized, cancelled, or adopted;
- payment method selected, handoff opened, reported sent, confirmed, rejected, disputed, and cancelled.

Each event has a stable ID, actor, server timestamp, entity references, and a structured effect. The interface derives readable text locally. The server does not send arbitrary rich text for display.

Events must avoid putting full payment identifiers, receipt text, notes, or secrets into broadly readable payloads.

---

## 12. Interface and accessibility requirements

Keep the established Square Up design system and native SwiftUI behavior. Required states include:

- Account required / device-only account.
- No shared groups.
- Publishing with progress.
- Invitation preview, sign-in, accept, expired, revoked, already joined, and offline.
- Group loading, cached/offline, refreshing, sending, conflict, and partial failure.
- Member seat waiting for an invitee.
- Expense pending versus saved.
- Payment reported and awaiting this person's response.
- Account/session expired with a sign-in recovery path.

Accessibility remains a release requirement:

- full Dynamic Type including accessibility sizes;
- VoiceOver labels, values, hints, headings, and predictable focus after sync/error changes;
- status communicated by words and symbols, not color alone;
- 44-point targets;
- no truncated names or amounts;
- reduced motion/transparency support;
- announcements for successful join, saved expense, conflict, reported payment, and confirmed settlement;
- accessible alternatives to QR scanning and swipe actions.

Do not add novelty animation at the expense of financial clarity.

---

## 13. Privacy and security

### 13.1 Authorization

- Verify Firebase ID tokens on every account route.
- Re-check group membership for every group read and write.
- Treat invitation access as narrower than membership.
- Room guest credentials never authorize group APIs.
- On sign-out, separate or purge the local cache before another account can sign in.

### 13.2 Sensitive data

- Never log names, emails, payment identifiers, notes, receipt text/images, amounts, balances, invitation tokens, Firebase tokens, credentials, or the Anthropic key.
- Store refresh tokens and room credentials in the Keychain.
- Store invitation tokens and guest credentials hashed server-side.
- Mask payment identifiers by default.
- Use private Cloud Storage objects and authorized retrieval.
- Keep `.env` and generated evaluation responses out of commits and shared archives.

### 13.3 Abuse controls

- Apply bounded request sizes and pagination.
- Rate-limit account creation-adjacent operations, invitation preview/acceptance, invitations, commands, and destination reveals.
- Avoid account enumeration in sign-in/reset copy.
- Revoke invitations when a group is archived or the inviter loses permission.
- Expire unused invitations.
- Reject client timestamps as authoritative ordering.

---

## 14. Failure and conflict policy

| Situation | Required behavior |
|---|---|
| Network lost while reading | Show cached content with **Offline** and last-updated context |
| Network lost before a high-consequence action | Keep the action uncommitted and say connection is required |
| Retry after unknown response | Reuse the same idempotency key and recover the original result |
| Stale expense revision | Preserve the draft, fetch latest, show what changed, require a conscious retry |
| Member removed during draft | Preserve a copy where possible; require the split to be repaired before submission |
| Payment obligation changed | Refuse the stale attempt amount and show the current plan |
| Token refreshed/revoked | Refresh once; if still unauthorized, preserve drafts and request sign-in |
| Cursor expired | Fetch a full snapshot, never guess missing events |
| Local publish rejected | Keep the local group unchanged and explain the exact repairable issue |
| Receipt asset upload fails | Do not create a dangling authoritative expense; retry safely or finalize without the asset only after disclosure |
| Server data fails client mapping | Do not partially apply it; keep last known good state and report a safe recoverable error |

---

## 15. Implementation sequence

### M7.0 — Establish a buildable starting point

- Perform a compilation-only check of the current post-Milestone-6 source.
- Fix only blockers caused by the P2P cleanup before adding new features.
- Do not restore organization code to make old tests compile.
- Record the starting result and any cleanup correction.

### M7.1 — Account and profile foundation

- Complete recoverable Firebase sign-up/sign-in/add-email/sign-out/reset flows.
- Add the server account profile and stable account-to-member mapping.
- Make caches account-scoped.
- Synchronize the person's display name and payment destinations.

### M7.2 — Server shared-ledger core

- Add group, membership, expense revision, payment, settlement, audit, and idempotency storage contracts.
- Implement an in-memory adapter first, then the Datastore adapter with the same contract.
- Port/reuse deterministic commands and add shared Swift/Python fixtures.
- Implement versioned group snapshot and change-cursor APIs.

### M7.3 — Group creation, publication, and invitations

- Create shared groups directly.
- Publish eligible local groups transactionally.
- Bind local named seats through distinct invitations.
- Implement link, QR, code, revoke, expiry, preview, and accept flows without App Clip dependencies.

### M7.4 — Synchronized expenses and receipts

- Add, edit, delete, restore, and multi-payer expense commands.
- Add the remote repository/cache and pending/conflict interface states.
- Connect finalized Receipt Rooms to shared-group adoption exactly once.

### M7.5 — Balances and real two-person settlement confirmation

- Return authoritative balance/plan inputs and verify parity.
- Synchronize payment destinations under the reveal policy.
- Run payment attempts through both devices.
- Make recipient confirmation create one settlement and update both devices.

### M7.6 — Resilience, accessibility, and finish

- Complete offline/cache/retry/conflict/session-expiry behavior.
- Finish the synchronized activity timeline.
- Complete accessibility, empty/loading/error states, privacy audit, and documentation.
- Run the complete validation matrix.

---

## 16. Validation plan

### 16.1 Server

- Domain tests for every split, contribution, balance, simplification, attempt transition, and settlement.
- Storage contract runs against both in-memory and Datastore emulator adapters.
- Authorization matrix for owner, member, non-member, invite holder, and room guest.
- True concurrent-command tests for revision conflicts and exactly-once behavior.
- Invitation replay, expiry, revocation, seat binding, and token-hash tests.
- Publication rollback and retry tests.
- Destination reveal privacy tests.
- Log-redaction, rate-limit, malformed-payload, and size-limit tests.

### 16.2 iOS

- Repository/mapping tests for snapshots, event pages, conflicts, idempotent retry, and cache separation.
- Account-state and sign-out cache tests.
- Publication mapping and legacy-record exclusion tests.
- Pending/offline/conflict view-model tests.
- Snapshot tests for the required UI states, light/dark mode, narrow screens, and accessibility text sizes.
- VoiceOver labels and focus behavior for invitations, payments, and conflicts.

### 16.3 Cross-platform parity

Shared fixtures must cover at least:

- equal, exact, percentage, shares, and item splits;
- multiple payers;
- odd-cent rounding;
- expense edit/delete/restore;
- simplification on and off;
- pending payment reservation;
- confirmation/rejection/dispute/cancellation;
- a finalized Receipt Room adopted exactly once.

### 16.4 End-to-end

- Two Swift clients against the real local HTTP server.
- Two simulators logged into separate Firebase test accounts.
- Create/publish, invite, join, add expense, concurrent edit conflict, receipt finalization, payment handoff simulation, report sent, recipient confirmation, and synchronized final balances.
- Relaunch and account recovery from the protected cache/server.
- Full Milestone 1–5 regression suite after new tests pass.

External provider apps and real money movement are never automated.

---

## 17. Definition of done

Milestone 7 is complete only when:

1. The app builds in Swift 6 strict-concurrency mode with no warnings.
2. The server passes lint, type checks, security scan, dependency audit, and all tests.
3. SwiftLint and SwiftFormat are clean.
4. Two different authenticated accounts on two simulators or devices can share one group and converge on identical state.
5. A local P2P group publishes exactly once without uploading excluded legacy data.
6. Every expense split and multiple-payer contribution is revalidated server-side.
7. Both clients calculate the same balances and settlement plan as the server fixtures.
8. Payment reporting on one device and recipient confirmation on the other creates exactly one settlement and updates both balances.
9. Offline, retry, stale-revision, expired-invite, revoked-invite, and session-expired paths are visibly recoverable.
10. No unauthorized account can read group data, receipt assets, or payment identifiers.
11. Receipt scanning, Claude intelligence, and remote Receipt Rooms still work without regression.
12. Organization features remain absent from active models, UI, APIs, sample data, and documentation.
13. The App Clip remains untouched.
14. The architecture/API/deployment documentation describes what is implemented, what remains local, and what external setup is still required.

If GCP deployment details are not supplied, implementation may be proven against the local server and Datastore emulator, but the status must say **implemented and locally verified, deployment pending** rather than claiming production completion.

---

## 18. External configuration and release gates

The following require the project owner and must not be guessed:

- GCP project ID and explicit approval before creating/deploying cloud resources.
- Firestore in Datastore mode and private Cloud Storage bucket configuration.
- Firebase project configuration, Email/Password and Anonymous providers, and safe test accounts.
- Production server/domain values.
- Apple Developer Program membership for universal links, App Clip, and TestFlight distribution.

Local implementation should continue when these are unavailable. Document the exact commands and values the owner must supply, but do not deploy, enable billing, or alter cloud configuration without authorization.

---

## 19. Explicitly deferred

- App Clip and real invocation through App Clip Codes.
- Associated Domains and production universal links.
- Direct money movement, payment processor integration, bank linking, payment verification, or provider webhooks.
- Organization, club, reimbursement, approval, budget, and accounting features.
- Push-notification entitlements; use in-app polling and refresh for this milestone.
- Contact-book discovery, public usernames, friend graphs, public profiles, or social feeds.
- Web or Android clients.
- Cross-currency groups or currency conversion.
- Recurring bills, subscriptions, personal budgets, or spending analytics.
- Collaborative editing of another member's expense without an explicit proposal workflow.
- Production deployment until the owner supplies and approves the required cloud configuration.

---

## 20. Final implementation report

When implementation finishes, append a dated report to this document containing:

- what was implemented by M7 phase;
- important architecture decisions or justified deviations;
- data migration/publication behavior;
- test commands and exact results;
- two-account end-to-end evidence;
- privacy/security checks;
- manual accessibility/device checks;
- deployment status and required owner actions;
- all remaining work, without describing optional or untested work as complete.

---

## Final implementation report — October 7, 2026

**Status: implemented and locally verified, deployment pending.** Everything below was proven against the
local Flask server with the Datastore emulator and development accounts. It has **not** been run against real
Firebase accounts (no Firebase project is configured) or deployed to GCP (no project ID or approval). The App
Clip, Associated Domains, AASA, App Store Connect, and CloudKit were not touched or added. No organization,
budget, reimbursement, approval, or funding feature was restored.

### What was implemented, by phase

**M7.0 — Starting point.** A compile-only check of the post-cleanup source passed (app and tests, no
warnings). No cleanup fixes were needed.

**M7.1 — Accounts and profile.**

- `AccountSession` now covers: adding an email and password to the anonymous account (same user ID), sign-in
  on another iPhone, password reset (answered the same whether or not the address exists), and sign-out.
- The server has `GET/PUT /v1/account` (profile, display name, a stable profile member ID) and account-owned
  payment destinations with one preferred method.
- Shared-group APIs require a recoverable account (`account_required` otherwise).
- Profile → Account shows the account state, the name others see, and what signing out removes.
- `SharedGroupCache` keeps each account's copies apart (directory named by a hash of the account ID,
  complete-unless-open file protection, excluded from backup) and deletes them at sign-out.

**M7.2 — Server shared-ledger core.**

- `squareup/ledger/` ports the Swift rules: every split method with exact rounding, multiple payers, expense
  validation, the ledger, the direct and simplified settlement plans, and payment-attempt transitions.
- Groups are stored as one aggregate per group plus separate kinds: memberships, 100-event pages, expense
  revisions, invitations, and publications, on both `MemoryStore` and `DatastoreStore`. `MemoryStore` now
  matches Datastore's rule that reads inside a transaction don't see that transaction's writes. That change
  caught two real bugs.
- Commands carry an idempotency key whose fingerprint includes the expected revision. Owner and membership
  commands are revision-strict; expense commands are rebased and revalidated.
- `GET /changes?after=` returns event cursors and answers `cursorExpired` when a client is more than 300
  events behind.
- Three shared parity fixtures (`Shared/parity-fixtures/ledger`) run on both sides.

**M7.3 — Creation, publication, invitations.**

- Shared groups can be created directly (idempotent).
- A local group is published in one transaction with a stable publication ID: a retry returns the same
  group, and an invalid snapshot writes nothing.
- Legacy organization data, open payments, unfinished receipts, invalid expenses, and duplicate IDs are
  refused, both in the app's review and on the server.
- Named seats are bound to accounts through seat invitations.
- Invitation codes are 20 Crockford Base32 characters (100 bits), stored only as hashes. They support a
  QR code, Copy, and Share. The share link is an HTTPS `/g/<code>` page with an `squp://join-group/<code>`
  button; it is not presented as a universal link. Codes can be revoked, expire after 7 days, and show a
  safe preview before single-use acceptance.

**M7.4 — Synchronized expenses and receipts.**

- `SharedGroupLedger` (one `LedgerStore` per shared group) runs every existing screen on server state.
- Add, edit, delete, restore, and multi-payer expenses are revalidated by the server.
- Optimistic previews are used only for expense commands. Offline expense changes queue with the same
  idempotency key, and changes refused after reconnecting wait for a decision.
- A revision conflict shows the current state.
- Finalized receipt rooms (local drafts, or a shared milestone 4 room through `adoptRoom`) become the group's
  expense exactly once.

**M7.5 — Balances and settlement.**

- The server returns its balances and plan, and the client recomputes them and must agree before showing
  them.
- Payment-destination details are revealed only to a member who currently owes that person, and reveals are
  rate-limited.
- `reportedSent` reserves the amount. Reject releases it; dispute keeps it reserved. Only the recipient's
  confirmation creates the one settlement, including under concurrent confirmations.
- Home's "Confirm received" for a shared group acts with the recipient's seat.

**M7.6 — Resilience and finish.**

- Each shared group shows a status bar: up to date, checking, sending, offline with the copy's age, signed
  out, removed, or archived.
- Notices cover conflicts, unreadable changes, and "connection required."
- Polling is quick while a group or payment is open, slower otherwise, with backoff. An app-wide loop
  refreshes Home.
- The activity timeline merges local and shared events.
- Docs were updated: `App/ARCHITECTURE.md` (Milestone 7 section and deviations), `server/README.md`,
  `server/API.md`, `server/.env.example`, `overview.md` (roadmap status), and `App/DEPENDENCIES.md`.

### Architecture decisions and deviations

- **One engine.** Shared groups reuse `LedgerEngine` on a per-group workspace. The server runs a port of the
  same rules and is authoritative. There is no second client ledger engine, no CloudKit, and no real-time
  database.
- **No schema change.** A published local group is set aside with `GroupRecord.kind = "publishedShared"`. It
  is excluded from local reads, and nothing is deleted.
- **Invitation link.** The link is an HTTPS page plus a custom scheme, not a universal link, because
  Associated Domains are out of scope.
- **Sync is polling.** Push is deferred (§19). **Reminders are not implemented.**
- **Parity fixtures.** They cover splits, multiple payers, odd cents, edit/delete/restore, simplification on
  and off, and every payment transition. Receipt-room adoption exactly once is covered by server tests and the
  live two-client test instead of a parity fixture.

### Data migration and publication behavior

Publishing uploads the group, its members, expenses (with revisions and tombstones), confirmed settlements,
and mapped history. Payment drafts, receipt images, and payment methods stay on the iPhone. Legacy
organization groups and organization-funded expenses can't be published: they are excluded from every local
snapshot by `LegacyRecords`, and the server refuses organization fields. Tests cover this:
`SharedGroupMapperTests.legacyExcluded`, `test_legacy_organization_data_and_open_payments_are_refused`, and
the publication request contents check.

### Test commands and results

| Command | Result |
|---|---|
| `SQUAREUP_SKIP_LOCAL_ENV=1 DATASTORE_EMULATOR_HOST=localhost:8081 scripts/check.sh` (server) | **238 passed** on `MemoryStore` and **238 passed** on `DatastoreStore` (2 opt-in live-Claude tests deselected); ruff, ruff format, mypy (71 files), bandit: clean; pip-audit: no known vulnerabilities. 70 of these tests are Milestone 7 (groups, publication, authorization matrix, ledger parity). |
| `xcodebuild build-for-testing` (Swift 6, iPhone 18 Pro, iOS 27) | Succeeded, **0 warnings** |
| `swiftlint lint` / `swiftformat --lint .` | **0 violations** / **0 files need formatting** |
| `xcodebuild test -only-testing:SquareUpTests` | **370 tests in 73 suites passed** (the opt-in live tests skip in this run). The only build output beyond success is a `copypng` note while copying the new snapshot reference PNGs into the test bundle; it is not a compiler warning. |
| `LiveSharedGroupTests` (2 Swift clients, real HTTP server on 8093, emulator) | **4 passed**: `LiveSharedGroupTests` (2) and milestone 4 `LiveServerTests` (2), with `TEST_RUNNER_SQUAREUP_TEST_SERVER=http://127.0.0.1:8093` |
| `SharedGroupUITests`, two simulators at once (iPhone 18 Pro + 18 Pro Max) | **Both passed** (116 s and 126 s) |
| `SquareUpUITests` (M1–5 UI regression) | **Not re-run.** The owner asked to skip it. The M1–5 UI tests were not run after the Milestone 7 changes. |

Fixed while running the full unit regression:

- Four unit tests still expected the pre-P2P sample. They expected a $522.61 Home total and no open sample
  receipt room, but the October P2P sample adds the Driftwood Kitchen room and changes balances. The
  expectations were updated; the app code was not.
- Thirteen snapshot references still showed organization UI ("Organization reimbursements…", reimbursement
  badges, the Design Club row, the "Personal" badge). Each was compared with the new render, then
  re-recorded.
- Both causes came from the P2P cleanup, which did not run tests. Neither was caused by Milestone 7.

New Milestone 7 snapshot references cover:

- a shared group, up to date (dark, light, 320 pt, AX2);
- offline with a change waiting to send (dark, light, AX2);
- the invitation sheet (dark, light, 320 pt, AX2);
- the join preview (dark, light, AX2).

### Two-account end-to-end evidence

- **Two Swift clients, real server** (`LiveSharedGroupTests.primaryProof`). Two dev accounts go through:
  create, invite, preview, join, a multi-payer expense, a stale-revision conflict, receipt adoption (once,
  then an idempotent repeat), payment report, then recipient confirmation. Both accounts end with identical
  balances and exactly one settlement. `publication` covers a lost response with the same publication ID
  returning the same group, then seat binding.
- **Two simulators, real UI** (`SharedGroupUITests`). Riley (iPhone 18 Pro) and Maya (iPhone 18 Pro Max) are
  separate Keychain accounts on the same server:
  1. Riley creates "UI Trip ####" as a shared group and opens Invite (code, QR, Copy, Share; no
     universal-link claim).
  2. Maya opens `squp://join-group/<code>`, sees "Riley invited you", and joins.
  3. Riley adds "Gas", $60.00, split equally.
  4. Maya's group shows "Riley paid $60.00 · you borrowed −$30.00" and "you owe −$30.00".
  5. Maya pays Riley through "Other" and reports it sent. She sees "Reported as sent · waiting for Riley" only
     after the server accepted it.
  6. Riley's Home shows "Maya reported paying you $30.00 through Other. Did you receive it?" Riley confirms.
  7. Maya's group shows "you're all square".
- **Not done:** two **Firebase** accounts. No Firebase project is configured, so this was not simulated and
  remains pending.

### Privacy and security

- A non-member gets the same 404 as a missing group.
- Room guest credentials never open group APIs.
- Group logs carry only salted hashes of group and account IDs plus counts; a test checks this.
- Invitation codes are hashed. The `/g/` page and the preview reveal only the group name and icon, the
  inviter, the member count, the currency, and the expiry.
- Destinations are revealed only to someone who owes, and reveals are rate-limited.
- Request size limits: commands at 256 KB and publication at 1 MB.
- Per-scope rate limits cover account, group read, command, publish, invite, preview, accept, and reveal.

**An incident to report:** early in this milestone, the server test suite's evaluation-runner test imported
`main.py`, which loaded `server/.env`. That made about 20 real Claude API calls, roughly $1, with results
written to a temporary directory. It is fixed: `SQUAREUP_SKIP_LOCAL_ENV=1` and a `conftest.py` guard keep tests
from reading `.env`, and the runner test removes the key after loading. The key itself was never printed,
logged, or copied.

### Accessibility and visual checks

The new screens use Dynamic Type, labels that name the person and amount, and identifiers for UI tests. The
status bar uses icons plus words, never color alone, and the "Discard" button includes the change it discards
in its label. Snapshots at AX2 and 320 pt were reviewed by eye, as were the two-simulator screenshots. Fixed
from that review:

- the offline line now reads "showing the copy from …";
- the compose review note said the expense would sync "once shared groups arrive". It now says whether the
  expense goes to everyone in a shared group or stays on this iPhone;
- Home's "Saved on this iPhone" chip is hidden once the account has shared groups.

Not done: a VoiceOver pass and a physical-device pass.

### Deployment status and what the owner must supply

Nothing was deployed, and no billing or cloud resources were touched. To deploy:

1. A GCP project ID and explicit approval.
2. Firestore in Datastore mode.
3. A private receipt bucket.
4. Firebase on the same or a named project (`SQUAREUP_FIREBASE_PROJECT_ID`), with Email/Password and
   Anonymous providers and two safe test accounts.
5. `SQUAREUP_PUBLIC_BASE_URL` if invitation pages should use a custom origin.
6. Deploy `index.yaml` (it includes the shared-group indexes).
7. In the app's gitignored `Remote.local.xcconfig`: the Firebase Web API key, `SQUAREUP_AUTH_MODE = firebase`,
   and the production host.

Universal links, the App Clip, and TestFlight need the Apple Developer Program.

### Remaining work

- Two-account check with real Firebase accounts on two devices, and account recovery on a second iPhone.
- GCP deployment (after approval).
- Reminders and push notifications (deferred).
- A VoiceOver pass and physical-device checks of the join, invite, and payment flows.
- A ledger parity fixture for receipt-room adoption (it is covered by other tests today).
- Re-running the full M1–5 UI regression (`SquareUpUITests`), skipped at the owner's request.
- Upgrading an existing on-device store from the milestone 5 build with a published group.
