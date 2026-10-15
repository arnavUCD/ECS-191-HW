# Square Up — Milestone 4

## Multi-Device Live Receipt Rooms and App Clip

**Status:** Planned, but paused pending professor approval and Apple Developer Program access  
**Starting point:** Milestone 3 provides receipt capture, on-device recognition, deterministic allocation, a complete local Receipt Room, repository boundaries, revisioned room commands, and idempotent ledger finalization.  
**Primary objective:** Turn the local Receipt Room into a real multi-device experience and let invited participants join it immediately through a production-quality App Clip.

> **Implementation hold:** Do not begin Milestone 4 implementation until the professor gives the project direction a green light and the team confirms access to an Apple Developer Program organization or individual membership. Preserve this document as the approved future specification. Until the hold is removed, do not create the production server, App Clip target, signing configuration, Associated Domains, App Store Connect records, or paid cloud resources.

> **Scope change (October 2026):** Square Up is now peer-to-peer only. Organization groups, roles, budgets, approvals, organization funding, and reimbursement management were removed from the product and are no longer planned. Shared rooms, invitations, guest identities, and the server below are unchanged. The App Clip remains paused. See `overview.md` and `App/ARCHITECTURE.md` (P2P scope and legacy compatibility).

---

## 1. Milestone outcome

At the end of Milestone 4:

1. A host creates or opens a receipt room in the full Square Up app.
2. Square Up publishes the room to the server and creates an HTTPS invitation URL.
3. The host shares the URL or presents a QR/App Clip Code.
4. A person without Square Up invokes the App Clip from that invitation.
5. The App Clip opens directly into the correct room rather than a generic landing screen.
6. The guest joins with a lightweight room-scoped identity.
7. The guest can claim, share, unclaim, review, and dispute receipt items.
8. Changes appear on the host's device and other participant devices.
9. The server enforces permissions, room revisions, exact financial allocation, and finalization readiness.
10. The host resolves remaining issues and finalizes one authoritative expense.
11. The App Clip offers the full app only after the guest has completed the immediate task.

The milestone is successful only when this real cross-device path works:

> Host opens room → shares invitation → guest invokes App Clip → joins → claims items → host sees changes → host finalizes

When Milestone 4 is authorized to begin, the App Clip will be a **required feature and release gate** for this milestone. It is not an optional stretch goal within Milestone 4.

---

## 2. Why the App Clip belongs in this milestone

Milestone 3 intentionally completed the product interaction locally before introducing networking. A useful App Clip requires infrastructure that did not yet exist:

- A room available outside the host's device.
- An authoritative server.
- A secure invitation URL.
- A temporary guest identity.
- Cross-device synchronization.
- Server-side permission and financial validation.
- A domain and App Clip invocation configuration.

Implementing these together ensures that the App Clip performs a genuine task instead of presenting a nonfunctional imitation of collaboration.

---

## 3. Locked decisions

### 3.1 App Clip is required

Milestone 4 cannot be declared complete without an App Clip target that joins and operates on a real server-backed room.

### 3.2 The server is authoritative

The client may present optimistic updates, but the server decides whether a room command is valid. The server must enforce:

- Room state.
- Actor identity and permissions.
- Membership or invitation authorization.
- Expected room revision.
- Claim validity.
- Exact-cent allocation.
- Dispute status.
- Finalization readiness.
- Idempotency.

No client—including the App Clip—may submit a calculated balance and have it accepted without server validation.

### 3.3 Course-compatible server stack

Use the server architecture already approved in `overview.md` unless course requirements change:

- Python 3.13
- Flask and Flask Blueprints
- Gunicorn
- Google App Engine Standard Environment
- Firestore in Datastore Mode through `google-cloud-datastore`
- Google Cloud Storage for receipt files that must be shared
- Versioned REST APIs
- HTTPS

Do not place server secrets in the iOS app or App Clip.

### 3.4 REST synchronization first

Use revisioned REST commands and efficient polling for the first multi-device implementation. Do not add a separate real-time vendor merely for this milestone.

The client will:

1. Fetch the current room and revision.
2. Apply a reversible optimistic change when appropriate.
3. Submit a command with the expected revision and idempotency key.
4. Accept the authoritative response or reconcile a conflict.
5. Poll while the room is active, using lifecycle-aware intervals.

The repository boundary must allow a future push or streaming transport without rewriting room UI or domain behavior.

### 3.5 Focused App Clip

The App Clip exists for one immediate task: participating in an invited Receipt Room.

It does not include:

- Receipt scanning.
- Group creation or administration.
- Full expense history.
- Settlement management.
- Organization dashboards.
- Profile customization.
- General app navigation.

### 3.6 Invocation URL

Use an HTTPS URL shaped like:

```text
https://<owned-domain>/r/<opaque-invitation-token>
```

Rules:

- The URL identifies an invitation, not raw database keys.
- The token must be unguessable and revocable.
- Do not put names, totals, merchant data, group names, or other private data in the URL.
- Both the full app and App Clip must handle the same invocation.
- If the full app is installed, the invitation must open the equivalent room experience there.
- Missing, invalid, expired, revoked, and already-finalized invitations need explicit states.

### 3.7 Lightweight guest identity

An App Clip participant may join without creating a permanent Square Up account.

The guest identity must be:

- Scoped to the invited room.
- Represented by a user-confirmed display name.
- Backed by a short-lived server credential stored securely on the device.
- Unable to access unrelated rooms or group history.
- Expirable and revocable.
- Upgradeable or linkable if the guest later installs the full app.

The host must be able to distinguish invited group members from temporary guests.

### 3.8 Existing deterministic financial behavior remains unchanged

The server implementation must port or independently reproduce the established financial rules with shared fixtures proving parity. Networking must not change the meaning of a claim, dispute, allocation, rounding decision, or finalized expense.

---

## 4. Required scope

### 4.1 Server foundation

- Versioned API under `/v1`.
- Environment-based configuration.
- Structured error responses.
- Health and readiness endpoints.
- Datastore models and indexes.
- Cloud Storage integration for shared receipt images or safe demo equivalents.
- Authentication and invitation authorization middleware.
- Request identifiers and privacy-safe structured logging.
- Idempotency for commands and finalization.
- Automated server tests.
- Local development configuration and documented deployment procedure.

### 4.2 Server-backed Receipt Room

- Create/publish a room.
- Fetch a room snapshot.
- Join through an invitation.
- Claim and unclaim items.
- Create and update shared claims.
- Create disputes.
- Resolve disputes as host.
- Mark a participant reviewed.
- Update charge allocation rules as host.
- Handle revision conflicts.
- Cancel or revoke a room.
- Finalize once.
- Preserve an auditable command history.

### 4.3 Full-app remote experience

- Remote `ReceiptRoomRepository` implementation.
- Clear local, syncing, synced, offline, conflicted, expired, and failed states.
- Invitation management.
- Share sheet integration.
- QR code display.
- App Clip invocation URL handling.
- Background/foreground polling behavior.
- Offline action policy and recovery.
- Transition from local Milestone 3 rooms to published rooms.

### 4.4 App Clip target

- A dedicated App Clip target associated with the full app.
- Shared room domain, repository, networking, and design-system code.
- Invocation parsing.
- Room preview and privacy disclosure.
- Lightweight identity entry.
- Claim, share, unclaim, dispute, and review actions.
- Running participant total.
- Synchronization and conflict UI.
- Finalized, expired, revoked, offline, and invalid-link states.
- Appropriate full-app suggestion after task completion.
- App Clip size and capability compliance.

### 4.5 Domain and App Store configuration

- Owned HTTPS domain selected before production invocation setup.
- Associated Domains capability on the full app and App Clip where required.
- Apple App Site Association file served correctly from the domain.
- Default App Clip experience configured in App Store Connect when distribution credentials are available.
- Invocation metadata and card artwork.
- QR/App Clip Code generation for valid room URLs.
- Full app and App Clip both tested against the same URL format.

---

## 5. App Clip user experience

### 5.1 Invocation

The user scans a QR/App Clip Code or taps a shared invitation. The system displays the App Clip card, and the selected action launches directly into the corresponding room.

The App Clip must also handle launches where the invocation URL is unavailable by showing a small, useful recovery screen rather than crashing or opening an unrelated room.

### 5.2 Loading and invitation validation

The initial screen should quickly communicate:

- Square Up identity.
- That the person is joining a shared receipt.
- A progress state while the invitation is validated.

Only after authorization should it reveal the room's permitted details.

### 5.3 Joining

For a new guest:

1. Show the inviter or room context allowed by the invitation.
2. Explain that the guest is joining only this receipt room.
3. Request a display name.
4. Confirm the name before creating the room-scoped identity.
5. Enter the room immediately.

If the guest already has a valid credential for the room, restore that identity without creating a duplicate participant.

### 5.4 Participating

The App Clip must support the essential Milestone 3 participant experience:

- Clearly display the active guest identity.
- List receipt items and their state.
- Filter or emphasize Mine, Unclaimed, Shared, and Disputed items.
- Claim an entire item.
- Join or configure a shared item.
- Undo a claim while allowed.
- Enter an exact or shares-based portion.
- Dispute an item with an optional note.
- Mark the guest's portion reviewed.
- Show the guest's item subtotal, charges, discounts, and total.
- Show whether the room is still resolving or ready.

Host-only actions must never appear as usable App Clip guest actions.

### 5.5 Completion and full-app suggestion

After the guest reviews their portion:

- Confirm that their response was saved.
- Tell them whether the host still needs to finalize.
- Allow them to reopen the room while the invitation remains valid.
- Offer the full app as a secondary next step.

Installing the full app must not be required to finish the invited task.

---

## 6. Invitation lifecycle

An invitation contains:

- Stable invitation identifier.
- Opaque public token or its secure hash.
- Room identifier.
- Creator identifier.
- Created and expiry times.
- Revocation state.
- Allowed capability set.
- Optional maximum guest count.

Required behavior:

- The host can create, copy, share, display, and revoke an invitation.
- Recreating an invitation may revoke the old token if the host chooses.
- A finalized or cancelled room no longer accepts new participation.
- Existing participants receive a clear read-only final state when appropriate.
- Repeated opening by the same guest restores the same room-scoped identity.
- Token validation is constant-time where relevant and never exposes internal identifiers.

---

## 7. Synchronization and conflict behavior

### 7.1 Room revisions

Every accepted mutation increments the authoritative room revision. Every command includes:

- Command identifier.
- Idempotency key.
- Actor credential.
- Room identifier.
- Expected revision.
- Typed payload.

### 7.2 Revision conflict

When a command uses a stale revision:

1. The server refuses the mutation without partially applying it.
2. The response includes the current safe room snapshot or enough information to refetch it.
3. The client removes or reconciles its optimistic state.
4. The interface explains what changed when user attention is required.
5. The user can retry against the latest revision.

### 7.3 Polling

- Poll frequently enough for an active room to feel collaborative.
- Slow or stop polling when the app is backgrounded or the room is inactive.
- Use backoff after failures.
- Avoid overlapping requests.
- Refresh immediately after returning to the foreground.
- Stop polling finalized, cancelled, revoked, or expired rooms after the final state is shown.

### 7.4 Offline behavior

The interface must distinguish:

- Viewing a cached snapshot.
- A command waiting locally.
- A failed command that needs retry.
- A conflict that needs review.

Financial commands must never appear confirmed until the server accepts them. If queued offline actions are supported, preserve their order and idempotency keys and make their pending status unmistakable.

---

## 8. Authentication and authorization

### 8.1 Full-app users

Choose and document the production identity provider before implementation. The existing candidates are Sign in with Apple, Firebase Authentication with server token verification, or the course-provided authentication method.

The selection must support:

- Stable user identifiers.
- Server-verifiable tokens.
- Group membership.
- Invitation creation.
- Room hosting.
- Future account recovery.

### 8.2 App Clip guests

- Guest onboarding must not require a full account.
- Guest credentials are restricted to the invitation and room.
- Guest tokens must expire.
- Sensitive credentials use Keychain-backed storage where available.
- A display name is not treated as secure authentication.
- Server authorization relies on the room-scoped credential, not the submitted name.

### 8.3 Authorization matrix

At minimum:

| Action | Host | Full-app participant | App Clip guest |
|---|---:|---:|---:|
| View invited room | Yes | Yes | Yes |
| Claim/share/unclaim | Yes | Yes | Yes |
| Create dispute | Yes | Yes | Yes |
| Mark own portion reviewed | Yes | Yes | Yes |
| Edit receipt values | Yes | No | No |
| Resolve disputes | Yes | No | No |
| Change charge strategy | Yes | No | No |
| Manage invitations | Yes | No | No |
| Finalize room | Yes | No | No |

The server enforces this matrix even if a modified client attempts a forbidden request.

---

## 9. API contract

Representative endpoints may include:

```text
POST   /v1/receipt-rooms
GET    /v1/receipt-rooms/{roomId}
POST   /v1/receipt-rooms/{roomId}/invitations
DELETE /v1/receipt-rooms/{roomId}/invitations/{invitationId}
POST   /v1/receipt-room-invitations/{token}/join
POST   /v1/receipt-rooms/{roomId}/commands
POST   /v1/receipt-rooms/{roomId}/finalize
GET    /v1/receipt-rooms/{roomId}/receipt-assets/{assetId}
```

Prefer one typed command endpoint for room mutations if it preserves clear validation and documentation. Do not create subtly different business rules across many handlers.

Every mutation response should include:

- Authoritative room revision.
- Resulting room state or typed delta.
- Command identifier.
- Whether the command was newly applied or returned from idempotency storage.

Errors should have stable machine-readable codes and safe user-facing meaning, including:

- Invalid invitation
- Expired invitation
- Revoked invitation
- Room finalized
- Room cancelled
- Unauthorized action
- Revision conflict
- Invalid allocation
- Unresolved dispute
- Rate limited
- Temporary server failure

---

## 10. Receipt-image sharing

App Clip guests should receive only the receipt material needed to participate.

Requirements:

- Do not expose a permanently public Cloud Storage URL.
- Authorize access through the room credential.
- Prefer short-lived signed delivery or an authenticated server route.
- Provide appropriately sized display images instead of original camera resolution when possible.
- Strip unnecessary metadata before upload.
- Never place receipt image URLs in logs or analytics.
- Delete or expire server assets according to documented retention behavior.
- The room must remain usable if the image temporarily fails to load by retaining structured item data.

---

## 11. Privacy and security

- Use HTTPS for every production request and invocation.
- Use opaque invitation tokens with sufficient entropy.
- Store only token hashes server-side when practical.
- Rate-limit invitation validation, joining, and commands.
- Validate all payload types, lengths, monetary bounds, and identifiers.
- Never trust client roles, totals, or room state.
- Do not put receipt contents or personal details in URLs.
- Do not log tokens, receipt text, item names, participant balances, or images.
- Redact identifiers in diagnostics.
- Use least-privilege Cloud credentials.
- Document data retention and deletion.
- Allow the host to revoke an invitation.
- Expire temporary guest access.
- Protect against duplicate submission and replay.
- Include security-focused server tests.

---

## 12. App Clip size and shared code

The App Clip should compile only what it needs.

Share:

- Money and allocation value types.
- Receipt Room models and commands.
- Remote repository interfaces.
- Networking client.
- Relevant design tokens and components.
- Room participation feature models and views.

Exclude:

- Full SwiftData ledger stack unless strictly needed.
- Camera and Vision receipt pipeline.
- Group administration.
- Profile, settlement, organization, and analytics features.
- Unused sample assets and snapshot resources.
- Optional packages that do not serve the App Clip flow.

Measure the archive rather than assuming source-code size represents the final App Clip size.

---

## 13. Full-app transition

Apple replaces the App Clip experience with the full app after installation, so the full app must handle every supported room invitation URL.

Required behavior:

- Opening the same invitation in the full app navigates to the same room.
- A room-scoped guest identity can be safely linked or migrated after installation.
- The transition must not duplicate the participant.
- Existing claims remain associated with the participant.
- If linking cannot be completed automatically, explain the choice instead of silently creating a second identity.

---

## 14. Testing strategy

### 14.1 Shared financial fixtures

Run equivalent room-command fixtures against:

- The existing Swift domain engine.
- The Flask server implementation.

The results must match for allocations, rounding, readiness, permissions, revisions, and idempotency.

### 14.2 Server tests

Cover:

- Invitation creation, expiry, revocation, and invalid tokens.
- Guest creation and restoration.
- Authorization matrix.
- Claim and shared-item commands.
- Disputes and host resolution.
- Stale revisions.
- Simultaneous conflicting claims.
- Idempotent retries.
- Double finalization.
- Malformed and oversized payloads.
- Receipt-asset authorization.
- Rate limiting.
- Datastore transaction behavior.
- Cleanup and retention.

### 14.3 iOS repository contract tests

Run the same client scenarios against:

- In-memory repository.
- SwiftData/local repository where still applicable.
- Mock remote repository.
- Deployed test server.

### 14.4 App Clip tests

Test:

- Valid invocation URL.
- Missing invocation URL.
- Invalid, expired, revoked, finalized, and cancelled room.
- First-time guest join.
- Returning guest restoration.
- Claim, share, undo, dispute, and review.
- Stale revision conflict.
- Temporary offline and recovery.
- Full-app suggestion timing.
- Dynamic Type, VoiceOver, Voice Control, Reduce Motion, light mode, and dark mode.
- Full app installed versus not installed.

### 14.5 Real multi-device tests

Use at least two physical iPhones when possible:

1. Host opens the room in the full app.
2. Guest invokes the App Clip from QR or shared URL.
3. Guest claims an item.
4. Host sees the accepted claim without manual relaunch.
5. Host and guest attempt conflicting changes.
6. Both receive a clear authoritative result.
7. Host finalizes.
8. Guest sees the finalized read-only state.

Also test slow networking, connection loss, foreground/background transitions, and invitation revocation.

### 14.6 Production invocation testing

Local Xcode invocation is necessary but not sufficient. Before calling the milestone complete, test the configured App Clip experience through the intended distribution path and inspect Apple's App Clip diagnostics for domain or invocation problems.

---

## 15. Implementation sequence

### M4.1 — Server foundation

- Scaffold the Flask application and test infrastructure.
- Add configuration, health checks, Datastore, and Cloud Storage boundaries.
- Define versioned DTOs, errors, command envelopes, and idempotency.
- Implement privacy-safe logging.

**Exit condition:** A deployed test environment responds securely, persists test records, and passes its automated suite.

### M4.2 — Identity and invitations

- Implement full-app authentication choice.
- Implement room-scoped guest credentials.
- Implement invitation lifecycle.
- Add the authorization matrix and rate limits.
- Implement the HTTPS invitation route.

**Exit condition:** A valid invitation creates or restores only the authorized room participant, while invalid, expired, and revoked invitations reveal no room data.

### M4.3 — Authoritative remote rooms

- Port and validate room commands on the server.
- Add revisions, conflict responses, idempotency, and audit history.
- Add remote receipt assets.
- Add finalization protection.
- Prove Swift/server behavior using shared fixtures.

**Exit condition:** Two API clients can safely collaborate on one room and cannot violate allocation or permission rules.

### M4.4 — Full-app synchronization

- Implement the remote repository.
- Add publish/share/revoke controls.
- Add polling, optimistic states, conflicts, offline behavior, and recovery.
- Add universal-link/App Clip URL routing to the full app.

**Exit condition:** Two full-app installations can collaborate reliably through the deployed test server.

### M4.5 — Required App Clip

- Create the App Clip target.
- Minimize and share the correct modules.
- Handle invocation URLs.
- Build guest joining and the participant room UI.
- Add invalid/finalized/offline states and full-app transition.
- Confirm archive size and capability compliance.

**Exit condition:** A physical iPhone without Square Up installed can invoke the App Clip, join the intended deployed room, participate, and finish without installing the full app.

### M4.6 — Domain, App Store, and QR configuration

- Configure Associated Domains where required.
- Serve and validate the AASA file.
- Configure the default App Clip experience.
- Add card artwork and metadata.
- Generate and test QR/App Clip Codes.
- Verify that the full app handles the same links after installation.

**Exit condition:** The intended external invitation reliably launches the App Clip or full app with the correct room context.

### M4.7 — Reliability, accessibility, and release QA

- Complete automated tests.
- Perform two-device conflict and recovery testing.
- Complete App Clip accessibility review.
- Test slow/offline transitions and app lifecycle behavior.
- Run security and privacy review.
- Complete build, lint, format, and regression checks.

**Exit condition:** The definition of done is satisfied with recorded evidence.

---

## 16. Definition of done

Milestone 4 is complete only when:

- A deployed server provides authoritative Receipt Rooms.
- Full-app users can publish, share, revoke, and finalize rooms.
- Invitation URLs contain no sensitive data and are secure, expirable, and revocable.
- The App Clip is a real target associated with Square Up.
- A guest without the full app can invoke the App Clip into the correct room.
- The guest can join without creating a full account.
- The guest can claim, share, unclaim, dispute, and review their portion.
- The host sees accepted guest changes from another device.
- The server rejects unauthorized, stale, invalid, and over-allocated commands.
- Exact-cent financial behavior matches the Milestone 3 engine.
- Conflicting edits have understandable outcomes.
- Retried commands and finalization are idempotent.
- Receipt images are authorized and never publicly exposed.
- Offline and server-error states never appear falsely confirmed.
- Revoked, expired, cancelled, and finalized invitations behave correctly.
- Installing/opening the full app preserves the room context and prevents duplicate identity.
- The App Clip stays focused and satisfies applicable size restrictions.
- App Clip invocation is tested on physical hardware through the intended distribution configuration.
- Accessibility is verified with VoiceOver, Voice Control, Dynamic Type, and Reduce Motion.
- Milestones 1–3 continue to pass.
- Client and server automated tests pass.
- Client and server builds have no warnings relevant to the project.
- SwiftLint and SwiftFormat remain clean.
- Server dependency and security checks pass.
- Architecture, API, deployment, and testing decisions are documented.

---

## 17. Demonstration script

1. On the host's iPhone, open a reviewed receipt room.
2. Tap **Invite people**.
3. Display the invitation QR/App Clip Code.
4. On a second iPhone without Square Up installed, scan the code.
5. Show the App Clip card and launch it.
6. Confirm that the App Clip opens the correct room.
7. Join as a temporary guest.
8. Claim one item and join a shared item.
9. Show the updated amount on the guest device.
10. Show the accepted changes appearing on the host device.
11. Create a dispute from the App Clip.
12. Resolve it from the host app.
13. Demonstrate one revision conflict or connectivity interruption and recovery.
14. Mark the guest portion reviewed.
15. Finalize from the host app.
16. Show the finalized read-only state in the App Clip.
17. Show the optional full-app suggestion after the guest's task is complete.

---

## 18. External prerequisites

Production App Clip invocation requires items outside ordinary local coding:

- An Apple Developer Program team with the necessary signing and App Store Connect access.
- A final unique bundle identifier owned by the team.
- An owned HTTPS domain or an intentional use of Apple's supported default App Clip link.
- A deployed server reachable from participant devices.
- App Store Connect configuration and, for public distribution, Apple review.

These prerequisites must be identified early. Local App Clip invocation can support development, but it does not replace production-path validation.

---

## 19. Explicitly deferred from Milestone 4

The following are not required for this milestone unless separately approved:

- Foundation Models receipt structuring.
- Live Activities.
- SharePlay.
- Organization budgeting and approval workflows *(since removed from scope entirely)*.
- Payment-provider money movement.
- Advanced analytics and charts.
- Push notifications beyond what becomes strictly necessary for the chosen invitation flow.
- A general web application.

This keeps Milestone 4 centered on one exceptional experience: joining and completing a shared receipt instantly from another device.

---

## 20. Apple documentation references

- [App Clips](https://developer.apple.com/documentation/appclip)
- [Configuring App Clip experiences](https://developer.apple.com/documentation/appclip/configuring-the-launch-experience-of-your-app-clip)
- [Responding to invocations](https://developer.apple.com/documentation/appclip/responding-to-invocations)
- [Associating an App Clip with a website](https://developer.apple.com/documentation/appclip/associating-your-app-clip-with-your-website)
- [Testing the launch experience](https://developer.apple.com/documentation/appclip/testing-the-launch-experience-of-your-app-clip)
- [Encoding a URL in an App Clip Code](https://developer.apple.com/documentation/appclip/encoding-a-url-in-an-app-clip-code)
- [Associated Domains entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.associated-domains)
- [App Store Connect — App Clip experiences](https://developer.apple.com/help/app-store-connect/offer-app-clip-experiences/overview-of-app-clips)

---

## 21. Final implementation instruction

Build the server-backed room before presenting the App Clip as functional. Reuse the Milestone 3 room interface and domain boundaries, but treat the deployed server as the authority for every shared financial action. Keep the App Clip extremely focused, fast, private, accessible, and honest about connectivity.

Milestone 4 must not be declared complete because an App Clip target launches locally. Completion requires a real invited guest, on another physical device, participating in the same deployed room as the host.

---

## Implementation status (added during implementation; the sections above are the unchanged specification)

**Status as of October 6, 2026:** M4.1–M4.4 are implemented and tested locally. The server is not yet
deployed. **M4.5 (the App Clip) has not started**: by the course owner's instruction, work stopped before
creating the App Clip target, to check in first. Milestone 4 is therefore **not complete**.

### Decisions recorded (§8.1, §18)

| Decision | Choice | Notes |
|---|---|---|
| Full-app identity | **Firebase Authentication** | Anonymous on first share, then optional email upgrade with the same UID for recovery. REST API, no SDK. The server verifies ID tokens. See `App/ARCHITECTURE.md` |
| Domain | **App Engine default domain** (`https://<project>.appspot.com`) | No custom domain |
| Apple team | **Free (personal) team only** | Associated Domains, App Clip invocation, and App Store Connect are unavailable. See "External prerequisites" below |
| Server stack | Python 3.13, Flask blueprints, Gunicorn, App Engine Standard, Firestore in Datastore mode, private Cloud Storage | As locked in §3.3 |

### Phase status (§15)

| Phase | Status | Evidence |
|---|---|---|
| M4.1 Server foundation | Implemented; **not deployed** | `server/` with `/v1` REST, health and readiness, structured errors, request IDs, privacy-safe JSON logs, auth middleware, rate limits, idempotency, transactions, `app.yaml`, `cron.yaml`, `index.yaml`, `scripts/deploy.sh` |
| M4.2 Identity and invitations | Implemented | 256-bit opaque tokens stored as hashes; preview limited to permitted context; expiry and revocation; room-scoped hashed guest credentials (72 h sliding); seats; `link-guest` |
| M4.3 Authoritative rooms | Implemented | Python engine ported from Swift; every mutation carries command ID, idempotency key, credential-derived actor, room, expected revision, and typed payload; stale revisions are refused atomically with the current snapshot; finalization is idempotent; image uploads strip metadata and are served only through authorized routes; retention cron |
| M4.4 Full-app synchronization | Implemented, verified on two simulators against a local server | `RemoteRoomLedger` (the existing room screens on the server), publish, QR/link invitation with new-link and turn-off, join (preview, seat or name), polling, pending previews, conflict and offline recovery, guest matching, one local expense per finalized room |
| M4.5 App Clip | **Not started** (paused for check-in) | Server, guest credentials, `RoomAPIClient`, and `RemoteRoomLedger` already support a guest caller |
| M4.6 Domain, App Store, QR | Server side ready; Apple side externally blocked | The AASA route serves `applinks` and `appclips` once team and bundle IDs are configured; `/r/<token>` page includes the App Clip banner and a `squp://join` link; QR codes are generated in app |
| M4.7 Reliability and release QA | Partially done | Automated suites below; VoiceOver, Voice Control, Dynamic Type, and Reduce Motion review of the new screens and the physical two-device demo are still to do |

### Tests (§14)

| Layer | Result |
|---|---|
| Server `scripts/check.sh`: pytest, ruff, ruff format, mypy `--strict`, bandit, pip-audit | 71 tests pass on the in-memory store **and** on the real Datastore adapter (emulator); lint, types, and the security scan are clean; no known vulnerabilities |
| Shared parity fixtures (`Shared/parity-fixtures`, 7 scenarios) | Identical step outcomes and final allocations, rounding, readiness, and state in Python and Swift |
| iOS unit tests | 304 tests pass, including remote session (mock transport), mapping, links, configuration safety, and `adoptShared` |
| `LiveServerTests` (opt-in) | Two Swift clients over real HTTP against the Flask server on the Datastore emulator: publish, invite, seat join, claim, stale-revision conflict, host-only refusal, double finalize, totals parity, revocation |
| `SharedRoomUITests` (opt-in, two simulators at once) | Host shares, shows QR and link; participant joins by link as a seat, claims, sees the host's claims, disputes, marks reviewed; host sees the claim and dispute by polling, resolves, finalizes, and saves one expense; participant sees the read-only final split |
| SwiftLint / SwiftFormat | Clean |

### Definition of done (§16), current state

| Item | State |
|---|---|
| Deployed server | **Blocked:** needs the GCP project, Firestore (Datastore mode), private bucket, and Firebase setup (see server/README.md) |
| Publish, share, revoke, finalize from the full app | Done (local server) |
| Secure, expirable, revocable invitation URLs | Done |
| App Clip is a real target / guest invokes it / joins without an account / participates | **Not started** (paused) |
| Host sees changes from another device | Done (two simulators) |
| Server rejects unauthorized, stale, invalid, and over-allocated commands | Done (server tests) |
| Exact-cent behavior matches Milestone 3 | Done (parity fixtures; `adoptShared` refuses if totals differ) |
| Understandable conflicts; idempotent retries and finalization | Done |
| Images authorized, never public | Done (server tests); the full app does not yet upload the receipt photo to shared rooms |
| Offline and server errors never look confirmed | Done (pending previews, unsent changes, offline status) |
| Revoked, expired, cancelled, finalized invitations | Done (server tests and live tests) |
| Full app keeps room context, no duplicate identity | Join and restore are done; App Clip → full-app migration needs the App Clip and a shared container (see below) |
| App Clip size, physical-hardware invocation | **Not started / externally blocked** |
| Accessibility verification of new screens | To do |
| Milestones 1–3 continue to pass; builds clean | All 304 unit tests and all Milestone 1–3 UI tests pass. `testDoubleFinalizeCreatesOneExpense` failed once in the full run ("Missing option Friday Dinner Crew") on an overloaded simulator and passed on rerun. The receipt-room UI tests are slow (10–14 min each, same as the Milestone 3 baseline) because `actAs` scroll-searches for the pinned identity switcher |
| Documentation | `server/README.md`, `server/API.md`, `App/ARCHITECTURE.md` (Milestone 4), `App/DEPENDENCIES.md` |

### External prerequisites (§18): actions required from the project owner

1. **Google Cloud:**
   - Share the GCP project ID.
   - Enable billing, run `gcloud app create`, and create Firestore in Datastore mode.
   - Create a private bucket (uniform access, public access prevention).
   - Add Firebase with the Anonymous and Email/Password providers.
   - Fill `server/deploy.env` and the app's gitignored `Config/Remote.local.xcconfig`.
2. **Apple Developer Program (paid):** required for production App Clip invocation and App Clip experiences, Associated Domains (universal links and `appclips` in the AASA file), App Store Connect, and TestFlight distribution of the App Clip.
   - With the free team, the App Clip can only be built and run locally from Xcode (§14.6 production-path validation is not possible).
   - The full app opens invitations through `squp://join/<token>` or a pasted link instead of universal links.
