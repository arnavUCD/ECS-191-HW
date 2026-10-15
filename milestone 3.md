# Square Up — Milestone 3

## Receipt Intelligence and Live Receipt Room

**Status:** Approved implementation specification  
**Starting point:** Milestones 1 and 2 are complete. The app builds in Swift 6 strict-concurrency mode, the personal group-expense and settlement flows work, and the current experience has been reviewed successfully on a physical device.  
**Primary objective:** Turn a paper or digital receipt into a verified, itemized group expense through a fast, trustworthy collaborative flow.

> **Scope change (October 2026):** Square Up is now peer-to-peer only. Organization groups, roles, budgets, approvals, organization funding, and reimbursement management were removed from the product and are no longer planned. The receipt and Live Receipt Room results below are unchanged. See `overview.md` and `App/ARCHITECTURE.md` (P2P scope and legacy compatibility).

---

## 1. Milestone outcome

At the end of Milestone 3, a user must be able to:

1. Scan a receipt with the camera or select one from Photos.
2. See clear progress while Square Up recognizes the receipt on device.
3. Review the original receipt beside editable extracted information.
4. Correct the merchant, date, individual items, quantities, prices, subtotal, tax, tip, fees, discounts, and total.
5. Start a Live Receipt Room for a selected group.
6. Switch among simulated group members on one device and claim, share, or dispute items.
7. Allocate tax, tip, service charges, fees, discounts, and rounding differences using understandable rules.
8. See exactly what each person owes before anything is saved.
9. Resolve every unclaimed item, conflict, and arithmetic mismatch.
10. Finalize the room as a normal itemized expense in the existing ledger.
11. Reopen the saved expense to view its receipt, item allocations, and audit history.

The milestone is successful only when the full path works:

> Receipt → recognition → human review → room → claims → exact reconciliation → final expense

---

## 2. Product principle

Receipt recognition is an assistant, not an authority.

Square Up must preserve three distinct layers:

1. **Original evidence:** the captured or imported receipt image.
2. **Machine proposal:** OCR text and suggested structured fields.
3. **User-confirmed record:** the information approved before the expense is created.

The app must never silently invent an amount, change a total, or finalize an uncertain receipt. Every financial calculation remains deterministic and exact to the cent. AI may reduce typing, but the user owns the final decision.

---

## 3. Locked product and technical decisions

### 3.1 Apple-native capture and recognition first

- Use VisionKit for document-style camera capture.
- Use PhotosUI for importing receipt images.
- Use Vision for on-device text recognition.
- Use AVFoundation only if a specific experience cannot be delivered with VisionKit.
- Do not add a third-party OCR service in this milestone.
- Receipt recognition must work without uploading the receipt to an external service.

### 3.2 Human review is mandatory

- Recognition produces a draft only.
- No recognized receipt is saved directly as an expense.
- Low-confidence and inconsistent fields must be visibly identified.
- The original image must remain available throughout review.
- The user must explicitly approve the receipt before opening the room or creating an expense.

### 3.3 Deterministic money logic remains authoritative

- Store money as whole minor currency units using the existing money model.
- Use the existing exact-cent rounding behavior.
- OCR and AI never perform the final allocation.
- The allocation engine must prove that participant amounts add exactly to the receipt total.
- Any mismatch must be visible and resolved before finalization.

### 3.4 Local-first room for the course prototype

The Milestone 3 room will provide the entire collaborative experience through clearly labeled simulated participant switching on one device. This makes every claim, dispute, conflict, and payer action demonstrable without implying that production synchronization exists.

The room architecture must use repository and command boundaries so that real networking can replace the local repository later.

### 3.5 App Clip and real cross-device invitations

An App Clip is valuable only when an invited person can open a genuinely server-backed room. A fake invitation that works only on the creator's phone would misrepresent the product.

For Milestone 3:

- Define the App Clip invocation, lightweight identity, and room-entry architecture.
- Keep the room UI compatible with an eventual App Clip target.
- Do not make a production App Clip a completion requirement until remote room synchronization exists.
- If schedule permits, build a contained feasibility prototype after the core milestone is complete.

### 3.6 SharePlay

SharePlay is deferred until server-backed rooms exist. GroupActivities may later improve presence and coordination, but it must not become the authoritative financial data store.

### 3.7 Live Activities

A privacy-safe Live Activity is optional after the core room lifecycle works. It may show only high-level status such as:

- Room is open.
- Number of items remaining.
- Action is required.
- Room is ready to finalize.

It must not show item names, purchase details, or individual balances on the Lock Screen.

---

## 4. Scope

### 4.1 Required

- Camera receipt scanning.
- Photos import.
- Image normalization and local asset storage.
- On-device OCR.
- Deterministic receipt structuring with confidence and evidence.
- Complete receipt review and correction UI.
- Itemized split model and exact allocation engine.
- Local Live Receipt Room.
- Participant identity switching for demonstration.
- Single-person and shared-item claims.
- Equal, share-based, and exact shared-item allocation.
- Tax, tip, fee, service charge, discount, and rounding allocation.
- Disputes and payer resolution.
- Room readiness rules.
- Finalization into the existing group ledger.
- Receipt and room audit history.
- SwiftData and in-memory persistence parity.
- Accessibility, privacy, error states, and comprehensive tests.

### 4.2 Optional after required work is complete

- Scan Receipt App Intent that opens the app at the capture flow.
- Privacy-safe Live Activity.
- App Clip feasibility target and invocation mock.
- Foundation Models-assisted receipt structuring when supported.
- QR presentation for the future invitation architecture, clearly labeled as a prototype if it does not open a remote room.

### 4.3 Not part of this milestone

- Production remote synchronization.
- User accounts or cloud identity.
- A production App Clip connected to live remote data.
- SharePlay.
- Cloud OCR or server-side AI.
- Organization approvals and reimbursement policies.
- Payment processing changes.
- Push notifications.
- Barcode or SKU database lookup.
- Merchant integrations.
- Automatic submission without review.

---

## 5. Primary user experience

### 5.1 Entry points

The user can start from:

- **Scan receipt** on Home.
- **Scan receipt** from a group detail screen.
- The Add Expense flow.
- An optional Scan Receipt App Intent.

When launched from a group, that group is preselected. When launched globally, group selection occurs during review.

### 5.2 Capture or import

The first screen offers:

- **Scan with Camera**
- **Choose from Photos**
- A short privacy explanation stating that recognition occurs on device.

Camera permission is requested only after the user chooses camera scanning. Photos access uses the system picker and should not request broad library access.

The capture experience must support:

- Automatic edge detection and perspective correction.
- Retake.
- Crop and rotate.
- Multiple pages when a receipt is unusually long or split across images.
- A visible image-quality warning for blur, glare, missing edges, or very low contrast when detectable.

### 5.3 Processing

Show named progress stages instead of an indefinite spinner:

1. Preparing receipt
2. Reading text
3. Organizing items
4. Checking totals

The user may cancel. Processing must not block the interface. If the app moves to the background, work should either finish safely or resume without corrupting the draft.

### 5.4 Receipt review

The review screen presents:

- The original image with zoom and pan.
- Editable structured values.
- Confidence or attention indicators.
- A reconciliation summary that updates immediately.

Editable fields include:

- Merchant
- Date
- Currency
- Item name
- Quantity
- Unit price, when available
- Line total
- Subtotal
- Tax
- Tip
- Service charge
- Other fee
- Discount
- Receipt total

The user can:

- Add a missed item.
- Delete an incorrectly recognized item.
- Merge wrapped text lines into one item.
- Split a wrongly combined item.
- Rename any item.
- Change quantities or amounts.
- Add or remove charges.
- Crop, rotate, replace, or rescan a page.

Selecting a field should reveal or emphasize the corresponding region of the original receipt when evidence geometry exists.

### 5.5 Review completion

The app enables **Continue to Room** only when:

- A group and payer are selected.
- The receipt has at least one valid item.
- All monetary fields are valid.
- The receipt math is reconciled or the user has explicitly assigned a documented remainder.
- No required field is in an unresolved invalid state.

Before continuing, show a plain-language statement such as:

> “The receipt total is $84.37. Eight items and three additional charges account for the full amount.”

---

## 6. Recognition and structuring pipeline

### 6.1 Pipeline stages

The pipeline must be separated into testable stages:

1. **Capture/import** — obtain one or more image assets.
2. **Normalize** — fix orientation, preserve aspect ratio, create processing and display variants.
3. **Recognize** — produce text observations and geometry with Vision.
4. **Structure** — propose merchant, date, item rows, charges, and totals.
5. **Validate** — check types, currency, arithmetic, duplicates, and ambiguity.
6. **Review** — present the proposal to the user.
7. **Confirm** — convert the reviewed draft into a room-ready receipt.

Each stage must have a typed input and output. UI code must not contain the receipt parsing rules.

### 6.2 OCR observations

Each recognized observation should retain:

- Original text.
- Normalized text.
- Confidence.
- Page identifier.
- Bounding rectangle.
- Candidate alternatives when useful.
- Stable ordering information.

Geometry is evidence, not presentation-only data. It supports row grouping and lets the review UI connect a field to the source image.

### 6.3 Deterministic structuring baseline

The baseline structurer must work without Foundation Models. It should use deterministic rules such as:

- Horizontal and vertical alignment.
- Currency and decimal patterns.
- Likely quantity patterns.
- Common total, subtotal, tax, tip, fee, and discount labels.
- Date patterns.
- Merchant placement near the top of the receipt.
- Exclusion of card numbers, authorization codes, addresses, and footer text from item rows.
- Arithmetic consistency as a ranking signal.

Every proposed value must carry its source evidence and confidence reason.

### 6.4 Optional Foundation Models assistance

When Apple Intelligence and the required model are available, a receipt-structuring provider may propose a typed structure from OCR text.

Rules:

- The deterministic structurer remains the required fallback.
- Model availability must be checked at runtime.
- The model must consume recognized text, not upload the receipt.
- The model output must conform to a constrained typed schema.
- All money values must pass deterministic parsing and validation.
- The model must not invent a missing line item or amount.
- The model must not decide who owes money.
- The user must review the same fields regardless of provider.
- Tests must not require model availability.
- Logs may record provider type and processing duration, but never receipt contents.

### 6.5 Confidence and attention

Confidence should be communicated as action, not as an unexplained percentage:

- **Looks good** — consistent value with strong evidence.
- **Check this** — ambiguous recognition or weak evidence.
- **Needs resolution** — invalid value or math conflict.

Color cannot be the only indicator. Use an icon, label, and accessible description.

---

## 7. Receipt arithmetic and reconciliation

### 7.1 Canonical equation

The system should attempt to reconcile:

> Item subtotal + tax + tip + service charges + other fees − discounts + explicit adjustment = receipt total

Some receipts include tax in item prices, combine fees, omit a subtotal, or contain printed rounding. The model must support those cases without forcing a false interpretation.

### 7.2 Reconciliation rules

- Never silently modify a recognized or edited amount to make the receipt balance.
- Show the exact difference when the receipt does not reconcile.
- Let the user edit the incorrect field.
- If the source receipt genuinely contains an unexplained difference, allow an explicit **Adjustment** with a required label.
- Preserve the original recognized proposal in the audit history.
- Store negative discounts explicitly rather than hiding them inside another charge.
- Prevent unsupported mixed-currency receipts from proceeding.

### 7.3 Item validation

- Item names may be edited and must not be blank at finalization.
- Quantities must be positive when present.
- A line total is required.
- Refund or return lines may be negative but must be explicitly identified.
- Zero-value lines may be preserved as notes but cannot affect allocation.
- Duplicate-looking lines are warned about, not automatically removed.

### 7.4 Exact-cent allocation

All proportional and share-based allocation must use a deterministic largest-remainder method or the existing equivalent behavior:

1. Calculate ideal fractional shares.
2. Assign whole cents without exceeding the total.
3. Distribute remaining cents using a stable, documented ordering.
4. Confirm that the assigned shares exactly equal the source amount.

The UI should disclose rounding when it changes a participant's amount by a cent.

---

## 8. Live Receipt Room

### 8.1 Purpose

The room replaces the awkward discussion around a table after the bill arrives. Every person can clearly identify what they had, share common items, and see a continuously updated amount.

### 8.2 Room lifecycle

A room has these explicit states:

1. `draft` — receipt is still being reviewed.
2. `ready` — receipt is valid and can be opened.
3. `open` — participants may claim, share, and dispute.
4. `resolving` — payer is resolving remaining items or disputes.
5. `readyToFinalize` — every amount is allocated and no dispute remains.
6. `finalized` — an expense has been created and the room is locked.
7. `cancelled` — the draft or room was abandoned.

Invalid transitions must be rejected by the domain layer, not only hidden in the UI.

### 8.3 Roles

#### Payer/host

- Selects the group and payer.
- Reviews the recognized receipt.
- Opens the room.
- May claim items like any other participant.
- Resolves disputes and unclaimed amounts.
- Chooses allocation rules for additional charges.
- Performs final review and finalization.

#### Participant

- Joins or is selected from the group.
- Claims an item.
- Shares an item.
- Changes or removes their claim while the room is open.
- Disputes an item or allocation with a short note.
- Reviews their running total.
- Marks their portion reviewed.

### 8.4 Local prototype identity

For Milestone 3, the room contains an obvious identity switcher labeled for the prototype, for example:

> “Previewing as Maya”

Switching identity changes only the acting participant; it must not silently give that person host permissions. Each action records the actual simulated actor in the audit history.

### 8.5 Claim states

Each chargeable item can be:

- Unclaimed
- Claimed by one participant
- Shared by multiple participants
- Disputed
- Resolved

The room always shows unclaimed and disputed items prominently.

### 8.6 Claim actions

For an item, a participant can choose:

- **Mine** — claim the entire item.
- **Share** — add themselves to a shared claim.
- **Custom share** — use shares or an exact amount.
- **Not mine / Dispute** — flag the item with an optional note.
- **Undo** — remove their current claim while the room remains open.

### 8.7 Shared items

A shared item supports:

- Equal division among selected participants.
- Share counts, such as 2 shares for one person and 1 share for another.
- Exact per-person amounts.

The editor must show a live “adds up” status. It cannot be saved unless the participants' portions equal the item amount exactly.

### 8.8 Additional charges

Tax, tip, service charge, other fees, discounts, and explicit adjustments are allocated separately from item claims.

Supported strategies:

- **Proportional to item totals** — default for tax and most fees.
- **Equal among included participants.**
- **Custom shares.**
- **Exact amounts.**
- **Assigned to payer** when the host intentionally accepts the full charge.

The selected strategy and its result must be visible before finalization.

Discounts default to proportional allocation across item totals unless the host chooses another valid method. Negative allocations must remain understandable in the summary.

### 8.9 Running totals

The room displays:

- The participant's claimed item subtotal.
- Their portion of tax.
- Their portion of tip.
- Their portion of fees.
- Their portion of discounts.
- Their final amount.
- Room-wide allocated and remaining amounts.

Totals update immediately after every accepted command.

### 8.10 Disputes

A dispute contains:

- Item or charge reference.
- Participant.
- Optional note.
- Creation time.
- Resolution state.
- Resolving actor and resolution note when applicable.

A disputed amount prevents finalization. The host may resolve by changing the item, changing allocations, assigning it, or dismissing the dispute with an audit note.

### 8.11 Editing after claims begin

If the host edits a line amount or deletes an item after it has claims:

- Show a clear confirmation explaining the effect.
- Invalidate only the affected item's allocations when possible.
- Preserve the previous values and claims in the audit history.
- Increase the room revision.
- Notify the local room UI that affected participants need to review again.

Changing merchant text or another nonfinancial field does not invalidate claims.

---

## 9. Final review and ledger creation

### 9.1 Readiness conditions

The room is ready to finalize only when:

- Every chargeable item is fully allocated.
- Every additional charge and discount is fully allocated.
- No dispute remains open.
- No invalid receipt field remains.
- Participant totals exactly equal the receipt total.
- The group and payer still exist.
- At least one participant owes a valid amount or the payer intentionally owns the entire receipt.

### 9.2 Final review screen

Show:

- Merchant, date, and receipt total.
- Payer.
- Each participant's items and additional charges.
- Each participant's final amount.
- Rounding disclosures.
- Any manual adjustment.
- A direct statement proving that the allocation adds to the total.

Example:

> “The $84.37 receipt is fully assigned. Alex paid, Maya owes $26.42, Jordan owes $31.10, and Alex's own share is $26.85.”

### 9.3 Finalization command

Finalization must be one idempotent domain command:

1. Revalidate the room and expected revision.
2. Freeze a receipt allocation snapshot.
3. Create an `Expense` using the existing ledger command path.
4. Use the existing `.itemized` split method or its finalized equivalent.
5. Attach the receipt reference and room snapshot.
6. Record an audit event.
7. Mark the room finalized.

A double tap, retry, or interrupted save must not create duplicate expenses.

### 9.4 After finalization

- Claims can no longer be changed in the room.
- The created expense appears everywhere a normal expense appears.
- The expense detail shows its itemized breakdown and receipt.
- Later changes use the existing expense revision system.
- Deleting the expense must follow the current audit and balance rules.
- Receipt retention behavior must be explicit if an associated expense is deleted.

---

## 10. Domain model

Names may be adjusted to match the codebase, but the responsibilities must remain separated.

### 10.1 Receipt assets

`ReceiptAsset`

- Stable identifier
- Local file reference
- Thumbnail reference
- Page order
- Pixel dimensions
- Orientation metadata
- Import source: camera or Photos
- Creation date
- Content fingerprint for duplicate detection

### 10.2 Recognition evidence

`RecognizedRegion`

- Identifier
- Page identifier
- Original text
- Normalized text
- Confidence
- Bounding rectangle
- Candidate alternatives
- Reading order

### 10.3 Receipt draft

`ReceiptDraft`

- Identifier
- Asset references
- Merchant proposal and confirmation state
- Date proposal and confirmation state
- Currency
- Line items
- Additional charges
- Subtotal
- Total
- Reconciliation state
- Recognition provider metadata
- Draft revision
- Created and updated dates

### 10.4 Receipt field evidence

Every recognized structured field should carry:

- Current value
- Original proposed value
- Confidence/attention state
- Source region identifiers
- Whether a user edited it
- Last editor and edit date when applicable

### 10.5 Receipt line item

`ReceiptLineItem`

- Identifier
- Display order
- Name
- Quantity, optional
- Unit price, optional
- Line total
- Refund/return flag
- Source evidence
- Validation state

### 10.6 Additional charge

`ReceiptCharge`

- Identifier
- Type: tax, tip, service fee, other fee, discount, adjustment
- User-facing label
- Amount
- Source evidence
- Allocation strategy

### 10.7 Room

`ReceiptRoom`

- Identifier
- Group identifier
- Host member identifier
- Payer member identifiers and contributions
- Confirmed receipt draft identifier
- State
- Participants
- Claims
- Disputes
- Room revision
- Created, opened, finalized, or cancelled dates
- Final expense identifier, when finalized

### 10.8 Claims

`ReceiptClaim`

- Item identifier
- Participant identifier
- Mode: full, equal share, shares, exact amount
- Share count or exact amount
- Created and updated dates
- Room revision

### 10.9 Allocation snapshot

The immutable final snapshot contains:

- Receipt values used at finalization.
- Item-level participant allocations.
- Charge-level participant allocations.
- Participant totals.
- Payer contributions.
- Rounding decisions.
- Room revision.
- Finalization date.

This snapshot makes the expense explainable even if room implementation changes later.

---

## 11. Service and repository boundaries

Use protocols so device frameworks, parsing, persistence, and UI remain independently testable.

Suggested boundaries:

- `ReceiptCaptureProviding`
- `ReceiptImportProviding`
- `ReceiptAssetStoring`
- `ReceiptRecognizing`
- `ReceiptStructuring`
- `ReceiptValidating`
- `ReceiptAllocationCalculating`
- `ReceiptRoomRepository`
- `ReceiptRoomCommandHandling`
- `ReceiptFinalizing`

Requirements:

- Provide test doubles for framework-backed services.
- Provide in-memory and SwiftData room repositories with matching behavior.
- Keep Vision types out of the domain model.
- Keep SwiftData types behind the persistence layer.
- Keep UI state on the main actor.
- Run image processing and recognition away from the main actor.
- Model cancellation explicitly.
- Use revision checking so stale room commands cannot silently overwrite newer state.

---

## 12. Persistence and file management

### 12.1 Image storage

- Store receipt images as local files, not large SwiftData blobs.
- Store only stable references and metadata in SwiftData.
- Create smaller display thumbnails.
- Preserve enough source quality to verify recognized text.
- Use atomic file writes.
- Use a dedicated receipt directory owned by the app.
- Apply appropriate file protection for financial images.

### 12.2 Lifecycle

- A draft image survives normal app termination.
- Cancelling a draft offers to discard it.
- Discarding removes unreferenced files.
- Finalized receipt files remain associated with the expense.
- Cleanup must detect orphaned thumbnails and source images safely.
- Reset Sample Data must also reset sample receipt assets without touching unrelated files.

### 12.3 Migration

Adding receipt and room entities must use a deliberate SwiftData schema version and migration strategy. Existing Milestone 2 data must continue to open.

---

## 13. Interface design

### 13.1 Design language

- Continue the established Square Up design system.
- Use native navigation, sheets, controls, and materials.
- Prefer focused steps over one crowded screen.
- Use the existing spacing, typography, color, corner, motion, and haptic tokens.
- Preserve excellent light and dark mode behavior.
- Avoid decorative visuals that compete with receipt evidence.

### 13.2 Required screens

1. Receipt source chooser
2. System document scanner or Photos picker
3. Processing progress
4. Receipt review
5. Reconciliation detail
6. Room setup and participant selection
7. Open room item list
8. Shared-item editor
9. Additional-charge allocation editor
10. Dispute editor and host resolution
11. Final review
12. Success confirmation
13. Itemized expense detail with receipt viewer

### 13.3 Room navigation

The open room should make three facts immediately obvious:

- Who the user is currently acting as.
- What that participant has claimed and owes.
- What remains unresolved for the room.

Useful room filters:

- All
- Mine
- Unclaimed
- Shared
- Disputed

### 13.4 Motion and haptics

- Use subtle item-state transitions when claims change.
- Use a light selection haptic for claim toggles.
- Use a warning haptic for invalid reconciliation or conflicts.
- Use the existing strong success haptic only when finalization succeeds.
- Respect Reduce Motion.
- Never rely on animation to communicate state.

### 13.5 Accessibility

- Support Dynamic Type through accessibility sizes.
- Provide meaningful VoiceOver descriptions for receipt pages and recognized fields.
- Announce when a claim changes a participant total.
- Announce reconciliation errors and the exact mismatch.
- Ensure every action is usable without image-coordinate tapping.
- Use accessible alternatives to drag-only reordering.
- Maintain minimum touch targets.
- Do not communicate confidence, claim state, or disputes through color alone.
- Preserve logical focus when fields are corrected or items change state.

---

## 14. Privacy and security

Receipts may reveal location, purchasing habits, card fragments, health information, or other sensitive details.

Requirements:

- Perform recognition on device by default.
- Explain why camera access is needed at the moment it is requested.
- Use the system Photos picker.
- Never log OCR text, merchant names, item names, receipt images, or payment details.
- Use OSLog privacy controls for identifiers and diagnostics.
- Exclude receipt contents from analytics.
- Provide a clear deletion path for drafts and receipt attachments.
- Avoid exposing sensitive receipt content in notifications, widgets, or Live Activities.
- Do not transmit receipt data in Milestone 3.
- Sample and test receipts must contain fictional information.
- App Clip planning must minimize the data retained for a temporary participant.

---

## 15. Performance and reliability

- Downsample processing copies without destroying the preserved source image.
- Avoid decoding every full-resolution page simultaneously.
- Generate and cache thumbnails.
- Perform Vision work off the main actor.
- Show progress for long receipts and multi-page jobs.
- Support cancellation between pipeline stages.
- Release temporary image buffers promptly.
- Restore an interrupted draft safely.
- Prevent duplicate receipt assets and duplicate finalization where practical.
- Keep scrolling smooth in a room with at least 100 line items.

Suggested performance checks should cover:

- A normal one-page receipt.
- A very long receipt.
- Three receipt pages.
- A high-resolution imported image.
- Accessibility text sizes.
- A low-memory simulator/device condition when practical.

---

## 16. Error and edge-case behavior

The app needs designed outcomes for:

- Camera permission denied.
- Camera unavailable.
- Photos import cancelled.
- Unsupported or corrupt image.
- Blurry, dark, overexposed, or heavily rotated receipt.
- Receipt partially outside the image.
- Handwritten receipt.
- Multi-page receipt.
- Same page imported twice.
- No text found.
- Merchant or date not found.
- No total found.
- Multiple possible totals.
- Subtotal and items do not agree.
- Tax already included.
- Blank tip line.
- Service charge plus tip.
- Multiple discounts.
- Negative return item.
- Zero-value promotional item.
- Printed rounding adjustment.
- Unsupported multiple currencies.
- Extremely long item name.
- Duplicate participant names.
- Participant removed from the group while a draft exists.
- Two simulated actors attempt conflicting claims from stale room revisions.
- Host changes an already claimed item's amount.
- Participant removes their final claim.
- App closes during recognition.
- App closes while a room is open.
- Finalize is tapped twice.
- Persistence save fails after receipt processing.
- Receipt image is missing when reopening an expense.

Every failure must provide a useful recovery action such as retry, rescan, import another image, edit manually, save draft, or discard.

---

## 17. Testing strategy

### 17.1 Test data

- Use a curated set of fictional receipt fixtures.
- Include common layouts, long receipts, low-quality images, discounts, fees, refunds, and intentionally inconsistent totals.
- Never commit a real personal receipt.
- Keep deterministic OCR/structuring fixtures separate from tests that invoke Vision.

### 17.2 Unit tests

Test:

- Money parsing and normalization.
- Observation ordering and row grouping.
- Date and merchant proposals.
- Item and charge labeling.
- Receipt reconciliation.
- Explicit adjustments.
- Confidence and attention states.
- Equal, proportional, share, and exact allocation.
- Largest-remainder cent distribution.
- Negative discount distribution.
- Shared-item validation.
- Room state transitions.
- Host authorization.
- Stale-revision conflicts.
- Claim changes and undo.
- Dispute creation and resolution.
- Readiness conditions.
- Finalization idempotency.
- Audit history.
- File lifecycle and orphan cleanup.

### 17.3 Recognition tests

Vision output may change across OS versions, so tests should be layered:

- Unit-test the structurer with fixed recognized-region fixtures.
- Add a smaller integration suite using known receipt images and tolerant semantic assertions.
- Avoid fragile assertions against every OCR character or exact confidence value.
- Confirm that failure produces a reviewable manual draft rather than data loss.

### 17.4 Persistence contract tests

Run the same room and finalization scenarios against:

- In-memory repositories.
- SwiftData repositories.

Verify equivalent outcomes and error behavior.

### 17.5 Snapshot tests

Cover major receipt and room states in light and dark mode:

- Empty capture state.
- Processing.
- Clean review.
- Several low-confidence fields.
- Reconciliation mismatch.
- Open room.
- Participant view.
- Unclaimed items.
- Shared-item editor.
- Dispute state.
- Ready-to-finalize summary.
- Large Dynamic Type.
- Narrow screen.

### 17.6 UI tests

At minimum:

1. Import a bundled fictional receipt fixture, review it, open a room, claim items as multiple participants, and finalize.
2. Correct an OCR mistake and resolve a receipt mismatch.
3. Share an item with exact-cent rounding.
4. Create and resolve a dispute.
5. Terminate and relaunch with a saved draft or open room.
6. Confirm that a double finalization attempt creates only one expense.

System camera capture must be reviewed manually on a physical device because it cannot be fully represented by a fixture-only UI test.

### 17.7 Device review matrix

Review on at least:

- A supported physical iPhone with camera.
- A smaller/narrower simulator.
- A large-screen simulator.
- Light mode.
- Dark mode.
- An accessibility text size.
- Reduced Motion.
- VoiceOver for the critical claim and review flows.
- Offline mode.

---

## 18. Implementation sequence

### M3.1 — Receipt assets and capture

- Add receipt schema and file storage.
- Implement VisionKit document scanning.
- Implement PhotosPicker import.
- Add crop, rotate, retake, and multi-page management.
- Add thumbnails, cancellation, restoration, and cleanup.
- Add permission and failure states.

**Exit condition:** A receipt can be captured/imported, safely stored, reopened, edited at the page level, and discarded.

### M3.2 — Recognition and review

- Implement the Vision recognizer.
- Add observation geometry and evidence.
- Implement deterministic structuring.
- Add progress stages.
- Build the review and reconciliation interface.
- Add manual item and charge editing.
- Add confidence/attention behavior.

**Exit condition:** A user can turn a fixture or real receipt into a fully reviewed, mathematically valid receipt draft without AI availability.

### M3.3 — Itemized allocation engine

- Complete the `.itemized` split domain model.
- Implement single and shared item allocation.
- Implement charge and discount strategies.
- Reuse exact-cent rounding rules.
- Produce participant summaries and proof of equality.

**Exit condition:** Any valid reviewed receipt can be allocated exactly and explainably among group members.

### M3.4 — Local Live Receipt Room

- Add room, participant, claim, dispute, and revision models.
- Add in-memory and SwiftData repositories.
- Implement the room state machine and command handler.
- Build the local participant identity switcher.
- Build room filters and running totals.

**Exit condition:** Multiple simulated participants can claim and unclaim items with correct permissions, totals, persistence, and conflict handling.

### M3.5 — Resolution and finalization

- Add shared-item editor.
- Add extra-charge allocation editor.
- Add dispute workflow.
- Add host resolution tools.
- Add readiness validation.
- Add idempotent ledger finalization.
- Show receipts and allocation snapshots on expense detail.

**Exit condition:** The complete signature flow creates one correct, auditable itemized expense.

### M3.6 — Quality and polish

- Complete accessibility behavior.
- Complete error and recovery states.
- Tune performance and memory use.
- Add motion, haptics, and visual polish.
- Complete snapshot, UI, persistence, and device testing.
- Confirm zero warnings and clean lint/format output.

**Exit condition:** The required definition of done is satisfied.

### M3.7 — Optional intelligent and system features

Only after M3.6:

- Add Foundation Models structuring behind the provider boundary.
- Add Scan Receipt App Intent.
- Evaluate a privacy-safe Live Activity.
- Validate App Clip target size and invocation architecture.

These enhancements must not destabilize the core receipt workflow or become required for users without Apple Intelligence.

---

## 19. Definition of done

Milestone 3 is complete when all of the following are true:

- The app builds with Swift 6 strict concurrency and zero warnings.
- SwiftLint and SwiftFormat report no findings.
- All existing Milestone 1 and 2 behavior still passes.
- Camera scan works on a physical device.
- Photos import works.
- Recognition occurs on device and has a deterministic fallback path.
- Every recognized value is reviewable and editable.
- Original receipt evidence remains accessible.
- Invalid receipt arithmetic cannot proceed silently.
- Itemized allocations always add exactly to the receipt total.
- Shared items and additional charges support the specified strategies.
- The local room clearly represents each simulated participant.
- Claims, disputes, revisions, and permissions are enforced in the domain layer.
- An unresolved item or dispute prevents finalization.
- Finalization creates exactly one normal ledger expense.
- Reopening the expense explains every participant amount.
- Receipt and room data survive relaunch.
- In-memory and SwiftData behavior match.
- Receipt contents never appear in logs.
- Critical UI is accessible at large text sizes and with VoiceOver.
- Required unit, integration, snapshot, persistence, and UI tests pass.
- The complete demo works offline.

Optional App Clip, SharePlay, Live Activity, or Foundation Models work is not required to declare the core milestone complete.

---

## 20. Demonstration script

Use a fictional dinner receipt and a group with at least four members.

1. Open a group and tap **Scan receipt**.
2. Import or scan the receipt.
3. Show the named processing stages.
4. Review the recognized merchant, date, items, tax, tip, and total.
5. Correct one intentionally imperfect field and show the reconciliation update.
6. Open the Live Receipt Room.
7. Switch to Participant A and claim two items.
8. Switch to Participant B and start a shared item.
9. Switch to Participant C and join the shared item.
10. Demonstrate a rounding-cent disclosure.
11. Create a dispute, then switch back to the host and resolve it.
12. Show proportional tax and tip allocation and change one charge to a different strategy.
13. Resolve the final unclaimed item.
14. Show that the participant totals equal the receipt total exactly.
15. Finalize with the success haptic.
16. Open the created expense and show the receipt, itemized shares, and audit history.
17. Open Settle Up to show that the new expense participates in the existing optimized balance flow.

This demonstration should communicate the central product promise: a group can leave the table without doing receipt math aloud or arguing over a spreadsheet.

---

## 21. Risks and mitigations

### OCR accuracy varies across receipts

**Mitigation:** Make review fast, preserve evidence, highlight uncertainty, and provide complete manual editing.

### Receipt layouts are effectively unbounded

**Mitigation:** Use a deterministic baseline, evidence-aware proposals, an explicit adjustment, and fixture diversity instead of claiming universal automation.

### Room scope can grow into a backend project

**Mitigation:** Deliver the full product interaction locally behind network-ready repository boundaries. Do not make remote synchronization a hidden requirement.

### App Clip may distract from the signature flow

**Mitigation:** Keep it optional until the local room is polished and a real remote data source exists.

### Exact financial allocation is easy to get subtly wrong

**Mitigation:** Centralize allocation logic, use whole cents, make rounding deterministic, and prove conservation in tests.

### Receipt images can consume memory and storage

**Mitigation:** Store files outside SwiftData, create thumbnails, downsample processing copies, and clean orphaned assets.

### AI availability differs by device and language

**Mitigation:** Make AI an optional structuring provider. The deterministic pipeline is always capable of completing the workflow.

---

## 22. Future continuation

After Milestone 3, the same architecture can support:

- Server-backed rooms with real-time synchronization.
- Universal links and a production App Clip.
- SharePlay presence layered over the authoritative server room.
- Remote push notifications for claims and disputes.
- Exportable receipt reports.
- Merchant-aware categorization.
- Analytics using privacy-preserving aggregate events.

These are future capabilities, not promises disguised as current functionality.

---

## 23. Apple documentation references

- [VisionKit](https://developer.apple.com/documentation/visionkit)
- [Recognizing text in images with Vision](https://developer.apple.com/documentation/vision/recognizing-text-in-images)
- [PhotosUI](https://developer.apple.com/documentation/photosui)
- [Foundation Models](https://developer.apple.com/documentation/foundationmodels)
- [App Intents](https://developer.apple.com/documentation/appintents)
- [App Clips](https://developer.apple.com/documentation/appclip)
- [ActivityKit](https://developer.apple.com/documentation/activitykit)
- [Group Activities](https://developer.apple.com/documentation/groupactivities)
- [Human Interface Guidelines — Privacy](https://developer.apple.com/design/human-interface-guidelines/privacy)
- [Human Interface Guidelines — Live Activities](https://developer.apple.com/design/human-interface-guidelines/live-activities)

---

## 24. Final implementation instruction

Implement the required sections in order and treat each exit condition as a gate. Reuse the current domain commands, money types, design system, repositories, test infrastructure, audit model, and strict-concurrency patterns. Do not replace working Milestone 2 architecture to add this feature.

When product ambition conflicts with trustworthy financial behavior, choose the behavior that is explicit, reversible, testable, and understandable to the user.

---
---

# Implementation status (Milestone 3)

> Added October 5, 2026, after the specification above (which is unchanged). Engineering detail:
> `App/ARCHITECTURE.md` ("Milestone 3 architecture"); dependency decisions: `App/DEPENDENCIES.md`.

**Overall:** M3.1–M3.6 are implemented and pass in the simulator. The Definition of Done is satisfied
**except the physical-device items** (camera scanning, haptics, VoiceOver, and memory on hardware),
which cannot be verified in the simulator and are listed below. Milestone 3 is therefore *not yet
declared complete*; it is simulator-complete pending the device review.

## Verified quality gate (simulator, Xcode 27 / iOS 27 SDK, iPhone 18 Pro)

| Check | Result |
|---|---|
| Swift 6 strict concurrency, clean build (simulator and iPhone) | **0 warnings** |
| Unit, persistence-contract, integration, and snapshot tests (Swift Testing) | **280 passed, 0 failed** (Milestone 1–3) |
| Milestone 3 UI tests (XCUITest, §17.6) | **5 passed**: sample → OCR fix → claims → finalize; shared item rounding; dispute + resolution; draft and room survive relaunch; double finalize creates one expense |
| Milestone 1–2 UI tests (regression) | **9 passed, 0 failed** |
| Snapshot references | 62 total (20 new for receipts and rooms, re-recorded and reviewed in light/dark, 320 pt, accessibility size) |
| SwiftLint / SwiftFormat | **0 findings / 0 files to format** |
| Real Vision OCR on the bundled fictional receipt | Passes (tolerant semantic assertions) |
| Milestone 2 → 3 migration | Simulator test passes; build installed over the milestone 2 build on the test iPhone and launched (data check on the phone pending) |
| New dependencies | **None** |

## Stage status

| Stage | Status | Exit condition evidence |
|---|---|---|
| M3.1 Receipt assets and capture | Done (camera on device pending) | VisionKit document camera (multi-page, retake, crop by the scanner); PhotosPicker; protected files (original + page + thumbnail); rotate, trim-crop, replace/rescan, reorder, remove, add pages; duplicate-page detection; quality warnings; permission explanation and denied/unavailable states; drafts persist and resume; discard removes files; orphan cleanup; reset clears receipt files only. `ReceiptAssetAndRecognitionTests` |
| M3.2 Recognition and review | Done | Vision `RecognizeTextRequest` off the main actor; regions with geometry; deterministic structurer; named, cancellable stages; review with zoomable evidence highlighting, live reconciliation, every field editable, attention states, merge/split/move/add/delete lines, charges, labelled adjustment. Works with no AI. `ReceiptParsingTests`, `visionIntegration`, UI test 1–2 |
| M3.3 Itemized allocation engine | Done | Single/equal/shares/exact items; proportional/equal/shares/exact/payer charges and discounts; largest-remainder cents with disclosures; participant totals and proof. Property tests (40 random rooms) prove conservation |
| M3.4 Local Live Receipt Room | Done | Room aggregate + state machine + command handler with revisions and role checks; in-memory and SwiftData stores (one engine); "Previewing as …" switcher pinned at the top; filters; running totals; persistence parity, relaunch, stale-revision tests |
| M3.5 Resolution and finalization | Done | Shared-item editor, charge editor, disputes and host resolution, readiness rules, idempotent finalization through `addExpense`, receipt + snapshot + history on expense detail |
| M3.6 Quality and polish | Done in simulator | Light/dark, narrow, large and accessibility text sizes reviewed through 20 new snapshot references and UI-test screenshots; zero warnings, lint, format |
| M3.7 Optional | Partly | **Scan Receipt App Intent** (and `squp://scan`) implemented. Foundation Models structuring and Live Activity were not built. The App Clip is planned as a **required Milestone 4 feature**, paired with server-backed multi-device rooms, but Milestone 4 is paused pending professor approval and Apple Developer Program access. |

## Definition of done (§19)

| Item | Status | Evidence |
|---|---|---|
| Builds with Swift 6 strict concurrency, zero warnings | ✅ | Simulator and device builds |
| SwiftLint and SwiftFormat report no findings | ✅ | 0 / 0 |
| All existing Milestone 1 and 2 behavior still passes | ✅ | 280 unit/snapshot tests; M1–2 UI tests |
| Camera scan works on a physical device | ⏳ Device | VisionKit scanner implemented; simulator has no camera |
| Photos import works | ✅ (simulator) | PhotosPicker path; sample import in UI tests |
| On-device recognition with a deterministic fallback | ✅ | Vision OCR + `DeterministicReceiptStructurer`; no AI required |
| Every recognized value is reviewable and editable | ✅ | Review screen + editors; feature-model tests |
| Original receipt evidence remains accessible | ✅ | Original file kept; evidence highlighting; viewer on the expense |
| Invalid receipt arithmetic cannot proceed silently | ✅ | Continue disabled with exact difference; engine refuses `confirmReceipt` |
| Itemized allocations always add exactly to the total | ✅ | Property tests (40 random rooms), 120-item test, final review proof |
| Shared items and charges support the specified strategies | ✅ | Equal/shares/exact items; proportional/equal/shares/exact/payer charges |
| The local room clearly represents each simulated participant | ✅ | Pinned "Previewing as …" bar labelled as a local prototype |
| Claims, disputes, revisions, permissions enforced in the domain | ✅ | `ReceiptRoomEngineTests` (stale revisions, host-only, participant rules) |
| Unresolved item or dispute prevents finalization | ✅ | `ReceiptRoomReadiness`; dispute UI test |
| Finalization creates exactly one ledger expense | ✅ | Idempotency unit tests in both stores; double-finalize UI test |
| Reopening the expense explains every amount | ✅ | Itemized section with frozen snapshot, proof, and room history |
| Receipt and room data survive relaunch | ✅ | Persistence relaunch test; relaunch UI test |
| In-memory and SwiftData behavior match | ✅ | `ReceiptPersistenceTests.parity` (including errors) |
| Receipt contents never appear in logs | ✅ | `Log.receipts` records counts, durations, and provider kinds only |
| Critical UI accessible at large text and with VoiceOver | ✅ text sizes / ⏳ VoiceOver on device | Accessibility-size snapshots; VoiceOver labels and announcements implemented, device pass pending |
| Required unit, integration, snapshot, persistence, UI tests pass | ✅ | See the quality gate above |
| The complete demo works offline | ✅ (by design) / ⏳ Airplane Mode check | No network calls anywhere in the receipt flow |

## Deliberate deviations

- **One payer per receipt.** The room records a single payer who paid the full receipt total; multiple payers remain available for manual expenses.
- **The room aggregate holds the draft.** A `ReceiptRoom` is created at capture in the `draft` state with the receipt inside it, so drafts and rooms share one persistence and audit path.
- **Crop uses four trim sliders** (with nested crops; rotation resets the crop) instead of drag handles, for VoiceOver and Voice Control; the VisionKit scanner already perspective-corrects camera pages.
- **Currency changes in review** are limited to currencies with the same number of decimal places and only relabel the digits — no amount is ever rounded.
- **Quality warnings** use deterministic image statistics (brightness, contrast, Laplacian sharpness) and OCR geometry (text touching the edge); they never block.
- **Editing an itemized expense later** uses the normal composer; the expense keeps showing the frozen receipt snapshot with an "edited after finalizing" note.
- **The sample receipt uses prerecorded recognition** (clearly labelled) with one deliberate misreading, so the demonstration and UI tests are deterministic; scanned and imported receipts always use Vision.
- **Deferred work:** Foundation Models structuring and a privacy-safe Live Activity remain optional. The App Clip is planned as a **required Milestone 4 deliverable** paired with server-backed multi-device rooms, but that milestone is currently paused pending professor approval and Apple Developer Program access. A local-only clip in Milestone 3 would have misrepresented invitations (§3.5).

## Remaining physical-device verification (§17.7)

- [ ] VisionKit camera scan on a real receipt: permission explanation → system prompt; denied → Settings; edge detection, retake, multi-page; recognition quality.
- [ ] Photos import of real HEIC photos (orientation) and a very large image (memory).
- [ ] Haptics: selection on claims, `reconcile` when fully assigned, `settle` on finalization.
- [ ] VoiceOver through review and the room (focus order, claim-total announcements, mismatch announcements); Voice Control names.
- [ ] Reduced Motion on device (snapshots cover the static paths).
- [ ] Recognition time and memory for a long three-page receipt; a low-memory condition.
- [ ] Installing this build over the milestone 2 build already on the test iPhone (real on-disk migration; covered in the simulator by `migrationFromMilestone2`).
- [ ] Offline demonstration end to end (nothing in the flow uses the network; verify in Airplane Mode).

## Demonstration script (§20) readiness

Steps 1–17 run in the simulator with the sample receipt and the Friday Dinner Crew (Riley, Maya, Alex, Priya):
Scan receipt from the group → sample → named stages → review shows Tiramisu read as $6.50 ("Check this") and
"Doesn't add up yet … $2.00" → correct to $8.50 → "Adds up exactly" → Continue to Room → Open room → switch
to Maya/Alex/Priya and claim; Truffle Fries shared three ways discloses the cent → Maya disputes → host
resolves → change the tip to "Equally" → claim the last item → "Fully assigned … Adds up exactly" → Review &
finalize → Save as expense (settle haptic on device) → View expense (receipt, item shares, room history) →
Settle Up includes the new expense. Step 2 with the camera needs a device.
