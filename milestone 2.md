# Square Up — Milestone 2

## Core Personal Groups and Universal P2P Settlement

**Status:** Approved direction  
**Primary audience:** Product, design, and implementation  
**Starting point:** Milestone 1 is complete: the Swift 6 app builds with strict concurrency, has no warnings, and the existing unit, snapshot, and UI tests pass.

> **Scope change (October 2026):** Square Up is now peer-to-peer only. Organization groups, roles, budgets, approvals, organization funding, and reimbursement management were removed from the product and are no longer planned. This milestone's P2P results below are unchanged. References to organization features are historical. See `overview.md` and `App/ARCHITECTURE.md` (P2P scope and legacy compatibility).

---

## 1. Milestone outcome

Milestone 2 completes Square Up's first full personal-group experience. A user must be able to create a group, add members, add and revise shared expenses, understand everyone's balances, receive an optimized settlement plan, choose a payment method accepted by the recipient, leave Square Up to complete the payment when supported, and return to record and confirm the settlement.

The product remains **non-custodial** in this milestone:

- Square Up does not hold user money.
- Square Up does not collect bank credentials.
- Square Up does not pretend that opening another app completed a payment.
- Existing services such as Apple Cash, PayPal, Cash App, Zelle, and Venmo move the money.
- Square Up calculates, coordinates, records, confirms, and explains the settlement.

Personal groups and person-to-person settlement are the priority for this milestone. *(At the time, organization features were planned for later. They have since been removed from scope.)*

---

## 2. Product position

Square Up is the universal coordination layer above the payment methods people already use.

The first release should answer four questions clearly:

1. Who owes whom?
2. What is the smallest sensible set of payments that makes the group square?
3. Which payment methods does each recipient accept?
4. Has each payment been reported and confirmed?

Square Up should make settling a group feel like one coherent flow even when the actual money moves through multiple external services.

---

## 3. Decisions finalized for Milestone 2

### 3.1 Personal groups come first

Milestone 2 focuses on friends, trips, meals, roommates, families, and other informal groups. Organization-specific roles, budgets, approvals, and reimbursement processing were deferred at the time and have since been removed from scope.

### 3.2 External wallets move money

The initial settlement screen shows the payment methods configured by the person receiving money. The payer chooses one of those methods.

The first supported set is:

- Apple Cash
- PayPal / PayPal.Me
- Cash App
- Zelle
- Venmo
- Cash
- Other/manual payment

Support for a method means that Square Up can represent it safely. It does not mean that Square Up has a financial partnership with that provider.

### 3.3 Each integration uses the strongest officially supported handoff

Square Up classifies payment methods into three integration levels:

1. **Prefilled handoff:** recipient and/or amount can be included in an official link.
2. **App or website handoff:** Square Up can open an official destination, but the payer may need to enter remaining information.
3. **Guided manual handoff:** Square Up copies the relevant details and explains how to finish the transfer.

Square Up must not depend on undocumented URL schemes. Universal links are preferred because they can open an installed app and fall back to the provider's website.

### 3.4 Confirmation is part of the product

Opening Messages or a payment app is not payment confirmation. A payment is final in Square Up only after the recipient confirms receipt, or after a future provider integration supplies authoritative confirmation.

### 3.5 Pending payments must not create duplicate recommendations

After a payer reports a payment as sent, the amount is pending rather than settled. It is excluded from new optimized-payment suggestions while confirmation is outstanding, preventing Square Up from telling the payer to pay twice. If the recipient rejects it or the payer cancels it, the obligation becomes payable again.

---

## 4. Scope inherited from the original Milestone 2 plan

The original Milestone 2 was the **core personal flow**. All of it remains in scope:

- Create, edit, and view personal groups.
- Add, identify, and manage group members.
- Navigate from the Groups list to Group Detail.
- Provide Expenses, Balances, and Activity segments in Group Detail.
- Add expenses through the existing staged composer.
- Support equal, exact, percentage, and share-based splits.
- Support multiple payers.
- Show live reconciliation and prevent invalid expenses from being saved.
- Calculate per-person balances deterministically.
- Simplify debts into an optimized payment plan.
- Explain optimized payments in plain language.
- Record, track, and confirm settlements.
- Edit and delete expenses without destroying their audit history.
- Show expense, edit, deletion, and settlement events in Activity.
- Use a strong success animation and haptic only after a settlement is genuinely confirmed.

The new multi-wallet payment direction extends the settlement part of this plan; it does not replace the group and expense work.

---

## 5. User stories

### Groups

- As a user, I can create a personal group with a name, description, optional visual identity, and default currency.
- As a user, I can add members with clear full names and optional disambiguating handles.
- As a user, I can edit group details and membership without losing financial history.
- As a user, I can always identify myself and every other participant.

### Expenses

- As a user, I can add an expense and select its payer or payers.
- As a user, I can choose who participated and how the cost is divided.
- As a user, I can see that the payments and allocations reconcile exactly before saving.
- As a user, I can edit a mistake and understand how it changed balances.
- As a user, I can delete an expense while retaining an audit record that the expense once existed and who removed it.

### Balances

- As a user, I can see how much I owe or should receive.
- As a user, I can inspect every member's position and understand which expenses created it.
- As a user, I can switch debt simplification on or off and see the effect.
- As a user, I can see the number of transfers before and after optimization.

### Payments

- As a recipient, I can add the payment methods I accept and choose a preferred method.
- As a payer, I see only the methods the recipient has enabled.
- As a payer, I can open the best available handoff or copy the exact information I need.
- As a payer, I can report that I sent the payment without Square Up claiming it is verified.
- As a recipient, I can confirm or reject a reported payment.
- As every group member, I can see settlement events in the group's activity history.

---

## 6. Group creation and membership

### Required group fields

- Group name
- Default currency
- Creator/current user

### Optional group fields

- Description
- Group photo, emoji, color, or generated group mark
- Initial members

### Membership rules

- Full names are the primary identity label.
- Optional handles disambiguate people who share a name.
- Avatars or initials accompany member names in financial decisions.
- A member with financial history cannot simply disappear from old records.
- Removing a member prevents future participation but retains past expenses, settlements, and activity.
- A group cannot change its currency after financial records exist unless a future explicit migration is implemented.
- Group creation must support empty, loading, validation-error, persistence-error, and successful states.

### Initial payment setup

Payment methods are optional during account/profile setup. Users can skip them and add them later. We should not block group participation because a user has not configured a payment method.

The onboarding prompt should be concise:

> How can friends pay you?

Users can choose one or more providers, add the corresponding destination, and select a preferred method.

Contacts permission must not be requested during launch. It may be requested only when a user deliberately chooses a contact-assisted action.

---

## 7. Group Detail

Group Detail is the center of the personal experience.

### Header

- Group identity and name
- Participant stack with accessible names
- Active user's net position in plain language
- Persistent Add Expense action
- Settle Up action when unresolved balances exist

### Expenses segment

- Chronological expenses
- Payer identity
- Total and active user's share
- Category and date
- Clear distinction between active and deleted records
- Tap through to full expense detail

### Balances segment

- Active user's net balance first
- Every member's amount owed or receivable
- Direct balance detail explaining the contributing records
- Simplification control with an explanation of what changes and what does not
- Entry into the optimized settlement plan

### Activity segment

- Expense created
- Expense edited
- Expense deleted
- Group created or edited
- Member added or removed
- Settlement initiated
- Payment reported sent
- Payment confirmed, rejected, cancelled, or disputed

Activity events use human language and identify the actor, amount, method, and time where relevant.

---

## 8. Expense lifecycle

### Creation

Continue using the existing staged Add Expense experience:

1. Amount and description
2. Payers, participants, and split
3. Human-readable review and confirmation

Every save must satisfy the existing deterministic invariants:

- Payment shares equal the total.
- Allocation shares equal the member-funded amount.
- All amounts share the expense currency.
- Rounding reconciles to the cent using the existing largest-remainder behavior.

### Supported split methods

- Equal
- Exact amount
- Percentage
- Shares

Itemized splits remain reserved for later milestones (delivered in Milestone 3). Hybrid organization/member splits have since been removed from scope.

### Multiple payers

The UI must allow more than one member to contribute to the paid amount. Each contribution is explicit, and all payer contributions must add to the expense total.

### Editing

- Expense Detail includes Edit.
- Edit starts from the saved values rather than a blank draft.
- The same validation rules apply as creation.
- Before saving, show a summary of the material changes.
- An edit produces a durable activity event containing the actor, time, and changed field names.
- Old financial values must remain available to the audit mechanism even though only the current revision drives balances.

### Deleting

- Deletion requires confirmation and explains the balance impact.
- Deletion should be implemented as a soft deletion or tombstone, not silent physical disappearance.
- Deleted expenses no longer affect current balances.
- Activity retains who deleted the expense and when.
- Undo may be offered immediately when safe.

---

## 9. Balance and optimization rules

### Authoritative balance

Confirmed balances continue to be derived from valid expenses and confirmed settlements. The UI never stores or manually edits a balance as an independent source of truth.

### Simplification

Debt simplification should:

- Preserve every member's net position.
- Minimize or substantially reduce the number of transfers.
- Never change what the group collectively owes.
- Produce deterministic output for the same ledger.
- Use stable tie-breaking so the plan does not change randomly between launches.
- Operate only within one currency.

### Plain-language plan

Examples:

- `Alex pays Maya $27.83.`
- `Jordan pays Sam $12.40.`
- `2 payments instead of 5.`

The UI should explain that simplification changes who pays whom, not the amount each person ultimately owes or receives.

### Pending-payment adjustment

The confirmed ledger and the actionable settlement plan are related but distinct:

- **Confirmed ledger balance:** expenses minus confirmed settlements.
- **Available-to-settle balance:** confirmed ledger balance adjusted by payments reported sent and awaiting confirmation.

An initiated handoff has no balance effect. A reported-sent payment reserves that obligation in the available settlement plan. A confirmed payment becomes a real settlement. A rejected or cancelled payment releases the reservation.

---

## 10. Payment profile

Each member may have zero or more `PaymentDestination` records.

### Conceptual fields

- Stable identifier
- Owner member identifier
- Provider type
- Display label
- Destination type: phone, email, username, URL, QR payload, or instructions
- Destination value
- Preferred flag
- Enabled flag
- Creation and update timestamps

### Provider-specific input

#### Apple Cash

- Phone number or email used for iMessage
- Square Up cannot verify that the contact is enrolled in Apple Cash
- Never claim Apple Cash availability solely because an email or phone number was entered

#### PayPal

- PayPal.Me username or validated `paypal.me` URL
- Square Up may create the amount-specific PayPal.Me URL from a validated username
- Reject unrelated hosts and malformed links

#### Cash App

- `$Cashtag` and/or an official personal payment link supplied by the user
- Prefer storing the official link provided by the recipient
- Do not invent an undocumented custom URL scheme

#### Zelle

- Zelle-enrolled US phone number or email
- Optional official Zelle QR link when available from the user's financial institution
- Square Up cannot verify enrollment
- QR-link hosts and payloads must be validated before opening

#### Venmo

- Username
- Use only a currently documented official link if one is available at implementation time
- Otherwise copy the username, amount, and note and provide a guided handoff

#### Cash

- No identifier required
- Optional instructions such as `Cash in person`

#### Other/manual

- User-provided label and short instructions
- No executable arbitrary scripts or unvalidated custom URL schemes

### Display and privacy

- The recipient controls which methods are enabled.
- The recipient chooses the preferred method.
- The preferred enabled method appears first.
- Identifiers are masked in general profile and group views.
- Reveal the needed destination only to a payer with an active obligation to that recipient.
- Never include payment destinations in logs, analytics, crash reports, widgets, notifications, or screenshots generated for testing.
- Provide a warning before changing or deleting a destination involved in a pending payment.

---

## 11. Paying screen

### Header

The screen leads with the obligation:

> Pay Maya $27.83  
> Weekend Trip

It also shows the recipient's full name, avatar, and optional handle so the payer can verify the person before leaving Square Up.

### Payment-method list

Only enabled methods configured by the recipient are shown. Each row contains:

- Provider name
- Masked destination
- Capability label
- Primary action

Recommended capability labels:

- `Amount prepared`
- `Opens provider`
- `Copy and continue`
- `Record manually`

Do not say `Verified`, `Instant`, or `Secure` unless Square Up can substantiate that provider-specific claim.

### Example

| Method | Information | Square Up action |
|---|---|---|
| Apple Cash | `•••-•••-4821` | Copy amount and open Messages |
| PayPal | `paypal.me/maya` | Open amount-specific PayPal link |
| Cash App | `$MayaR` | Open the recipient-provided payment link or copy details |
| Zelle | `m•••@ucdavis.edu` | Copy recipient and amount; show QR/link if supplied |
| Venmo | `@maya-r` | Use official link if supported; otherwise copy details |
| Cash | `In person` | Record a manual payment |

### No configured method

If the recipient has no payment methods:

- Offer `Ask Maya how they want to be paid` using the system share or Messages composer.
- Offer `Record a manual payment`.
- Do not block the settlement plan.

---

## 12. Provider handoff behavior

### General rules

1. Create a pending `PaymentAttempt` before leaving Square Up.
2. Store the chosen method, amount, payer, recipient, group, and settlement-plan reference.
3. Prefer an HTTPS universal link supplied or documented by the provider.
4. Use a custom URL scheme only when it is officially documented and deliberately allowed.
5. If opening fails, retain the attempt and show copy/share/manual alternatives.
6. Returning to Square Up prompts for an explicit result.
7. Successfully opening another app means only `handoff opened`, never `payment succeeded`.

### Return prompt

When Square Up becomes active after an attempted handoff, show:

> Did you send $27.83 to Maya?

Actions:

- `Yes, I sent it`
- `Not yet`
- `Cancel attempt`

Do not preselect the affirmative action.

### Apple Cash

Square Up can present the standard Messages composer with the recipient and a prepared message. Apple does not expose a public third-party API for preselecting Apple Cash, inserting the Apple Cash transfer amount, sending it, or reading its transaction status.

Apple Cash flow:

1. The payer selects Apple Cash.
2. Square Up copies the amount.
3. Square Up opens Messages addressed to the recipient.
4. The message body says, for example: `Square Up: Paying you $27.83 for Weekend Trip. Settlement SU-4821.`
5. Square Up explains: `In Messages, tap +, choose Apple Cash, paste $27.83, review, and send.`
6. The payer returns and reports the result.

The action label is `Continue in Messages`, not `Pay now`.

### PayPal

If the recipient supplied a valid PayPal.Me username or URL, Square Up opens an amount-specific HTTPS link. Square Up still treats the result as external and unverified unless a future supported API provides authoritative status.

### Cash App

If the recipient supplied an official payment link, open it. Otherwise copy the `$Cashtag`, amount, and memo and show the Cash App instructions. Square Up must not construct an undocumented deep link.

### Zelle

Zelle is commonly provided inside a user's bank or credit-union app, so Square Up cannot reliably open one universal Zelle application.

Square Up should:

- Copy the recipient's enrolled email or phone number.
- Copy the amount and provide a concise memo.
- Show the official Zelle QR link if the recipient supplied one.
- Offer the Zelle bank-finder/QR destination when valid.
- Remind the payer to verify the displayed recipient name in their banking app.

### Venmo

Use an official supported handoff only if it is documented and verified during implementation. Otherwise copy the username, amount, and note. Merchant checkout integrations must not be misrepresented as personal P2P APIs.

### Cash and other methods

Square Up shows the recipient's instructions, asks the payer to report completion, and uses the same recipient-confirmation lifecycle.

---

## 13. Settlement state machine

The milestone introduces an explicit payment-attempt lifecycle.

### States

```text
unpaid
  -> methodSelected
  -> handoffOpened
  -> reportedSent
  -> confirmed
```

Alternative transitions:

```text
methodSelected -> cancelled
handoffOpened -> cancelled
reportedSent -> rejected
reportedSent -> disputed
reportedSent -> cancelled (only before recipient confirmation)
disputed -> confirmed
disputed -> rejected
```

### State meanings

- **Unpaid:** no payment attempt affects the settlement plan.
- **Method selected:** a draft attempt exists; balances are unchanged.
- **Handoff opened:** an external destination was opened; balances are unchanged.
- **Reported sent:** the payer says payment was sent. The amount is reserved out of new suggestions but not part of the confirmed ledger.
- **Confirmed:** the recipient acknowledges receipt. The settlement becomes authoritative and updates balances.
- **Rejected:** the recipient says funds were not received. The obligation returns to the settlement plan.
- **Disputed:** the members disagree or need to investigate. Show it separately and do not describe anyone as settled.
- **Cancelled:** the attempt is closed without financial effect.

### Confirmation copy

Recipient prompt:

> Alex reported paying you $27.83 through Apple Cash. Did you receive it?

Actions:

- `Confirm received`
- `Not received`
- `Review later`

### Success treatment

- Reporting payment uses a restrained acknowledgment haptic.
- Recipient confirmation uses the strongest settlement success haptic and the approved success animation.
- Reduce Motion receives a short opacity/scale transition with the same informational result.
- No confetti or success language appears merely because another app opened.

---

## 14. Data-model changes

The current `Settlement` represents a completed external payment. Preserve that clear meaning and add separate models for destinations and attempts rather than overloading it with every transient state.

### `PaymentProviderKind`

Cases:

- `appleCash`
- `paypal`
- `cashApp`
- `zelle`
- `venmo`
- `cash`
- `other`

### `PaymentDestination`

Represents how a member accepts payment. It includes the fields defined in the Payment Profile section and a type-safe destination value.

### `PaymentAttempt`

Conceptual fields:

- Identifier
- Group identifier
- Settlement-plan identifier or stable obligation identifier
- Payer member identifier
- Recipient member identifier
- Payment-destination identifier
- Provider kind
- Amount in minor units and currency
- State
- User-visible memo
- Created, handoff-opened, reported, confirmed, rejected, disputed, cancelled timestamps
- Actor responsible for each state change
- Optional external reference supplied manually or by a future provider

### `Settlement`

When an attempt becomes confirmed, create or finalize exactly one `Settlement`. The operation must be idempotent so repeated confirmation cannot reduce a balance twice.

Extend the current settlement representation only as necessary with:

- Provider kind
- Source payment-attempt identifier
- Confirmation timestamp
- Confirming member identifier

### Audit event

Financial mutations should produce append-only activity events. Expense edits and deletions require revision/tombstone information sufficient to explain what changed without using deleted records in current balances.

### Repository boundaries

Add narrow protocols rather than exposing SwiftData directly:

- `PaymentDestinationRepository`
- `PaymentAttemptRepository`
- Expanded `GroupRepository` for create/update/member operations
- Expanded `ExpenseRepository` for update/delete/history
- Expanded `SettlementRepository` for confirmation-safe finalization

Both in-memory and SwiftData stores must implement identical rules so tests exercise the real domain behavior.

---

## 15. Local prototype versus multi-device behavior

Milestone 2 must build the complete state model even if the first implementation is local.

### Required local prototype

- Configure payment methods for sample members.
- Open supported external destinations on a physical device.
- Record payer-reported status.
- Provide a deterministic recipient-confirmation screen using the local sample identities.
- Persist all states across relaunch.
- Demonstrate confirmation, rejection, cancellation, and dispute.

### Future server-backed behavior

When authentication and networking arrive, the same repository interfaces will support:

- Recipient confirmation on the recipient's device
- Push notifications
- Server-authoritative audit events
- Signed links into a specific settlement
- Provider webhooks where a future provider supports them

The local milestone must not fake push delivery or call local simulation provider verification.

---

## 16. Privacy, security, and trust

- Payment handles are sensitive personal information.
- Do not store bank usernames, passwords, routing numbers, card numbers, Apple Cash balances, or payment-app credentials.
- Do not request Contacts access until the user explicitly invokes a contact feature.
- Do not log payment handles, phone numbers, emails, QR payloads, memos containing personal data, or full external URLs.
- Validate all externally opened URLs against provider-specific HTTPS host allowlists.
- Reject `javascript:`, `data:`, file, and unrecognized custom schemes.
- Display the recipient's full identity before handoff.
- Warn that Zelle and similar irreversible methods should be used only with people the user knows.
- Avoid storing payment screenshots in the first release.
- Provide controls to disable or replace a payment destination.
- Preserve financial history when a destination is removed, but redact the destination from ordinary historical display when no longer needed.
- Use privacy-aware OSLog interpolation for all related diagnostics.

---

## 17. Accessibility and UI quality

- Every provider row has a text name; never communicate a method using only a logo or color.
- VoiceOver reads recipient, amount, method, destination state, and action in a logical order.
- Masked identifiers must remain distinguishable under VoiceOver without exposing them unnecessarily.
- Dynamic Type must not truncate names, amounts, or the primary settlement action.
- Provider lists must work on narrow screens and accessibility text sizes.
- Confirmation and rejection must not be adjacent ambiguous icon-only actions.
- Statuses use text and symbols, not color alone.
- All payment handoffs have loading, failure, unavailable, offline, and cancellation states.
- Use official brand assets only when their usage terms are satisfied; otherwise use clear text and neutral system symbols.
- The app must remain understandable with Reduce Motion, Reduce Transparency, Increased Contrast, and Voice Control enabled.

---

## 18. Error and edge cases

The milestone must handle:

- Recipient has no payment method.
- Preferred method is disabled.
- Malformed or unsupported payment link.
- External app is not installed.
- Universal link opens a web fallback.
- User returns without paying.
- User opens two handoffs for the same obligation.
- User reports the same payment twice.
- Recipient rejects the payment.
- Payer and recipient dispute the result.
- Expense is edited while a related payment is pending.
- Expense is deleted while a related payment is pending.
- Member is removed while owing or receiving money.
- Multiple members have the same display name.
- Payment amount is zero or negative.
- Payment exceeds the current obligation.
- Currency differs from the group currency.
- Group becomes fully settled while an old draft handoff remains.
- App is killed while an external provider is open.
- Device is offline when the user records or confirms a payment.

Financially conflicting edits must require the pending attempt to be cancelled, rejected, or explicitly reconciled before the underlying obligation is changed.

---

## 19. Testing requirements

### Unit tests

- Group creation and membership invariants
- Expense creation, editing, soft deletion, and revision history
- Equal, exact, percentage, shares, and multiple-payer reconciliation
- Balance calculation before and after edits/deletions
- Deterministic debt simplification
- Tie-breaking in optimized plans
- Pending-payment adjustment
- Every allowed and forbidden settlement-state transition
- Idempotent confirmation
- Provider destination validation
- URL host and scheme allowlists
- Masking of phone, email, username, and URL destinations
- No sensitive values in diagnostic descriptions

### Persistence tests

- Payment destinations survive relaunch.
- Attempts survive relaunch in every nonterminal state.
- Confirmation creates one settlement only.
- Rejection releases the pending reservation.
- Soft-deleted expenses stop affecting balances but retain history.
- In-memory and SwiftData behavior match.

### Snapshot tests

- Payment screen with all methods
- Preferred method first
- No-method empty state
- Malformed/unavailable method state
- Reported-sent state
- Recipient-confirmation state
- Rejected and disputed states
- Light and dark appearance
- Narrow screen
- Accessibility Dynamic Type
- Increased Contrast and Reduce Transparency where testable

### UI tests

- Create group and members
- Add and edit an expense
- Delete an expense and verify balance/history
- Open Settle Up and inspect optimized payments
- Select each provider type without claiming success
- Return from a simulated handoff and report payment
- Confirm as recipient and verify balance/activity
- Reject as recipient and verify obligation returns

### Physical-device checks

At least one real iPhone test must verify:

- Messages composer handoff
- HTTPS universal-link behavior
- App-not-installed fallback
- Clipboard and privacy behavior
- Returning to Square Up after an external app
- Haptics
- VoiceOver focus order

External-provider payments should use trivial test amounts only when permitted by the provider and participants. Automated tests must not move real money.

---

## 20. Implementation sequence

### M2.1 — Group management

- Create and edit personal groups.
- Add and remove members while preserving history.
- Replace the current Create Group placeholder.
- Complete Group Detail navigation and segments.
- Add tests and accessibility coverage.

### M2.2 — Expense lifecycle

- Complete multiple-payer entry.
- Add expense detail.
- Add edit with change summary.
- Add soft deletion and audit history.
- Verify all split methods and persistence paths.

### M2.3 — Balances and optimized plan

- Implement deterministic simplification.
- Show before/after transfer counts.
- Explain the plan in plain language.
- Add pending-payment adjustment behavior.

### M2.4 — Payment profiles

- Add profile editing for accepted methods.
- Add validation, masking, ordering, privacy, and preferred method.
- Seed realistic sample payment profiles.

### M2.5 — Paying screen and handoffs

- Build the provider list and capability labels.
- Implement Apple Cash guided Messages handoff.
- Implement PayPal.Me amount links.
- Implement recipient-provided Cash App links.
- Implement Zelle copy/QR/link guidance.
- Implement safe Venmo fallback.
- Implement cash and manual recording.
- Add external-open failure and return prompts.

### M2.6 — Confirmation and activity

- Implement the payment-attempt state machine.
- Add recipient confirmation, rejection, dispute, and cancellation.
- Finalize settlement idempotently.
- Add settlement events to Activity.
- Add the approved confirmation animation and haptic.

### M2.7 — Quality gate

- Run strict-concurrency build with zero warnings.
- Run formatting and lint checks with zero findings.
- Run the full unit, persistence, snapshot, and UI suites.
- Perform physical-device and accessibility review.
- Update `ARCHITECTURE.md`, `DEPENDENCIES.md`, and the relevant product documentation to record implemented decisions and deviations.

---

## 21. Definition of done

Milestone 2 is complete only when all of the following are true:

1. A user can create and edit a personal group.
2. Members remain unmistakably identified throughout financial actions.
3. A user can add a valid expense with any supported manual split and multiple payers.
4. A user can edit or delete an expense with an understandable audit record.
5. Balances remain exact after every mutation.
6. Square Up produces a deterministic optimized payment plan.
7. A recipient can configure multiple accepted payment methods and a preferred method.
8. A payer sees only the recipient's enabled methods.
9. Supported handoffs open safely, and every unsupported handoff has a useful copy/share fallback.
10. Apple Cash opens a prepared Messages conversation without claiming to control Apple Cash.
11. An external app opening never marks a balance settled.
12. Payer-reported payments enter a visible pending state.
13. Pending payments do not produce duplicate payment suggestions.
14. Recipient confirmation finalizes exactly one settlement.
15. Rejection or cancellation restores the obligation.
16. Activity explains every important expense and settlement change.
17. The strongest success treatment occurs only after confirmation.
18. Sensitive payment identifiers do not appear in logs or unrelated UI.
19. The app builds in Swift 6 strict-concurrency mode without warnings.
20. All existing and new tests pass.

---

## 22. Demonstration script

The milestone demonstration should use a personal dinner or trip group:

1. Create `Weekend Trip`.
2. Add Alex, Maya, Jordan, and Sam.
3. Add expenses using equal, exact, and share-based splits.
4. Edit one expense and delete another.
5. Open Balances and explain each member's net position.
6. Turn on simplification and show fewer recommended payments.
7. Select `Alex pays Maya $27.83`.
8. Show that Maya accepts Apple Cash, PayPal, Cash App, and Zelle.
9. Choose Apple Cash and open the prepared Messages conversation.
10. Return to Square Up and select `Yes, I sent it`.
11. Show the payment as awaiting Maya's confirmation and absent from duplicate suggestions.
12. Confirm receipt as Maya in the local prototype.
13. Show the final balance, settlement animation, haptic, and activity history.
14. Repeat a second attempt with rejection to demonstrate that the obligation safely returns.

---

## 23. Deferred beyond Milestone 2

- Square Up holding stored balances
- Direct access to bank credentials
- Production embedded P2P money movement
- Automatic Apple Cash status or transaction-history access
- Undocumented payment-app URL schemes
- Provider-verified settlement webhooks
- Production KYC/AML onboarding
- Moov or another embedded P2P provider in production
- Multi-device authentication and synchronization
- Push notifications
- Organization roles, budgets, approvals, and reimbursements *(since removed from scope)*
- Live Receipt Room and itemized receipt collaboration
- Multi-currency conversion
- Accounting integrations

The architecture should leave room for a future `PaymentProvider` implementation. A future approved provider can replace manual confirmation with authoritative status without rewriting groups, expenses, balances, or the paying screen.

---

## 24. Reference documentation

- Apple MessageUI: <https://developer.apple.com/documentation/MessageUI/MFMessageComposeViewController>
- Apple Cash user flow: <https://support.apple.com/en-us/105013>
- Apple external URL handling: <https://developer.apple.com/documentation/uikit/uiapplication/open(_:options:completionhandler:)>
- Apple URL availability: <https://developer.apple.com/documentation/uikit/uiapplication/canopenurl(_:)>
- PayPal.Me: <https://www.paypal.com/paypalme/>
- Cash App send/request guidance: <https://cash.app/learn/getting-started/how-to-send-and-receive-money>
- Zelle QR guidance: <https://www.zellepay.com/faq/how-do-i-use-zelle-qr-code>
- Moov wallets for future evaluation: <https://docs.moov.io/guides/money-movement/wallets/>
- Moov capabilities for future evaluation: <https://docs.moov.io/guides/accounts/capabilities/reference/>


---
---

# Implementation status (Milestone 2)

> This section records what was built. It was added on October 5, 2026, after the requirements above, which are unchanged. The engineering details are in `App/ARCHITECTURE.md`, and the dependency decisions are in `App/DEPENDENCIES.md`.

**Overall:** every M2.1–M2.6 stage is implemented and covered by automated tests. M2.7 is complete except the physical-iPhone review, which can't run in the simulator.

## Verified quality gate (simulator, Xcode 27 / iOS 27 SDK)

| Check | Result |
|---|---|
| Swift 6 language mode, strict concurrency, clean build | **0 warnings** |
| Unit, persistence-parity, and snapshot tests (Swift Testing) | **208 passed**, repeated on a second clean run |
| UI tests (XCUITest; 6 new in M2 and 3 from M1) | **9 passed** |
| Snapshot references (all re-recorded and reviewed by eye) | 42 (20 new payment-state references) |
| SwiftLint | **0 findings** |
| SwiftFormat `--lint` | **0 files need formatting** |
| Runtime dependencies added | **None** |

## Stage status

| Stage | Status | Notes |
|---|---|---|
| M2.1 Group management | Done | The real create/edit editor replaces the placeholder. It covers name, details, symbol, and currency (locked once financial records exist). You can add people by typing them or picking from your other groups. Member removal is a soft removal, so history keeps the name. The Group Detail segments are Expenses, Balances, and Activity. |
| M2.2 Expense lifecycle | Done | Multiple-payer entry that must reconcile exactly. Expense detail with payers, split, and history. Edit shows a per-member change summary and keeps every revision. Delete is a soft tombstone with an impact message and Undo/Restore. All split methods use one engine path in both stores. |
| M2.3 Balances and optimized plan | Done | Simplification is deterministic: exact matches first, then largest-first, with ties broken by membership order. Shows before/after transfer counts and the plan in plain language. Pending reports are held out of suggestions, and confirmed ledger balances are shown separately. |
| M2.4 Payment profiles | Done | "Getting paid" in Profile lets you add, edit, disable, set preferred, and remove methods. Each provider has its own validation, and values are masked in shared UI. Debug descriptions are redacted. Sample profiles are seeded. |
| M2.5 Paying screen and handoffs | Done | Shows only the recipient's enabled methods, preferred first, each with a capability label. Apple Cash opens a prepared Messages composer with the amount copied. PayPal.Me links include the amount. Cash App uses the recipient's own link or a copy flow. Zelle offers copy, a validated link, and bank guidance. Venmo is a copy flow. Cash and other methods are recorded manually. Includes open-failure handling and a return prompt that persists. |
| M2.6 Confirmation and activity | Done | An explicit `PaymentAttempt` state machine with role checks and idempotent repeats. The recipient can confirm, reject, or dispute; the payer can cancel. Only confirmation writes a `Settlement`, and exactly one per attempt. Durable audit events feed Activity. The mesh, draw-on checkmark, and haptic play only after confirmation. |
| M2.7 Quality gate | Done except the device review | See the table above. `ARCHITECTURE.md` and `DEPENDENCIES.md` are updated. |

## Definition of done (§21)

| # | Requirement | Status | Evidence |
|---|---|---|---|
| 1 | Create and edit a personal group | ✅ | `GroupAndExpenseEngineTests`, `FeatureModelTests`, and UI `testCreateGroupWithMembers` |
| 2 | Members unmistakable | ✅ | Avatars plus full names on every payment card and timeline; the payer and recipient are both shown; snapshots |
| 3 | Any manual split and multiple payers | ✅ | Engine and composer tests; multi-payer reconciliation |
| 4 | Edit/delete with an audit record | ✅ | Revision history, tombstones, and UI `testEditThenDeleteExpenseKeepsHistory` |
| 5 | Balances exact after every mutation | ✅ | Integer-cent engine; expected nets checked after edit, delete, restore, confirm, and reject in the engine and lifecycle tests |
| 6 | Deterministic optimized plan | ✅ | Property test (nets preserved, exact amounts moved, repeat runs identical) plus exact-match-first and tie-break tests |
| 7 | Multiple methods and a preferred one | ✅ | Destination rule tests (single preferred, promotion when one is removed) |
| 8 | Payer sees only enabled methods | ✅ | `PayingSummary` tests and snapshots |
| 9 | Safe opens with copy/share fallbacks | ✅ | HTTPS allowlist tests; every provider plan has copy items; the no-method state includes ShareLink |
| 10 | Apple Cash via Messages without control claims | ✅ | Handoff plan tests; copy reviewed in snapshots |
| 11 | Opening an app never settles | ✅ | `handoffOpened` creates no settlement (machine and UI `testProviderHandoffNeverClaimsSuccess`) |
| 12 | Reported → visible pending | ✅ | "Awaiting confirmation" state on the plan, Home, and Activity |
| 13 | No duplicate suggestions | ✅ | Pending-adjustment planner tests; seeded Tahoe attempt |
| 14 | Confirmation finalizes exactly one settlement | ✅ | Idempotency tests in both stores |
| 15 | Rejection/cancellation restores the obligation | ✅ | Lifecycle tests, relaunch test, and UI `testRejectionRestoresObligation` |
| 16 | Activity explains changes | ✅ | `AuditEventPresenter` for group, expense, and payment events |
| 17 | Strongest success only after confirmation | ✅ | `SettlementSuccessView` is presented only from the confirm path |
| 18 | No sensitive identifiers in logs or unrelated UI | ✅ | Masking and redaction tests; `Log.payments` logs only the provider kind |
| 19 | Swift 6 strict concurrency, no warnings | ✅ | Clean build |
| 20 | All tests pass | ✅ | 208 + 9 |

## Deliberate deviations and interpretations

- **Venmo is copy-and-continue only.** No officially documented consumer pay link or universal link was found for personal P2P, and §12 forbids undocumented schemes. The app copies the username, amount, and memo.
- **Square Up never builds Cash App links.** It opens a `cash.app` link only when the recipient supplied it and it passed the allowlist. Otherwise it copies the $Cashtag.
- **Member removal is blocked while the member has a non-zero balance or an open payment attempt.** This is an interpretation that keeps balances exact. The editor explains why in plain language.
- **Percentage and share splits reopen as exact amounts when edited.** The stored expense keeps only the reconciled allocations. The original split method is still shown in history.
- **New M2 records are stored as JSON payloads in SwiftData.** The payment-destination, attempt, and audit-event records use JSON payloads with indexed keys. This keeps the schema reviewable and lets the in-memory and SwiftData stores share one engine.
- **The M1 → M2 on-disk migration is lightweight and additive but untested against a real M1 store file.** Fresh installs and relaunch are tested.
- **The local prototype uses sample-identity switching.** "Respond as {name} (sample identity)" is labeled as a local prototype and never presented as another device.
- **Settle up is hidden for organization groups**, which are out of scope for M2. *(October 2026: organization groups were removed; Settle up now appears for every group.)*
- **Increased Contrast is snapshot-tested. Reduce Transparency is not**, because the snapshot harness can't toggle that trait. Glass surfaces use system materials that respond to it.

## Remaining physical-device and external-provider verification (§19)

These haven't been done yet and need a real iPhone with trivial amounts only and participants' consent:

- [ ] Messages composer handoff with a real recipient; choosing Apple Cash manually in Messages
- [ ] PayPal.Me and Zelle HTTPS universal links opening the installed app vs. Safari
- [ ] App-not-installed fallback (Safari page plus copy rows)
- [ ] Clipboard: local-only, two-minute expiry, paste banner behavior
- [ ] Returning to Square Up after an external app shows the "Did you send it?" prompt
- [ ] The `settle` Core Haptics pattern on hardware
- [ ] VoiceOver focus order on Paying, Handoff, Payment, and Success screens; Voice Control names
- [ ] Opening an M1-era on-disk store with the M2 build

## Demonstration script (§22) readiness

All 14 steps can be performed in the simulator with the seeded data. Step 9 (the Messages composer) needs a device or a simulator with Messages configured. With `-SUSimulateHandoffs`, the flow continues to the return prompt without opening another app.
