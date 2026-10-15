# Square Up

## Product overview

Square Up helps friends, roommates, couples, families, and travel groups scan receipts, divide shared expenses, track balances, and settle up through the payment apps they already use.

Its everyday experience follows the familiar Splitwise model. People create a group, record who paid and who shared, see who owes whom, and record payments until everyone is square. Square Up adds what Splitwise lacks:

- AI-assisted receipt interpretation.
- Live Receipt Rooms, where everyone claims their own items.
- Exact allocation of tax, tip, fees, and discounts.
- Optimized settlement.
- Hand-off to each person's preferred payment app.
- An interface designed for clarity and accessibility.

Square Up is the working product name. It reflects the product's goal: helping people resolve shared expenses until everyone is square.

Square Up is peer-to-peer. It coordinates money between people who share costs informally. It is not a tool for organizations, budgets, or business expenses, and it never holds or moves money itself.

## Problem statement

Sharing costs with other people is common and still awkward:

- One person pays the restaurant, the rental, or the groceries.
- Someone works out the split by hand, in a calculator, or in a spreadsheet, often late and often wrong.
- An itemized receipt is slow to divide fairly. Who had the salmon, who shared the appetizer, and how should tax and tip follow?
- Over a trip or a month of shared rent, the running totals become hard to follow. People lose track of who owes whom.
- Paying back is its own friction. Friends use different payment apps, usernames get mistyped, and nobody is sure whether a payment was sent or received.
- People hesitate to ask for money, so balances stay open and resentment builds.

The underlying problem is not arithmetic alone. Groups need a fast, trustworthy, shared record of what was spent, how it was divided, and what is left to settle, plus a low-friction way to settle it.

## Existing solutions and opportunity

Splitwise established the model: groups, expenses, flexible splits, balances, and settlements. It is widely used, especially by students. But its interface feels dated and dense. Itemized receipts must still be divided by hand. Paying back happens entirely outside the app, with no guidance. Its free tier limits everyday use.

Square Up keeps the model people already understand and improves the slowest, most error-prone moments:

- Turning a receipt into a correct split.
- Agreeing on who had what.
- Getting paid back.

There is no restrictive free group or expense limit.

## Target users

- College roommates sharing rent, utilities, and groceries.
- Friends sharing dinners, nights out, and tickets.
- Travel groups sharing rentals, gas, parking, and activities.
- Couples sharing household costs.
- Families splitting gifts, trips, and household expenses.
- Friends organizing informal events together, such as a birthday dinner or a weekend away.

Everyone in a group is an equal member. There are no financial roles, approvals, or administrators of other people's money. The person who creates a group can manage its name, details, currency, and members, and every member can see the expenses and balances they're part of.

## Product principles

- **Clarity before spectacle.** Every amount, payer, and direction of debt is unmistakable. Visual effects never make a number harder to read.
- **One expense, one understandable record.** Who paid, who shared, how it was divided, the receipt, and every later edit stay connected.
- **Deterministic money.** Balances, splits, and settlements come from exact integer arithmetic in tested code. They are never produced by AI and never cached as UI state.
- **AI proposes; people confirm.** AI can read a receipt or draft an expense. Nothing becomes an expense, a split, or a payment without a person's review.
- **Honest about payments.** Square Up prepares and records payments. It never claims a payment happened that only a person reported, and it never claims to have moved money.
- **Accessible by default.** VoiceOver, Dynamic Type, contrast, and reduced motion are release requirements.
- **Focused core loop.** Record, understand, and settle shared expenses. Square Up is not a bank, a budgeting tool, or accounting software.

## Personal groups

A group holds the people who share costs: an apartment, a trip, a dinner crew, a couple, a family. Each group has:

- A name, an optional description, and a symbol.
- A default currency. It locks once money has been recorded, so totals never silently change meaning.
- Members, shown with full names and avatars. People who share a first name are disambiguated.
- An optional setting to simplify debts.

Members can be added at any time. A member can be removed only when they have no balance and no open payment. Past expenses keep showing them, so history never rewrites itself.

Every group is a personal, peer-to-peer group. Creating a group never asks what kind of group it is.

## Expense recording

An expense records:

- Description and optional merchant.
- Date.
- Total and currency.
- Who paid. One person or several.
- Who shared, and how it was divided.
- Category, chosen or suggested.
- Optional note.
- Receipt images and the item-level allocation, when it came from a receipt.

Expenses are entered in a short, staged flow: amount, then people, then split, then a final review. The review shows a plain-language sentence ("Riley paid $640 for the beach house, split equally among 4 people"). A natural-language shortcut can prepare the same draft from a sentence such as "I paid $80 for dinner with Maya and Jordan", which the person then reviews field by field.

Editing an expense creates a new revision. The previous version stays in the history. Deleting an expense leaves a restorable record, so mistakes can be undone without losing the audit trail.

## Multiple payers

When more than one person paid, for example two cards on one bill, each payer's contribution is recorded. Contributions must add up to the total exactly. Each person's balance reflects what they paid minus what they owe, so both payers are owed in proportion to what they put in.

## Split methods

- **Equally** among chosen people.
- **Exact amounts** per person.
- **Percentages** that must total 100%.
- **Shares**, such as 2 : 1 : 1 : 2 for people who stayed more nights or ate more.
- **By item**, created by finalizing a receipt or a Live Receipt Room.

Every split must reconcile to the total before it can be saved. Indivisible cents are distributed by a documented rule: largest remainder, with ties broken by participant order. The affected people can see the result.

## Receipt scanning

A receipt can come from:

- the camera, using the system document scanner with edge detection, perspective correction, retakes, and multiple pages;
- the photo library, through the system picker, without library-wide permission;
- a bundled fictional sample receipt for demonstrations.

Square Up keeps the untouched original, an oriented and cropped working page, and a thumbnail. Pages can be rotated, cropped, reordered, replaced, or removed during review. Image-quality checks warn about blur, darkness, or cut-off text but never block the person.

## Vision and Claude receipt processing

Processing happens in named stages: Preparing receipt, Reading text, Understanding items, and Checking totals. Each stage can be cancelled.

1. **Vision OCR always runs on the iPhone.** It produces recognized text with positions and confidence.
2. **Claude interprets the receipt when the person has agreed.** The app sends a metadata-free copy of the page and Vision's evidence to the Square Up server, and only the server calls Claude. The server returns structured fields (merchant, date, items, quantities, tax, tip, fees, discounts, total), each linked to the place on the receipt it came from.
3. **Deterministic validation checks everything twice.** The server validates the schema and arithmetic. The app validates again before showing anything. Values Claude read but Vision did not see are flagged for checking. Amounts that couldn't be read, or totals that were worked out rather than printed, must be resolved by the person.
4. **Automatic fallback.** If AI is turned off, the person is offline, the server is unavailable, or the response fails validation, the on-device parser prepares the same editable draft. The person sees a calm note, not an error.

The first time a receipt could use AI, Square Up explains what is sent, to whom, and for how long. The person chooses between automatic processing and on-device only, and can change the choice in Profile at any time.

## Human review

Nothing from a scan becomes an expense automatically. The review screen shows the receipt image beside every extracted value. Selecting a value highlights where it came from on the receipt. Every field is labelled **Looks good**, **Check this**, or **Needs resolution**, with an icon and words, not color alone. People can:

- edit, merge, split, move, add, or delete lines;
- add a labelled adjustment;
- change charges.

A live reconciliation shows whether items, tax, tip, fees, and discounts add up to the printed total, and by exactly how much they don't. Square Up never alters a printed amount to force a match.

Only after the person confirms the receipt can they split it directly or open a Live Receipt Room.

## Live Receipt Rooms

A Live Receipt Room turns a confirmed receipt into a shared workspace, so the payer doesn't have to reconstruct everyone's order.

1. The payer confirms the receipt and chooses the participants from the group.
2. The payer shares a QR code or link. Friends join on their own phones, and invitees without a group seat can join as guests.
3. Each person claims what they had. Shared items are split among their claimants.
4. Tax, tip, fees, and discounts are allocated by a visible rule.
5. Unclaimed, partly claimed, and disputed items stay highlighted until resolved.
6. The payer reviews a per-person breakdown and finalizes. The room becomes one itemized expense in the group.

Only the payer (the host) can edit the receipt, resolve disputes, change charge rules, or finalize. Participants can claim, share, unclaim, dispute, and mark their part reviewed. Every room keeps its own history of who did what, and the finalized expense keeps a frozen snapshot of the allocation, so the split stays explainable after later edits.

On one device, a room can also be previewed with sample participants, clearly labelled as a local prototype.

## Item claims and shared items

- **Mine** claims an item fully.
- **Share** joins an item with others. By default it divides equally among the claimants.
- A shared item can instead be divided by **shares** or **exact amounts**, with a live "adds up" check and a disclosure of any rounding.
- **Dispute** flags an item ("I didn't have this") for the host to resolve rather than silently leaving it.
- Claims can be undone at any time while the room is open.

If the host edits the receipt after people have claimed items, only claims on items whose amount changed or that were removed are cleared. The affected people are asked to review.

## Tax, tip, fees, discounts, and rounding

Each charge is allocated by a rule the room displays:

- **Proportional** to each person's item subtotal (the default).
- **Equally** among everyone or a chosen group.
- By **shares** or **exact amounts**.
- **Payer keeps it**, with confirmation.

Discounts and refunds reduce shares by the same rules. All allocation uses integer minor units with the largest-remainder rule, so the per-person totals always add up to the receipt total exactly. Any cent moved by rounding is shown.

## Balances

For each group, Square Up computes each person's net position from authoritative records: everything they paid, minus everything they owe, adjusted by confirmed payments. Home shows the person's overall position across groups in plain language ("You're owed $884.61" / "You owe $29.69") and lists the groups needing attention, people they owe first. Amounts are never shown as a stored bank-like balance, because Square Up tracks obligations, not money.

Balances in different currencies are never added together. Groups in another currency are counted and listed separately.

## Debt simplification

When simplification is on, Square Up suggests the fewest payments that clear the group. It matches exact pairs first, then pays the largest debts to the largest credits, using at most one fewer payment than there are people. Every person's net position stays exactly the same. The plan explains itself in plain language and shows how many transfers it saves. With simplification off, people repay the specific people they owe.

## Payment destinations

Each person can list how friends can pay them:

- **Apple Cash**: phone or email.
- **PayPal**: PayPal.Me username.
- **Cash App**: $Cashtag, or the person's own cash.app link.
- **Zelle**: phone or email.
- **Venmo**: username.
- **Cash or other**: written instructions.

Each destination is validated for its provider, and one can be marked preferred. Identifiers are masked in general views and revealed only to their owner and to someone who currently owes them.

## Payment-app handoff

Settle Up prepares a payment through the recipient's chosen method, with an honest description of what each method can do:

- **Amount prepared.** PayPal.Me opens with the amount and currency.
- **Opens provider.** Messages opens to the recipient for Apple Cash. The recipient's own Cash App link opens, or Zelle's bank finder.
- **Copy and continue.** The username, amount, and memo are copied for Venmo or Zelle.
- **Record manually.** For cash and other methods.

Square Up opens only HTTPS links on an allowlist of provider domains, and never undocumented app schemes. Copied details expire from the clipboard after two minutes. Square Up never says a payment is "verified", "instant", or "secure", because it can't know.

## Recording and confirming payments

A payment becomes part of the record in two steps:

1. **The payer reports it.** On returning from the payment app, Square Up asks "Did you send $27.83 to Maya?" with three choices and none preselected. A reported payment is set aside so it is never suggested twice.
2. **The recipient confirms it.** Only the recipient's confirmation turns it into a settlement that changes balances. The recipient can also say they didn't receive it, which opens a dispute. The payer can cancel a payment before it is confirmed.

Cash or any other payment can also be recorded directly. While a payment is waiting for confirmation, edits that would change the amounts it depends on are paused until it is resolved, so a confirmed payment never settles a stale balance.

## Activity history

Each group has an append-only history:

- expenses added, edited, deleted, and restored;
- membership changes;
- receipt rooms opened, finalized, and cancelled;
- payments reported, confirmed, disputed, and cancelled.

Each entry says who did it and when. A cross-group Activity tab shows everything relevant to the person, grouped by day and filterable by expenses and payments, with each entry's effect on them: lent, borrowed, paid back, or received.

## Local and server architecture

### Client

- Native iOS app in Swift 6 and SwiftUI, with strict concurrency and the Observation framework.
- Every money change is a command run by one pure ledger engine. Both the in-memory store (tests and previews) and the SwiftData store (the app) use it, so the same rules apply everywhere.
- SwiftData stores the ledger with a versioned schema and migration plan. Receipt images are protected files referenced by the records.
- On-device frameworks: Vision, VisionKit, PhotosUI, Foundation Models (when available, for quick entry), Core Haptics, App Intents, and TipKit.
- Today, each person's groups, expenses, and balances live on their own device, with seeded sample people for demonstration.

### Server

- Python 3.13 and Flask on Google App Engine Standard (Gunicorn).
- Firestore in Datastore mode, and a private Cloud Storage bucket for receipt images.
- Firebase Authentication. An anonymous account is created when hosting, and it can be upgraded to email and password.
- Room-scoped guest credentials for invitees.
- The server is authoritative for shared Live Receipt Rooms. It runs a Python port of the receipt allocation engine, and shared fixtures prove both engines agree.
- Each command carries the revision it was based on and an idempotency key. Stale commands are refused with the current state, and retries never apply twice.
- Clients poll while a room is on screen.
- The server also hosts receipt intelligence. It is the only place the Claude API key and model are configured, with strict schemas, deterministic validation, per-account and project rate limits, and a short result cache.
- Image access requires authorization. Invitation tokens and guest credentials are stored only as hashes.

The server has been built and tested locally against the Datastore emulator. It has not been deployed.

## Privacy

- **Minimum data to AI.** Receipt AI receives only the receipt image (re-encoded without location or camera metadata), the OCR evidence, locale, and a currency hint. It never receives group names, members, balances, payment details, or other expenses.
- **AI consent.** It is off until the person agrees and can be withdrawn. Withdrawing consent deletes the person's cached results on the server.
- **What Anthropic keeps.** The server forwards images and evidence to Anthropic and keeps them only in memory for the request. Only the structured result is cached, for up to 24 hours. Under Anthropic's published API policy, inputs and outputs are deleted within 30 days and are not used for training.
- **Receipt images.** Shared images are private and served only to room members. They are deleted 30 days after a room ends. On the device, a host can remove an expense's receipt images while keeping its allocation.
- **Payment identifiers.** These are masked by default and never logged.
- **Logs.** Logs on device and server never include names, amounts, item text, notes, images, tokens, or credentials.
- **Secrets.** No secret ships in the app. Credentials are stored in the Keychain.
- **Permissions.** Camera permission is requested only when the person scans. Importing from Photos needs no library permission.

## Accessibility

- Every screen supports VoiceOver with meaningful labels and order. Claims and reconciliation changes are announced.
- Dynamic Type is supported through accessibility sizes, and layouts adapt rather than truncate money.
- Meaning never depends on color. Owing and being owed differ in wording, sign, and icon. Review states pair icons with words.
- Contrast is verified in light and dark appearances, including increased contrast.
- Reduce Motion and Reduce Transparency are respected. Haptics always accompany a visible change.
- Gestures such as zoom, crop, and reorder have button or adjustable alternatives. Touch targets are at least 44 points.
- People who share a name are distinguished by more than initials.

## Distribution

- The app currently installs from Xcode onto the developer's iPhone and simulators.
- TestFlight is the planned distribution for testers. It requires Apple Developer Program access.
- The App Clip for joining a Live Receipt Room without installing the app is **paused** pending the Apple Developer Program decision. No App Clip target, Associated Domains, or App Store Connect configuration exists. Invitations open in the full app through links, QR codes, or a pasted link.

## Product boundaries

Square Up is not:

- a bank, wallet, or payment processor;
- a budgeting or personal-finance tracker;
- accounting, tax, or business-expense software;
- an autonomous decision-maker about money.

## Success measures

- Time to create a group and record a first expense without help.
- Time from photographing a receipt to a confirmed itemized split.
- Corrections needed after receipt processing, and silent errors (target: none).
- Share of Live Receipt Rooms finalized without unresolved items.
- Time from expense to settled balance.
- Whether people can explain who owes whom from the screen alone.

## Roadmap

Delivered:

- Personal groups.
- Expenses with multiple payers and every split method.
- Balances and debt simplification.
- Payment destinations, handoff, and recipient confirmation.
- Activity and audit history.
- Receipt scanning with on-device Vision.
- Live Receipt Rooms, local and server-backed with invitations and guests.
- Claude receipt intelligence with deterministic validation and on-device fallback.

### Real Multi-User P2P Groups (milestone 7)

Status: **implemented and locally verified, deployment pending.** Proven against the local server and
the Datastore emulator with development accounts; real Firebase accounts and the GCP deployment wait for
the project owner's configuration (see `milestone 7.md` §18 and its final report).

- Recoverable accounts (email and password), a profile name, and account-owned payment methods
- Shared groups on the server, created new or published once from a local group
- Invitation codes, QR codes, and a share link to an HTTPS invitation page (not a universal link)
- Cross-device membership, including seats the owner added before inviting
- Cross-device expenses, revalidated by the server, with offline queueing and conflict handling
- Synchronized balances and settlement plans, checked against the server's
- Payment reporting by the payer and confirmation by the recipient on their own device
- Shared activity history

Not in this milestone: reminders and push notifications (the app polls while open).

### Production and Course Delivery

- Deployment
- Security review
- TestFlight
- User testing
- Performance
- Accessibility validation
- Receipt-accuracy evaluation
- Final polish
- Final report
- Presentation and demonstration

The App Clip remains paused pending the Apple Developer Program decision.

## Concise product statement

Square Up is a Splitwise-style app for people who share costs. It reads receipts with on-device Vision and Claude, lets everyone claim their items in a Live Receipt Room, allocates tax, tip, and discounts exactly, suggests the fewest payments to settle up, and hands each payment off to the app people already use. Every number is checked deterministically, and every AI suggestion is reviewed by a person.
