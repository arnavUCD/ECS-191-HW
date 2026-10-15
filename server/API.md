# Square Up API — `/v1`

The server is the authority for shared Receipt Rooms (milestone 4) and shared P2P groups
(milestone 7). Clients send **intent** (commands). The server validates every command, applies it
atomically, and returns the authoritative revision and state. Clients never send totals, roles, readiness, or permissions, and the server never
trusts them if they do.

All bodies are JSON (`Content-Type: application/json`) unless noted. All money is an integer in the
currency's **minor units** (cents for USD, yen for JPY). Times are ISO 8601 UTC strings. IDs are
UUID strings.

## Authentication

Send exactly one `Authorization` header:

| Scheme | Who | Notes |
|---|---|---|
| `Bearer <Firebase ID token>` | Full-app account | Verified against Google's signing keys and the configured Firebase project. Must be a *recoverable* (email/password or phone) account with a **verified identity**: `email_verified: true`, or a phone number Firebase verified with an SMS code (an E.164 `phone_number` claim that is also in `firebase.identities.phone`). No exceptions by account age. Square Up never sends or checks codes. |
| `Guest <credential>` | App Clip guest | A room-scoped, 256-bit secret returned by **join**. Stored hashed. Slides 72 h while in use. |
| `Dev <uid>` | Local development and tests | Refused in production and on App Engine. Treated as recoverable for shared groups. |
| `Demo <credential>` | One device's demo workspace | A 256-bit secret returned by `POST /v1/demo/sessions`. Stored hashed. Ends after 7 days (`401 unauthenticated`, "This demo ended…"). See **Demo workspaces**. |

**Unverified accounts** (always email ones — a phone number is verified before its account exists) get
`403 email_not_verified` (anonymous Firebase accounts `403 account_required`)
on every account, shared-group, receipt-room, and receipt-intelligence route, with two exceptions:
`GET /v1/account` (to read why) and `DELETE /v1/receipt-intelligence/cache` (to withdraw consent).
Resending the verification email, changing an unverified address, and deleting an incomplete sign-up
go to Firebase directly. Room guests keep using their `Guest` credential and never reach shared groups
or receipt intelligence.

A display name is **not** an identity. Two guests can use the same name and stay different
participants.

## Errors

Every error uses the same envelope and a stable `code`. The `message` is safe to show to people.

```json
{ "error": { "code": "revision_conflict", "message": "The room changed. Review the latest and try again",
             "requestId": "…", "currentRevision": 5 },
  "room": { …current snapshot, only when the caller may see it… } }
```

| Code | HTTP | Meaning |
|---|---:|---|
| `invalid_payload` | 400 | Malformed or out-of-range input. |
| `unauthenticated` | 401 | Missing or unverifiable credential. |
| `credential_expired` | 401 | The guest credential expired or was revoked. Open the invitation again. |
| `forbidden`, `host_only`, `not_a_participant`, `cannot_include_others`, `cannot_remove_others` | 403 | The caller isn't allowed to do this. |
| `room_not_found`, `invitation_invalid`, `item_not_found`, `charge_not_found`, `dispute_not_found`, `asset_not_found`, `payment_not_found`, `receipt_not_found`, `not_found` | 404 | Unknown resource, or one the caller may not know exists. |
| `invitation_expired`, `invitation_revoked` | 410 | The link no longer works. Nothing about the room is revealed. |
| `room_expired` | 410 | A temporary room passed its deadline. Its read-only summary is still readable until retention ends. |
| `revision_conflict` | 409 | `expectedRevision` is stale. Nothing was applied. Includes `currentRevision` and `room`. |
| `room_finalized`, `room_cancelled`, `not_allowed_in_state`, `seat_taken`, `invitation_full`, `item_already_claimed`, `item_has_custom_split`, `no_claim_to_remove`, `dispute_already_resolved`, `not_ready_to_finalize`, `unresolved_dispute`, `room_closed`, `no_payment_due`, `receipt_limit`, `member_has_open_receipt`, `group_has_open_receipts` | 409 | Not possible in the current state. |
| `units_unavailable` | 409 | Fewer units are left than requested. Includes `available` and the current `room`. |
| `unreviewed_shares` | 409 | Finalizing needs the host to acknowledge everyone whose current share isn't reviewed. Includes `participantIds` and `room`. |
| `receipt_conflict` | 409 | A group receipt's `expectedRevision` is stale. Includes `receiptId`, `receiptRevision`, and the receipt's `room` view. |
| `payload_too_large` | 413 | Request over 256 KB (images: 4 MB), or the room reached its size limit. |
| `unsupported_media` | 415 | Receipt images must be JPEG. |
| `idempotency_key_reused` | 422 | The same key was used for a different request. |
| `invalid_split`, `invalid_allocation`, `item_not_claimable`, `note_required`, `note_too_long`, `receipt_not_ready`, `participant_not_in_room`, `participants_required`, `currency_change_after_open`, `item_quantity_unknown` | 422 | Domain validation failed. |
| `rate_limited` | 429 | Includes a `Retry-After` header and `retryAfterSeconds`. |
| `temporarily_unavailable` | 503 | Storage contention or outage. Nothing was changed. Safe to retry with the same idempotency key. |
| `ai_consent_required` | 403 | Receipt intelligence: the request didn't assert the person's consent. |
| `email_not_verified` | 403 | The account has no verified identity yet: its email address isn't verified, and it has no verified phone number (receipt intelligence, and every account and shared-group route except `GET /v1/account`). |
| `demo_restricted` | 403 | A demo workspace can't do this (Find a person, group invitations, joining across demo and real rooms). |
| `demo_unavailable` | 503 | The demo is turned off on this server. |
| `ai_demo_limit` | 429 | A demo workspace (or all demos together) used today's AI receipt reading; the app reads on device. |
| `ai_in_progress` | 409 | An identical receipt from the same account is being processed. Retry after `retryAfterSeconds`. |
| `ai_invalid_output`, `ai_refused`, `ai_provider_error` | 502 | The AI provider's answer was unusable (with a content-free `reason`), declined, or failed. |
| `ai_unavailable` | 503 | AI processing is off or not configured on this server. |
| `ai_timeout` | 504 | The AI provider didn't answer within the deadline. |

Every response carries `X-Request-Id`. A client may send its own (8–64 characters from
`[A-Za-z0-9-]`).

## Rooms

### `POST /v1/receipt-rooms` — publish (account only)

Publishes a reconciled receipt as a shared room. This is idempotent per `roomId` for the same
host. Seats (`participants` other than the host) are group members that people can later claim
when they join.

```json
{ "roomId": "uuid", "hostParticipantId": "uuid", "payerId": "uuid",
  "participants": [{ "id": "uuid", "displayName": "Riley" }, { "id": "uuid", "displayName": "Maya" }],
  "receipt": { "merchant": "Fernwood Supper Club", "date": "2026-09-24", "currency": "USD", "total": 2165,
               "subtotal": 1950,
               "items": [{ "id": "uuid", "name": "Truffle Fries", "lineTotal": 950, "quantity": 1, "unitPrice": 950, "isRefund": false }],
               "charges": [{ "id": "uuid", "kind": "tax", "label": "Tax", "amount": 215,
                             "allocation": { "kind": "proportional" } }] },
  "claims": [{ "itemId": "uuid", "participantId": "uuid", "mode": { "kind": "full" } }],
  "payerAcceptsFullReceipt": false }
```

Returns `201 {"room": Snapshot, "created": true}`, or `200` with `created: false` when the room
was already published. A receipt that doesn't reconcile returns `422 receipt_not_ready` with
`issues`.

- Charge `kind`: `tax`, `tip`, `serviceCharge`, `fee`, `discount` (negative), `adjustment` (either sign, label required).
- Charge allocation: `{"kind":"proportional"}`, `{"kind":"equal","members":[uuid]|null}`,
  `{"kind":"shares","weights":[{"participantId","weight"}]}`,
  `{"kind":"exact","amounts":[{"participantId","amount"}]}`, `{"kind":"payer"}`.
- Claim modes: `full`, `equalShare`, `{"kind":"shares","shares":n}`,
  `{"kind":"exact","amount":n}`, `{"kind":"units","units":n}` (some of a line with a printed
  quantity; see `claimUnits`).

**Temporary rooms ("Split with people now").** Add `"kind": "temporary"` and, optionally,
`"paymentDestinationIds": [uuid]` (up to 12 of the host's own enabled destinations from
`/v1/account/destinations`; anything else is `422 invalid_payload`). A temporary room has no group:
`participants` must be the host alone, the host is the payer (`payerId == hostParticipantId`), and
everyone else joins through an invitation. It's open for `SQUAREUP_TEMPORARY_ROOM_TTL_HOURS` (72)
and then expires. See [Temporary rooms](#temporary-rooms-split-with-people-now).

### `GET /v1/receipt-rooms/{roomId}` — snapshot (participants)

Returns `{"room": Snapshot}`. A caller who was never in the room gets `404 room_not_found`, the
same response as for a room that doesn't exist.

### `GET /v1/receipt-rooms/{roomId}/history`

Returns `{"history": [{sequence, revision, actorId, at, type, detail}]}`. `detail` holds
identifiers only, never notes or names.

### Snapshot

```json
{ "roomId", "revision", "state": "open|resolving|readyToFinalize|finalized|cancelled",
  "hostParticipantId", "payerId", "receipt": {…as published…},
  "participants": [{ "id", "displayName", "kind": "host|member|guest", "joinedAt", "removed",
                     "isClaimedSeat", "accountBacked" }],
  "participantOrder": [uuid],
  "claims": [{ "itemId", "participantId", "mode" }],
  "disputes": [{ "id", "target": {"kind":"item|charge","id"}, "raisedBy", "note", "createdAt",
                 "status": "open|resolved|dismissed", "resolvedBy", "resolvedAt", "resolutionNote" }],
  "reviews": [{ "participantId", "revision" }], "needsReview": [uuid],
  "payerAcceptsFullReceipt": false,
  "allocation": { "receiptTotal", "allocatedTotal", "remaining", "isComplete",
                  "items": [{ "itemId", "status", "claimants", "shares": [{participantId, amount}], "rounding": […] }],
                  "charges": [{ "chargeId", "status", "shares", "rounding" }],
                  "participants": [{ "participantId", "items", "tax", "tip", "fees", "discounts",
                                     "adjustments", "total", "itemShares": [{itemId, amount}] }] },
  "readiness": [{ "kind": "unclaimedItem", "itemId" }, { "kind": "openDispute", "disputeId" }, …],
  "finalization": null | { "finalizedAt", "finalizedBy", "revision", "participants", "items",
                           "charges", "rounding", "payments", "total" },
  "assets": [{ "id" }],
  "viewer": { "participantId", "isHost" },
  "updatedAt",
  "kind": "group|temporary|groupReceipt",
  "unreviewed": [uuid],
  "expiresAt": null | "…", "closedAt": null | "…", "endReason": null | "allSquare|cancelled|expired",
  "payments": [{ "participantId", "amount", "state": "owed|reportedSent|disputed|confirmed", "confirmedAt",
                 "attempts": [{ "id", "provider", "destinationId", "state", "history", "externalReference", "amount" }] }],
  "paymentDestinationCount": 0 }
```

The receipt-split fields (October 2026) are additive; older clients ignore them. `unreviewed` lists
the non-host participants whose current share isn't reviewed: they never marked it, it was
flagged for review, or their total changed after they did. `payments` exists only on temporary
rooms after finalization; the host sees every payment, anyone else only their own.
`finalization.hostResolved` lists the people the host finalized without their review.

`allocation`, `readiness`, and `finalization` are computed by the server. The snapshot never
contains account IDs, credentials, invitation tokens, or image URLs.

### `POST /v1/receipt-rooms/{roomId}/commands` — mutate

```json
{ "commandId": "uuid", "idempotencyKey": "8–64 ASCII chars", "expectedRevision": 7,
  "type": "claim", "payload": { "itemId": "uuid", "request": "mine" } }
```

The server identifies the acting participant from the credential. It ignores any actor or role in
the body. On success it returns `200`:

```json
{ "commandId": "uuid", "applied": true, "replayed": false, "revision": 8, "room": Snapshot }
```

- `applied: false` means the command was valid but changed nothing (for example, setting the
  allocation a charge already has). The revision is unchanged.
- **Idempotency.** Retrying with the same `idempotencyKey` (scoped to the caller and room) returns
  the stored outcome with `replayed: true` and the current snapshot. The command is never applied
  twice. Reusing a key for a different request returns `422 idempotency_key_reused`.
- **Revisions.** The revision increases by exactly 1 for each applied command. A stale
  `expectedRevision` returns `409 revision_conflict` with the current snapshot and applies
  nothing.

| `type` | Who | Allowed states | `payload` |
|---|---|---|---|
| `claim` | any participant | open (host also resolving) | `{itemId, request: "mine"\|"share"}` |
| `claimUnits` | any participant | open (host also resolving) | `{itemId, units}`: how many of a line with a printed `quantity` (≥ 2) are the caller's; `0` removes their claim. The rest stays unclaimed for others. Refused for lines without a quantity (`422 item_quantity_unknown`), a line someone claimed whole or shared (`409 item_already_claimed`), a custom split (`409 item_has_custom_split`), or more than is left (`409 units_unavailable` with `available`). |
| `unclaim` | any participant | open (host also resolving) | `{itemId}` |
| `setItemSplit` | any participant | open (host also resolving) | `{itemId, split: {kind:"equal",members}\|{kind:"shares",weights}\|{kind:"exact",amounts}}` |
| `dispute` | any participant | open, resolving, readyToFinalize | `{target:{kind,id}, note?, disputeId?}` |
| `markReviewed` | any participant | open, resolving, readyToFinalize | `{}` |
| `resolveDispute` | host | open, resolving, readyToFinalize | `{disputeId, status:"resolved"\|"dismissed", note?}` (a note is required to dismiss) |
| `setChargeAllocation` | host | open, resolving, readyToFinalize | `{chargeId, allocation}` |
| `reviseReceipt` | host | open, resolving, readyToFinalize | `{receipt}` |
| `setPayerAcceptsFullReceipt` | host | open, resolving, readyToFinalize | `{accepts: bool}` |
| `removeParticipant` | host | open, resolving, readyToFinalize | `{participantId}`, which also revokes that guest's credential |
| `transition` | host | open, resolving, readyToFinalize | `{move: "beginResolving"\|"reopenClaims"\|"requestFinalReview"\|"returnToRoom"}` |
| `cancel` | host | open, resolving, readyToFinalize | `{}` |
| `reportPayment` | someone who owes (temporary rooms) | finalized, not closed | `{provider, destinationId?, reference?}`; `destinationId` must be one the payer chose for this room |
| `cancelPaymentReport` | the reporter | finalized, not closed | `{}` |
| `confirmPayment`, `rejectPayment`, `disputePayment` | the payer only | finalized, not closed | `{participantId, reason?}` |

A non-host can split an item only among people who already claimed it, plus themselves
(`cannot_include_others`), and can't drop anyone else's claim that way (`cannot_remove_others`).
Unit claims and other claim modes never mix on one line. Any command on a closed temporary room
returns `409 room_closed`; on an expired one, `410 room_expired`. Notes are optional and at most 140 characters.

### `POST /v1/receipt-rooms/{roomId}/finalize` — host

This is the same envelope as a command; `type` is implied. The room must be `readyToFinalize`, with
no open disputes and totals that reconcile exactly. The response includes
`room.finalization`: the authoritative per-person totals, item and charge shares, rounding, and
the payments owed to the payer. Finalizing an already-finalized room returns `200` with
`applied: false` and the same finalization, so a retry can never create a second expense.

Temporary rooms and group receipts also need every participant's share reviewed. The host may
finalize anyway only by naming each unreviewed person in `payload.acknowledgeUnreviewed`
(`409 unreviewed_shares` with `participantIds` otherwise); they're recorded in
`finalization.hostResolved`. Unclaimed items always block finalization; nothing is assigned
silently. Finalizing a temporary room creates one `owed` payment per participant with a positive
total (other than the payer) and moves `expiresAt` to the payment deadline
(`SQUAREUP_TEMPORARY_ROOM_PAYMENT_DAYS`, 30). If nobody owes anything, it closes immediately.

### `GET /v1/receipt-rooms/{roomId}/payment-destinations` — temporary rooms

The payer's chosen payment methods: `{"recipient": {participantId, displayName}, "destinations":
[…]}`. Only for someone who still owes the payer (or the payer); anyone else gets
`403 reveal_not_allowed`. `Cache-Control: private, no-store`; rate limit `reveal`.

## Invitations

### `POST /v1/receipt-rooms/{roomId}/invitations` — host

`{"expiresInHours": 48, "maxGuests": 8, "revokeExisting": false}` (all optional) →
`201 {"invitation": {invitationId, createdAt, expiresAt, revokedAt, maxGuests, guestCount, capabilities, url, token, code}}`.

`code` is the invitation's short code: 12 Crockford Base32 characters (60 bits), shown as
`ABCD-EFGH-JKMN`. Like the token, it's returned only once and only its SHA-256 is stored. Each
invitation has its own code; revoking the invitation turns off both.

The `url` is `https://<public origin>/r/<token>`. The token is 256 random bits and is returned
**only once**; the server stores only its SHA-256 hash. The URL contains no room ID, names, or
amounts.

### `GET /v1/receipt-rooms/{roomId}/invitations` — host

Lists invitations without tokens.

### `DELETE /v1/receipt-rooms/{roomId}/invitations/{invitationId}` — host

Revokes an invitation. Its link then returns `410 invitation_revoked`.

### `GET /v1/receipt-room-invitations/{token}` — preview (no authentication)

Returns `{"invitation": {status, roomState, expiresAt, host:{displayName}, merchant, date, currency, openSeats:[{id, displayName}], youAreParticipantId}}`.
The preview shows only the context someone needs before joining. It never includes items, claims,
or amounts. Unknown, malformed, and wrong tokens all return the same `404 invitation_invalid`.

### `POST /v1/receipt-room-invitations/{token}/join`

Body: `{"displayName": "Sam", "seatId": "uuid"?}`. The `Authorization` header is optional.

- **No credential:** creates a new guest participant (or claims `seatId`) and returns `201` with
  `{participantId, restored: false, credential, credentialExpiresAt, room}`. Store `credential` in
  the Keychain. It is never returned again.
- **Existing guest credential or account already in the room:** restores the same participant
  (`200`, `restored: true`, `credential: null`) without creating a duplicate.
- **Account (`Bearer`) not yet in the room:** joins as an account-backed participant with no guest
  credential.
- Finalized or cancelled rooms refuse new participants. Existing participants still restore to the
  read-only final state.

### `POST /v1/receipt-room-codes/preview` and `POST /v1/receipt-room-codes/join`

The same preview and join, by short code. The code goes in the JSON body (`{"code": "ABCD-EFGH-JKMN"}`,
plus `displayName` and `seatId` for join), never in the URL, so it can't reach a request log. Any
case, spaces, and dashes are accepted, and `O`/`I`/`L` are read as `0`/`1`/`1`. Unknown, malformed,
and wrong codes all return `404 invitation_invalid`. Rate limits: `code` (20 per minute) plus
`preview` or `join`.

The preview also returns `kind` (`group` or `temporary`) and `ended` (a temporary room that closed
or expired). Joining an ended room is refused (`409 room_closed`, `410 room_expired`), except that
an existing participant still restores to the read-only summary.

### `POST /v1/receipt-rooms/{roomId}/link-guest` — account

Body: `{"guestToken": "<guest credential>"}`. This binds an App Clip guest's participant to the
caller's account (milestone 4 §13). Claims and history stay with the participant, and the guest
credential is revoked.

## Temporary rooms ("Split with people now")

A temporary room is a receipt split with people at the table, without a group. The person who
scanned it paid, publishes it with `kind: "temporary"`, and invites people with a QR code (the
invitation `url`), the link, or the short code. Several invitations can be open at once; each can be
turned off.

| Stage | What happens |
|---|---|
| Open (`open`, `resolving`, `readyToFinalize`) | Guests join with a display name (guest credential) or as their account. Everyone claims, splits, disputes, and reviews. Ends at `expiresAt` (72 hours) unless finalized first. |
| Finalized | Shares are final. Each person who owes gets a payment (`owed`); the payer's chosen methods are revealed only to them. They report a payment (`reportedSent`); only the payer confirms or rejects it. |
| Closed (`closedAt`, `endReason`) | `allSquare` when every payment is confirmed, `cancelled` by the host, `expired` at the deadline (claiming or paying). Read-only. |
| Deleted | `SQUAREUP_TEMPORARY_ROOM_RETENTION_DAYS` (30) after it closed: the room, invitations, codes, guest credentials, and images. Until then participants can read the summary; afterwards `404 room_not_found`. |

Guest credentials for a temporary room last until the summary is deleted, so guests can still see
how it ended. The App Clip (prepared, not yet activated) uses only these routes.

## Receipt images

### `POST /v1/receipt-rooms/{roomId}/receipt-assets` — host

Raw JPEG body (`Content-Type: image/jpeg`, maximum 4 MB, at most 6 per room). The server removes
EXIF, GPS, XMP, ICC, and comment segments before storing the image in a private bucket. Returns
`201 {"assetId", "revision"}`.

### `GET /v1/receipt-rooms/{roomId}/receipt-assets/{assetId}` — participants

Streams the image through the API, with `Cache-Control: private, no-store`. There are no public or
long-lived URLs. Images are deleted 30 days after the room is finalized or cancelled. The
structured receipt data remains.

## Receipt intelligence (milestone 5)

AI interprets the receipt; Square Up validates every value deterministically; the person reviews
everything in the app. Every error below makes the app use its on-device parser instead.
**Accounts only** (`Bearer` or `Dev`); guests get `403 forbidden`, anonymous callers `401`.

### `POST /v1/receipt-intelligence/parse`

Body (JSON, at most 8 MB; the ordinary 256 KB limit doesn't apply here):

```json
{ "schemaVersion": 1, "consent": { "mode": "automatic", "version": 1 },
  "locale": "en_US", "likelyCurrency": "USD",
  "pages": [{ "index": 0, "image": "<base64 JPEG>", "warnings": ["blurry"] }],
  "regions": [{ "id": "<client region id>", "page": 0, "order": 3, "text": "TRUFFLE FRIES 9.50",
                "confidence": 0.97, "box": [0.08, 0.31, 0.61, 0.02], "alternatives": ["TRUFFLE FRIES 9.58"] }] }
```

Limits: 1–6 pages, JPEG only, each 64–8,000 px per side and at most 6 MB decoded; at most 1,500
regions, 300 characters per region, 2 alternatives; warnings from `blurry`, `tooDark`,
`overexposed`, `lowContrast`, `edgesMissing`, `lowResolution`. Image metadata (EXIF, GPS, XMP, ICC,
comments) is stripped before anything else happens. Region IDs are replaced with short aliases
before the provider sees them, and mapped back in the response.

`200` response:

```json
{ "schemaVersion": 1, "provider": "anthropic", "model": "<model that answered>", "cached": false,
  "proposal": {
    "merchant": Field<string>, "date": Field<"YYYY-MM-DD">, "currency": Field<ISO 4217>,
    "items": [{ "name": Field<string>, "quantity": 2 | null, "unitPrice": 450 | null, "lineTotal": Field<int>, "isRefund": false }],
    "charges": [{ "kind": "tax|tip|serviceCharge|fee|discount|adjustment", "label": "Tax", "amount": Field<int> }],
    "subtotal": Field<int|null>, "total": Field<int|null>,
    "notes": [{ "kind": "blankCharge", "chargeKind": "tip" }],
    "warnings": [{ "code": "cardDetailsIgnored", "regionIds": [...] }],
    "overallConfidence": "high|medium|low" },
  "validation": { "issues": [{ "code": "totalMismatch", "difference": -200 }], "reconciled": false } }
```

`Field<T>` is `{ "value", "attention": "looksGood|check|needsResolution", "reason", "basis":
"visible|layout|arithmetic|absent", "regionIds": [client region ids] }`. Money is integer minor
units. Values are never changed to make the receipt balance: disagreements are reported as issues
(`totalMismatch`, `subtotalMismatch`, `quantityTimesPriceMismatch`, `possibleDuplicate`,
`negativeItemNotRefund`, `refundNotNegative`, `chargeSignInvalid`, `itemAmountMissing`,
`chargeAmountMissing`, `quantityUnreadable`, `totalNotPositive`, `unknownRegionReferences`) with
exact differences, and as attention reasons (`strongEvidence`, `lowConfidence`, `notFound`,
`multipleCandidates`, `ambiguousFormat`, `quantityMismatch`, `possibleDuplicate`, `invalidValue`,
`mathConflict`, `defaultValue`, `derived`, `evidenceMismatch`, `noEvidence`).

`502 ai_invalid_output` `reason` values: `not_json`, `schema_mismatch`, `output_too_large`,
`malformed_money`, `malformed_date`, `unsupported_currency`, `nothing_extracted`.

**Duplicates and cost.** An identical request from the same account (same stripped images, OCR
evidence, locale, currency hint, prompt, schema, and model) returns the stored result with
`cached: true` and no provider call, for 24 hours. A concurrent identical request gets
`409 ai_in_progress`. Rate limits (configurable): 6 per minute per account; 10 provider calls per day
per verified account; 50 per day across the project (cache hits are free).

**Verified email.** Only Firebase accounts whose ID token has `email_verified: true` may parse;
others get `403 email_not_verified`. The answer names the requirement and nothing else about the
account.

### `DELETE /v1/receipt-intelligence/cache`

Deletes this account's cached results (the app calls this when AI processing is turned off).
Returns `{"removed": n}`.

## Shared groups (milestone 7)

Long-lived P2P groups whose ledger the server holds. Every money amount is an integer in the group's
currency. Balances are **derived** by the server from expenses and confirmed settlements and
returned with every snapshot and change page; a client never sends one.

**Who may call.** Every route below except `GET /v1/account` and the invitation preview needs a
Firebase email/password or phone account **with a verified identity** (see Authentication) (`401 unauthenticated`,
`403 account_required`, `403 email_not_verified`); a development account on a local server counts as
verified. Reads and commands are scoped to the caller's active membership. Room guest credentials
never authorize them.

**People.** A group starts with its creator as the only member and owner. Up to **25 active
members** (`409 group_full` with `limit: 25` when inviting or accepting beyond that); one owner; one
currency; one active membership per account per group (an account may be in many groups). Joining
never adds the new member to earlier expenses. A member who left or was removed keeps their name in
the history and loses access; they can be invited again as a new member.

### Account and profile

| Route | Purpose |
|---|---|
| `GET /v1/account` | `{"account": {"recoverable": bool, "emailVerified": bool, "phoneVerified": bool, "verified": bool, "profile": Profile or null}}`. Any signed-in account, verified or not, so the app can say what's missing. `phoneVerified` and `verified` are additive (October 2026); `verified` is what every other route requires. |
| `PUT /v1/account/profile` | `{"displayName", "locale"?, "currency"?, "memberId"?}` → `{"profile"}`. Creates the profile once (`memberId`: a fresh random UUID proposed by the app, else server-generated); afterwards updates the name and hints. Verified recoverable accounts only. |
| `PUT /v1/account/destinations/{id}` | Creates or replaces one payment destination: `{"provider", "value": {"kind": "phone"/"email"/"username"/"link"/"instructions", "value"}, "link"?, "label"?, "isEnabled", "isPreferred"}`. Validated again on the server (formats per provider; HTTPS links on the provider allowlist only). The first enabled method is preferred automatically. |
| `DELETE /v1/account/destinations/{id}` | Removes one; the next enabled method becomes preferred. |

Profile: `{memberId, displayName, locale, currency, destinations[], createdAt, updatedAt}`. Only the
owner receives their destination values from these routes.

### Groups

| Route | Purpose |
|---|---|
| `GET /v1/groups` | The account's active groups: `[{group, viewer, cursor, memberCount, confirmedNet, awaitingYourConfirmation}]`. |
| `POST /v1/groups` | Create: `{"groupId", "name", "details"?, "symbol", "currency", "simplifiesDebts"?}` → `201 {"snapshot", "created": true}`; repeating it is idempotent (`200`, `created: false`). Needs a profile. |
| `POST /v1/groups/publications` | Publish one local group (below). Up to 1 MB. |
| `GET /v1/groups/{groupId}` | Full snapshot (members only). |
| `GET /v1/groups/{groupId}/changes?after={cursor}` | Events after the cursor plus the current state of every entity they touched. `cursorExpired: true` (and nothing else) when the client is more than 300 events behind or the cursor is unknown — fetch the full snapshot; never guess. |
| `POST /v1/groups/{groupId}/commands` | One revisioned, idempotent command (below). |
| `GET /v1/groups/{groupId}/members/{memberId}/destinations` | A member's enabled destinations, **only** while the caller owes them in the plan or has a payment in progress to them; else `403 reveal_not_allowed`. `Cache-Control: private, no-store`. |
| `GET /v1/groups/{groupId}/expenses/{expenseId}/revisions` | Immutable revisions of one expense. |

A non-member gets `404 group_not_found` (existence isn't confirmed); a removed member gets
`403 not_a_member`. Room guest credentials never authorize these routes.

**Snapshot**

```json
{ "schemaVersion": 1, "serverTime": "…", "revision": 7, "cursor": 12,
  "group": { "id", "name", "details", "symbol", "currency", "simplifiesDebts", "ownerMemberId", "createdAt", "archivedAt", "revision", "publishedFromDevice" },
  "viewer": { "memberId": "uuid", "isOwner": false },
  "members": [{ "id", "displayName", "handle", "status": "active|pending|removed", "hasAccount", "addedAt", "joinedAt", "removedAt",
                "destinationProviders": ["venmo"] }],
  "expenses": [{ "id", "title", "merchant", "date", "total", "category", "splitMethod", "payments": [{"memberId", "amount"}],
                 "allocations": […], "note", "createdBy", "createdAt", "revision", "updatedAt", "updatedBy", "deletedAt", "deletedBy",
                 "receipt": { …frozen item split… } | null, "receiptOmitted", "roomId" }],
  "settlements": [{ "id", "fromId", "toId", "amount", "date", "recordedBy", "provider", "attemptId", "confirmedAt", "confirmedBy" }],
  "attempts": [{ "id", "payerId", "recipientId", "destinationId", "provider", "amount", "memo", "state", "history": [{"state", "actorId", "at", "note"}],
                 "externalReference", "settlementId" }],
  "balances": { "simplified", "payments": [{"payerId", "recipientId", "amount"}], "directPaymentCount", "simplifiedPaymentCount",
                "pendingAttemptIds", "confirmedNets": {"memberId": units}, "availableNets": {…} },
  "events": [{ "id", "sequence", "actorMemberId", "at", "kind", "data": {…structured effect…} }], "eventsComplete": true }
```

The account ID behind a seat is never sent. Payment notes (reject/dispute reasons, external
references) are visible only to the payer and recipient. Events carry no notes, receipt text, codes,
or destination values; the app writes readable text from `kind` and `data`.

**Commands** use the room envelope (`commandId`, `idempotencyKey`, `expectedRevision`, `type`,
`payload`) plus an optional `knownCursor`, which makes the response include `changes` since then.
The response is `{commandId, applied, replayed, revision, cursor, result, changes?}`. A retry with the
same key and envelope returns the original result; the same key with a different envelope is
`422 idempotency_key_reused`.

| Type | Who | Payload | Revision |
|---|---|---|---|
| `addExpense` | member | `{expense, split?, receipt?}` | validated against the current ledger |
| `updateExpense` | the expense's creator | `{expenseId, expense, expectedExpenseRevision, split?}` | `409 expense_conflict` when the expense changed |
| `deleteExpense`, `restoreExpense` | creator, or the owner (recorded with `byOwner: true` in the event) | `{expenseId}` | current |
| `adoptRoom` | the room's host | `{roomId, guestMembers?: {participantId: memberId}}` | current; exactly once per room |
| `startPayment` | payer | `{attemptId, recipientId, amount, provider, destinationId?, memo?}` | current |
| `advancePayment` | payer / recipient | `{attemptId, action: openHandoff/reportSent/confirm/reject/dispute/cancel, reason?, externalReference?}` | current |
| `updateGroup`, `setSimplification`, `addSeat`, `removeMember`, `transferOwnership`, `archiveGroup` | owner | … | **strict** (`409 revision_conflict` with `currentRevision`, `cursor`) |
| `leaveGroup` | member (not the owner) | `{}` | strict |

Membership rules: `leaveGroup` and `removeMember` need the person's net to be zero
(`409 member_has_balance` with `balance`) and no payment in progress (`409 member_has_open_payment`);
the owner can't leave (`409 owner_must_transfer`) or remove themself. `transferOwnership` goes only
to an active member and is recorded as `ownershipTransferred {fromMemberId, toMemberId}`.
`archiveGroup` needs every net to be zero (`409 group_has_balances`) and no payment in progress
(`409 group_has_open_payments`). Every membership and ownership change is an event
(`memberInvited`, `memberJoined`, `memberLeft`, `memberRemoved`, `ownershipTransferred`,
`groupArchived`). A payment may be for part of what's owed (any amount up to the planned
obligation); the rest stays in the plan.

Expense rules (ported from the app's engine): payments and allocations each add up to the total
exactly; every person is a seat (active or pending for new expenses; history may name removed
people); an `equal` split is recomputed from its people in order, and `shares`/`percentage` splits
must send `split` (weights, or percentages as decimal strings with at most four fraction digits) and
are recomputed with the same largest-remainder rule; zero shares are left out. An `itemized`
expense carries a frozen `receipt` whose per-person totals must equal its allocations. A change
that would alter the balance of anyone with a reported or disputed payment is refused
(`409 pending_payment_conflict`, `attemptIds`). `startPayment` and `reportSent` recompute the
obligation from the plan (`409 no_obligation`, `409 exceeds_obligation` with `owed`). Only the
recipient's `confirm` creates the settlement — exactly one per attempt (its ID is the attempt's).

### Receipts in a group ("Add to a group")

A host posts a reviewed receipt to a shared group with the active members who were there. It's a
*pending receipt allocation*: no live room, invitation, code, or guest. Each selected member claims
items, reviews, and disputes on their own device whenever they like; the host assigns, resolves,
cancels, or finalizes. Finalizing creates exactly one itemized group expense (its ID is the
receipt's). Until then the receipt never affects balances, the settlement plan, or payments.

| Type | Who | Payload |
|---|---|---|
| `postReceipt` | active member (becomes the host) | `{receiptId, receipt, participantIds, payerId?}`. The receipt must reconcile and use the group's currency. The host is always included; everyone must be an active member (`422 inactive_participant`); the payer must be one of them. At most 20 open receipts per group (`409 receipt_limit`). Posting the same ID again changes nothing. |
| `receiptCommand` | a selected member | `{receiptId, type, payload, expectedRevision}`, where `type` is a room command: `claim`, `unclaim`, `claimUnits`, `setItemSplit`, `dispute`, `markReviewed`, and host-only `resolveDispute`, `setChargeAllocation`, `reviseReceipt`, `setPayerAcceptsFullReceipt`, `removeParticipant`, `transition` |
| `finalizeReceipt` | the receipt's host | `{receiptId, expectedRevision, acknowledgeUnreviewed?}`. Same rules as room finalization, then the expense is recorded with `receipt.hostResolved`. Finalizing again returns the same `expenseId` and changes nothing. |
| `cancelReceipt` | the receipt's host | `{receiptId}` |

A receipt's `expectedRevision` is the receipt's own revision, not the group's: a stale one is
`409 receipt_conflict` with the receipt's current `room` view, and nothing is applied. Every change
is an event (`receiptPosted`, `receiptUpdated` with `change`/`itemId`/`revision`,
`receiptFinalized` with `expenseId`/`hostResolved`, `receiptCancelled`), so it syncs through the
group's change pages. A command response includes `receipt` (the fresh view).

The group snapshot and change pages carry `receipts: [{id, state, hostMemberId, payerId,
participantIds, merchant, date, currency, total, revision, createdAt, updatedAt, unreviewed,
expenseId, room}]`: open receipts plus those finished in the last 7 days. `room` is the full room
snapshot for the selected members and `null` for everyone else. The receipt image stays on the
host's device. `GET /v1/groups/{groupId}/receipts/{receiptId}` returns one view.
`GET /v1/groups` adds `openReceipts` and `receiptsNeedingYou` per group.

A member who joins later isn't added to an existing receipt. `leaveGroup` and `removeMember` are
refused while the person is on an open receipt (`409 member_has_open_receipt`); `archiveGroup`
while any receipt is open (`409 group_has_open_receipts`).

### Publishing a local group

```json
{ "publicationId": "uuid", "publisherMemberId": "uuid",
  "group": { "id", "name", "details", "symbol", "currency", "simplifiesDebts", "createdAt" },
  "members": [{ "id", "displayName", "handle", "removed" }],
  "expenses": [{ …expense fields…, "createdBy", "createdAt", "revision", "updatedAt", "updatedBy", "deletedAt", "deletedBy" }],
  "settlements": [{ "id", "fromId", "toId", "amount", "date", "recordedBy", "provider" }],
  "events": [{ "kind", "actorMemberId", "at", "data" }] }
```

The whole snapshot is validated before anything is written, then the group, its history, the
publisher's membership, and the publication record commit in one transaction. Every ID is kept. The
publisher's seat is the owner; everyone else is a `pending` seat. Receipt images and item details
are not uploaded (`receiptOmitted`). Legacy organization data (`kind` other than personal, funding)
and open payments are refused (`422 publication_invalid` with a `reason`). The same `publicationId`
and body return the original result (`200`, `created: false`); a different body is
`422 idempotency_key_reused`; a group ID that already exists is `409 entity_exists`.

### Invitations

| Route | Purpose |
|---|---|
| `POST /v1/groups/{groupId}/invitations` | Owner: `{"seatMemberId"?, "expiresInHours"?}` → an invitation view (below) plus `{code, url, appUrl}`. Each call makes a distinct single-use invitation. The `code` (20 Crockford Base32 characters = 100 bits, shown as `XXXX-XXXX-XXXX-XXXX-XXXX`) is returned once; only its SHA-256 is stored. `url` is `https://<server>/g/<code>` (an ordinary page, not a universal link unless Associated Domains are configured); `appUrl` is `squp://join-group/<code>`. A new seat invitation replaces the seat's earlier one. Default expiry 7 days. |
| `GET /v1/groups/{groupId}/invitations` | Owner: every invitation, without codes: `[{invitationId, status: unused/accepted/expired/revoked, seatMemberId, createdByMemberId, acceptedMemberId, createdAt, expiresAt, acceptedAt, revokedAt}]`. Records from before this release have no `acceptedMemberId`. |
| `DELETE /v1/groups/{groupId}/invitations/{invitationId}` | Owner: revoke an unused (or expired) invitation; an accepted one is `409 invitation_used`. |
| `GET /v1/group-invitations/{code}` | Safe preview, any caller: `{groupName, symbol, currency, inviterName, ownerName, memberCount (joined members), expiresAt, isSeatInvitation, alreadyMember}` — never the ledger, member names, or balances. |
| `POST /v1/group-invitations/{code}/accept` | Recoverable account with a profile: `{"displayName"?}` → `201 {"snapshot", "joined": true}`. A seat invitation binds the account to that seat (its history and ID stay); otherwise a new seat. Accepting again with the same account returns the group (`200`); another account gets `409 invitation_used`. |

Codes accept any case and optional separators. Errors: `404 invitation_invalid`, `410
invitation_expired`, `410 invitation_revoked`, `409 invitation_used`, `409 already_member`, `410
group_archived`, `409 seat_unavailable`, `409 group_full`, `403 account_required`, `403 email_not_verified`,
`409 profile_required`. Concurrent acceptances of one invitation create exactly one membership; the
others get `409 invitation_used` (or `200` for the same account). Seat invitations (`seatMemberId`)
remain for groups published from a device before invitations were per person.
Archiving a group, or transferring ownership, revokes the affected invitations.

### Direct invitations ("Find a person", October 2026)

Any active member can find an existing account by an email address or phone number they already
know and invite it. Nothing about the group changes until that person accepts in their own app:
they aren't listed, don't see the ledger, and don't count toward the 25 before then. Link and code
invitations above are separate and unchanged.

| Route | Purpose |
|---|---|
| `POST /v1/groups/{groupId}/people/lookup` | Member of a group that isn't archived: `{"email"}` or `{"phone"}` (E.164, e.g. `+16505550142`) → `{"match": {displayName, maskedIdentifier, status} or null}`. `status`: `available`, `invited` (an invitation is waiting), `member`, or `you`. `maskedIdentifier` looks like `s•••@example.com` or `•••• 0142`. |
| `POST /v1/groups/{groupId}/direct-invitations` | Member: the same body → `201 {"invitation": Sent}`. Looks the person up again. `404 invitee_not_found` (the same neutral wording as an empty lookup), `409 cannot_invite_yourself`, `409 invitee_already_member`, `409 invitation_exists` (one waiting invitation per person per group, whoever sent it), `409 group_full`, `410 group_archived`. |
| `GET /v1/groups/{groupId}/direct-invitations` | Member: the owner gets every one, anyone else the ones they sent, newest first: `[Sent]`. |
| `DELETE /v1/groups/{groupId}/direct-invitations/{invitationId}` | The sender or the owner: cancel one nobody answered → `{"invitation": Sent}`. `403 forbidden` for anyone else, `409 invitation_used` once answered. |
| `GET /v1/account/invitations` | The invitations waiting for this account, newest first (at most 50): `[{invitationId, status: "pending", groupName, symbol, currency, inviterName, memberCount, createdAt, expiresAt}]` — the same as a code preview; never the group's ID, ledger, members, or balances. |
| `POST /v1/account/invitations/{invitationId}/accept` | `{"displayName"?}` (default: the profile's name) → `201 {"snapshot", "joined": true}`; again with the same account → `200`, `joined: false`. A new member, recorded as `memberJoined`. `410 invitation_revoked` (cancelled, or its sender left), `410 invitation_expired`, `410 group_archived`, `409 invitation_declined`, `409 already_member`, `409 group_full`, `409 profile_required`. |
| `POST /v1/account/invitations/{invitationId}/decline` | → `{"invitation": {invitationId, status, respondedAt}}`; declining again changes nothing. The sender may invite again. |

Sent: `{invitationId, status, displayName, maskedIdentifier, invitedByMemberId, createdAt, expiresAt,
respondedAt}`, with `status` one of `pending`, `accepted`, `declined`, `cancelled`, or `expired`. A
waiting invitation ends when it's declined, cancelled, after 30 days
(`SQUAREUP_DIRECT_INVITATION_TTL_HOURS`), when its sender leaves or is removed, when the group is
archived, or when the person joins some other way. Someone else's invitation ID answers
`404 not_found`, like one that doesn't exist.

**Who can be found.** An account is findable by the email address Firebase verified and by the
phone number it verified, once it has a profile. The directory is refreshed whenever the app reads
`GET /v1/account` or saves the profile, and holds only a SHA-256 digest of each normalized
identifier (lower-cased email; E.164 number) mapped to the account. An identifier that stops being
verified on the account, or is verified by another account, stops finding the first one. A
development account's address is `<uid>@squareup.test`.

**Enumeration.** No account, an unverified one, and one without a profile all return the same
`{"match": null}`. Identifiers travel only in request bodies. Lookups (and invitations, which look
the person up again) are limited per account to 10 a minute and 60 a day (`group-lookup`,
`group-lookup-daily`), and need an active membership in a group that isn't archived. Logs record
only that a lookup happened and whether it matched — never the identifier, its digest, a name, or
an account ID.

## Demo workspaces ("Enter Demo", October 2026)

"Enter Demo" on the Welcome screen gives each device its **own** server-backed workspace of
fictional sample data. There is no shared demo login, and no Firebase account is involved.

### `POST /v1/demo/sessions` — no authentication

`201 {"session": {"token", "userId": "demo-…", "expiresAt", "profile"}}`. Creates a demo account
(`demo-<random>`, profile "Avery Lee") and seeds three shared groups by replaying ordinary group
commands as fictional people over the past four weeks:

- **Apartment 4B** — five expenses (equal and shares splits) and Jordan's Venmo payment to you,
  confirmed.
- **Tahoe Ski Weekend** — three expenses; you're owed the most here.
- **Friday Dinner Crew** — three expenses (one exact split); you owe Maya, Riley, and Noor.

Kept simple on purpose: nothing in the seed is waiting for you (no payment to confirm, no receipt to
review).

Every group's details say the people and amounts are fictional. The token is returned once; the
server keeps its SHA-256. Not rate limited; `503 demo_unavailable` when `SQUAREUP_DEMO_ENABLED=0`.

### `POST /v1/demo/reset` — `Demo` only

Deletes this workspace's groups (and anything created in them) and seeds them again; the name and
payment methods return to the seed. `200 {"profile"}`. Nothing outside this workspace changes.

### `DELETE /v1/demo/session` — `Demo` only

"Leave demo": deletes the workspace's groups, the rooms it hosts, its profile, and the credential.
Workspaces are also deleted by the hourly cleanup once they end (`SQUAREUP_DEMO_TTL_HOURS`, 168).

### What a demo account may do

Everything a verified account does in its own groups (expenses, payments, receipts, new shared
groups, its profile and payment methods), plus:

- **Receipt intelligence** with the same pipeline, on its own daily budget: at most 50 provider
  calls per demo workspace and 50 across all demos together per day (cache hits are free;
  `SQUAREUP_AI_DEMO_DAILY_LIMIT_PER_WORKSPACE`, `SQUAREUP_AI_DEMO_DAILY_LIMIT_PROJECT`). Demo scans
  never count toward a real account's or the project's real-account limits, which are unchanged.
  Past either limit: `429 ai_demo_limit` (with `retryAfterSeconds`), and the app reads the receipt
  on device instead.
- **Receipt rooms** ("Split with people now"): a demo hosts its own rooms. Guests and other demo
  accounts may join them; a real account gets `403 demo_restricted`, and so does a demo account
  joining a real room.

Refused with `403 demo_restricted`: "Find a person" (lookup and direct invitations), group
invitation links, and accepting a group invitation. A demo account is never in the account
directory, the fictional people's seats are bound to identifiers no credential can present, and
every group a demo creates is marked `demo` and deleted with the workspace.

## Web and platform

| Route | Purpose |
|---|---|
| `GET /g/{code}` | Group invitation page: shows the code and an "Open Square Up" link (`squp://join-group/{code}`). It never looks the code up and reveals nothing about the group. |
| `GET /r/{token}` | Invitation landing page for people without the app. It reveals nothing about the room (`Cache-Control: no-store`). It offers "Open in Square Up" (`squp://join/{token}`) and explains joining with the room's code. It mentions the App Clip and shows its Smart App Banner only when the team, app, App Clip, and App Store IDs are all configured. |
| `GET /.well-known/apple-app-site-association` | `applinks` for `/r/*` and `appclips`. Returns 404 until Apple identifiers are configured. |
| `GET /healthz`, `GET /readyz` | Liveness, and readiness (storage reachable). |
| `GET /tasks/cleanup` | Retention job (expired room, group, and direct invitations and their short codes, credentials, idempotency records, rate counters, cached AI results, finished rooms' images; closes expired temporary rooms and deletes them with everything they hold after retention). App Engine cron only (`X-Appengine-Cron`). |

## Rate limits (per client per minute, configurable)

| Scope | Default | Applies to |
|---|---:|---|
| `preview` | 60 | Invitation preview (token guessing) |
| `code` | 20 | Room short-code preview and join (code guessing), on top of `preview`/`join` |
| `join` | 20 | Join, link guest |
| `command` | 240 | Reads and commands |
| `publish` | 30 | Publish, create invitation |
| `asset` | 120 | Image upload and download |
| `intelligence` | 6 | Receipt intelligence parse requests |
| `intelligence-daily` | 10 per day (`SQUAREUP_AI_DAILY_LIMIT_PER_ACCOUNT`) | Receipt intelligence provider calls (cache misses) |
| `intelligence-global` | 50 per day, project-wide (`SQUAREUP_AI_DAILY_LIMIT_PROJECT`) | Receipt intelligence provider calls (cache misses) |
| `account` | 60 | Account, profile, and destination routes |
| `group-read` | 240 | Group snapshots, changes, lists, revisions |
| `group-command` | 120 | Group commands |
| `group-publish` | 10 | Creating and publishing groups |
| `group-invite` | 30 | Creating and revoking group invitations, direct invitations included |
| `group-invite-preview` | 30 | Group invitation previews (code guessing) |
| `group-invite-accept` | 10 | Accepting group invitations; accepting and declining direct ones |
| `group-lookup` | 10 | Finding a person by email or phone, and sending a direct invitation |
| `group-lookup-daily` | 60 per day | The same, per day |
| `reveal` | 30 | Revealing a member's (or a temporary room payer's) payment destinations |

A client is identified by its credential binding, or by a salted hash of its IP address when
anonymous.
