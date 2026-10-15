# Square Up — Dependency Record

Policy: `HW/CLAUDE.md` §7. No package is added until a feature needs it. `Package.resolved` lives at
`SquareUp.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` and must be committed.

## Installed

### SnapshotTesting (Point-Free)

| Field | Value |
|---|---|
| Package | <https://github.com/pointfreeco/swift-snapshot-testing> |
| Version | 1.19.6, `upToNextMinorVersion` (resolved 1.19.6) |
| License | MIT |
| Target membership | `SquareUpTests` only — never linked into the app |
| Platforms | iOS 13+, Swift tools 6.0 |
| Maintenance | Release 1.19.6 published 2026‑09‑21; actively maintained |
| Transitive packages | swift-custom-dump 1.7.3, swift-issue-reporting 2.1.1, swift-syntax 604.0.0 (swift-syntax is only compiled for `InlineSnapshotTesting`, which we do not link) |
| Why native APIs are insufficient | Xcode has no built-in image-diffing assertion for regression testing across appearances, sizes, and Dynamic Type |
| Privacy | Test-only; no runtime code ships. Fixtures use sample people only. |
| Binary size / performance | None in the shipped app |
| Used by | `SquareUpTests/Snapshots/SnapshotTests.swift` (22 references), `PaymentSnapshotTests.swift` (20, milestone 2), and `ReceiptSnapshotTests.swift` (milestone 3) |
| Removal strategy | Delete the test file and package reference; logic tests are independent |

Notes: references are recorded on the **iPhone 18 Pro simulator, iOS 27.0, @3x**. Comparison uses exact pixel
matching at 99% (perceptual ΔE comparison was unstable on the simulator GPU and is not used).

### Firebase Apple SDK — FirebaseAuth and FirebaseCore (phone sign-in only)

| Field | Value |
|---|---|
| Package | <https://github.com/firebase/firebase-ios-sdk> |
| Version | **12.19.2, exact** (published 2026‑09‑15; 13.0 was a week old and is deliberately not adopted yet) |
| Products linked | `FirebaseAuth`, `FirebaseCore` — app target only (never the App Clip or tests directly) |
| License | Apache 2.0 |
| Platforms | iOS 15+ |
| Why native APIs are insufficient | Phone verification needs Firebase's app verification (silent APNs push, or its reCAPTCHA flow) before Firebase sends an SMS. That is only supported through the SDK's `PhoneAuthProvider.verifyPhoneNumber`; a homemade REST/SMS flow is neither supported nor safe. Email/password keeps using the existing REST client. |
| Scope in code | One file imports it: `Services/Auth/FirebasePhoneVerifier.swift` (plus the app delegate bridge, which talks to that class). The SDK only sends the code and signs in; the session it creates is handed to `AccountSession` and the SDK's own copy signed out. |
| Transitive packages resolved | GoogleUtilities 8.1.4, gtm-session-fetcher 5.3.1, interop-ios-for-google-sdks 101.0.0, app-check 11.3.2, promises 2.4.1, nanopb 2.30910.1, GoogleDataTransport 10.1.1, leveldb 1.22.5, abseil-cpp-binary, grpc-binary 1.69.1, GoogleAppMeasurement 12.19.2, google-ads-on-device-conversion 3.7.0. SwiftPM resolves the whole Firebase package graph; only what FirebaseAuth/FirebaseCore use is built and linked (no Analytics, Firestore, gRPC, or ads code ships). |
| Privacy | Firebase ships privacy manifests. FirebaseAuth declares user ID and diagnostic data, not used for tracking. Analytics is not linked; method swizzling is off (`FirebaseAppDelegateProxyEnabled` = NO). Phone numbers go to Firebase/Google for verification — disclosed on the phone screens. |
| Configuration | `Config/Remote.xcconfig` (committed client identifiers; an optional gitignored `Remote.local.xcconfig` overrides them) → Info.plist keys; no `GoogleService-Info.plist` in the bundle. With the values missing the SDK is never configured and phone sign-in is off. See `PHONE_AUTH_SETUP.md` and "Client configuration" below. |
| Removal strategy | Delete `FirebasePhoneVerifier.swift` and the delegate bridge, and the package reference; `LiveAuthBackend` then has no phone verifier and the app offers email only (the same as a build without the Firebase settings). |

### PhoneNumberKit

| Field | Value |
|---|---|
| Package | <https://github.com/PhoneNumberKit/PhoneNumberKit> (the maintained home; `marmelroy/PhoneNumberKit` now points here) |
| Version | **5.0.10, exact** (published 2026‑09‑16) |
| License | MIT |
| Target membership | App target only |
| Why native APIs are insufficient | iOS has no public phone-number parsing, validation, or as-you-type formatting for every country. Hand-written rules would quietly assume one country; this is libphonenumber's metadata (every region, its calling code, valid lengths and patterns, and formatting). |
| Used by | `Features/Auth/Phone/PhoneNumbers.swift` only (countries, formatting, validation, E.164). Firebase remains the authority on whether a number can receive a code. |
| Privacy | Ships a privacy manifest; no network access; numbers never leave the device through it. |
| Binary size | 365 KB of metadata (PhoneNumberMetadata.json) plus code. |
| Removal strategy | Replace `PhoneNumbers` with a smaller E.164 check (digits and `+`), accepting weaker formatting and validation. |

### SwiftLint 0.65.1 and SwiftFormat 0.63.1 (development tools)

| Field | Value |
|---|---|
| Install | Homebrew on the developer Mac (`brew install swiftlint swiftformat`) — not SPM, not in any target |
| License | MIT (both) |
| Configuration | `HW/App/.swiftlint.yml`, `HW/App/.swiftformat` (repository-owned) |
| Custom rules | `no_floating_point_money` (error), `no_print` (warning) |
| Current status | 0 lint findings; 0 files need formatting |
| Privacy / runtime | None — never shipped |
| Removal strategy | Delete the two config files |

Run from `HW/App`: `swiftlint` and `swiftformat --lint .` (CI) or `swiftformat .` (local).

## Evaluated and deliberately not installed

| Package | Decision | Reason | Revisit when |
|---|---|---|---|
| Nuke | Not installed | No remote images exist; everything is local. iOS 27 `AsyncImage` caching to be evaluated first. | Server-hosted avatars or receipts (milestone M2/M3 multi-user) |
| Rive / Lottie | Neither installed | No authored animation assets exist. Motion uses native `PhaseAnimator`, `KeyframeAnimator`, `symbolEffect`, `MeshGradient`. Only one of the two will ever be chosen. | A designer delivers an interactive asset (Rive preferred for state-driven art) |
| Pow | Still not installed (M2) | The settlement-confirmation moment was built natively (`MeshGradient`, `symbolEffect(.drawOn)`, spring motion, Core Haptics `settle`) and reads clearly; a particle effect would add a dependency without adding meaning (CLAUDE.md §7.2 discourages particles on money movement). | A designer approves a specific effect native APIs can't produce |
| Pulse | Not installed | No networking exists. | Flask/App Engine REST repositories (DEBUG only) |
| Sentry | Not installed | Beta crash reporting requires privacy scrubbing to be configured first (CLAUDE.md §7.2). | TestFlight beta with a scrubbing review |

## Milestone 2 decisions (no new dependencies)

Milestone 2 added **no packages**. Each payment capability uses a native framework or plain HTTPS:

| Need | Chosen | Not chosen and why |
|---|---|---|
| Apple Cash handoff | `MessageUI` (`MFMessageComposeViewController`) | No Apple Cash API exists for third parties; private or undocumented schemes are forbidden (spec §12) |
| Opening provider destinations | `UIApplication.open` with an HTTPS allowlist (`ExternalURLPolicy`) | Provider SDKs (PayPal Checkout, Braintree/Venmo, Cash App Pay) are **merchant checkout** products, not personal P2P; using them would misrepresent the flow (spec §12) and add PCI/merchant obligations |
| Embedded P2P money movement (Moov, etc.) | Not adopted | Explicitly deferred (spec §23); Square Up stays non-custodial |
| Clipboard | `UIPasteboard` with `.localOnly` and a two-minute expiry | — |
| QR codes for Zelle | Recipient-supplied official link only | No QR generation or scanning library needed in M2 |
| Provider logos | SF Symbols + text names | Third-party brand assets not added until their usage terms are reviewed (spec §17) |
| Payment-attempt sync | Local SwiftData only | Networking, push, and webhooks are server-milestone work; repository boundaries are ready |

`Package.resolved` is unchanged from Milestone 1.

## Milestone 3 decisions (no new dependencies)

Milestone 3 added **no packages**. Receipt intelligence and the Live Receipt Room use Apple frameworks only:

| Need | Chosen | Not chosen and why |
|---|---|---|
| Camera capture with edge detection, perspective correction, retake, multi-page | VisionKit `VNDocumentCameraViewController` | AVFoundation custom camera — VisionKit already delivers the required experience (spec §3.1) |
| Photos import | PhotosUI `PhotosPicker` (out of process; no library permission) | — |
| OCR | Vision `RecognizeTextRequest` (`.accurate`, on device) | Any cloud or third-party OCR — forbidden in M3 (§3.1, §14) |
| Image normalization, thumbnails, downsampling | ImageIO + Core Graphics | Image-processing packages |
| Duplicate-page fingerprint | CryptoKit SHA-256 | — |
| Structuring | Deterministic rules in `Core/Receipts` | Foundation Models is optional and not shipped in M3 (boundary: `ReceiptStructuring`) |
| Sample receipt fixture | Generated with AppKit by `Tools/make-sample-receipt.swift` (fictional content, committed output) | Real receipts — never committed (§14, §17.1) |
| Room sync | Local SwiftData only (`ReceiptRoomRecord`) | SharePlay/GroupActivities and networking are deferred until a server-backed room exists (§3.5–3.6) |

New Info.plist key: `NSCameraUsageDescription` ("Square Up uses the camera only to scan receipts you choose to
split. The text is read on this device and the image stays here."). Photos access needs no key because the
system picker runs out of process. `Package.resolved` is unchanged.

## Milestone 4 decisions

### iOS app — no new packages

The full app's shared Receipt Rooms use Apple frameworks only. `Package.resolved` is unchanged.

| Need | Chosen | Not chosen and why |
|---|---|---|
| HTTP + JSON | `URLSession` (ephemeral session: no cookies, no URL cache) + `Codable` | Networking wrappers (CLAUDE.md §7.3) |
| Account | **Firebase Authentication through its REST API** (`identitytoolkit` / `securetoken`) in `AccountSession` | Firebase iOS SDK — dozens of transitive modules, swizzling, and a larger App Clip for three HTTPS calls we can make directly; Sign in with Apple — needs the paid Apple Developer Program, which this project does not have (see `ARCHITECTURE.md` "Milestone 4") |
| Credential storage | Security framework Keychain (`KeychainStore`, this-device-only) | Keychain wrapper packages |
| QR code | Core Image `CIFilter.qrCodeGenerator()` | QR libraries |
| Parity fixture IDs | CryptoKit SHA-256 (test target) | — |

### Server (`HW/server/requirements.txt`) — each with a concrete need

| Package | Version | Why it is needed | License |
|---|---|---|---|
| Flask | 3.1.3 | Required stack (blueprints, request handling) | BSD-3 |
| gunicorn | 23.0.0 | App Engine Standard entrypoint (WSGI server) | MIT |
| google-cloud-datastore | 2.21.0 | Firestore in Datastore mode: transactions, queries (required stack) | Apache-2.0 |
| google-cloud-storage | 3.4.0 | Private receipt-image bucket (required stack) | Apache-2.0 |
| google-auth | 2.41.1 | Verifies Firebase ID tokens against Google's signing keys (`verify_firebase_token`) | Apache-2.0 |
| requests | 2.34.2 | Transport `google-auth` uses to fetch signing certificates | Apache-2.0 |
| CacheControl | 0.14.3 | Caches Google's signing certificates per their HTTP cache headers, so token verification doesn't fetch keys on every request | Apache-2.0 |

Development only (`requirements-dev.txt`): pytest, ruff, mypy (+ `types-requests`), bandit, pip-audit — tests, lint,
formatting, strict typing, security scan, and the dependency vulnerability audit run by `server/scripts/check.sh`.
Flask was raised from 3.1.2 and requests from 2.32.5 after `pip-audit` reported advisories (PYSEC-2026-2151,
PYSEC-2026-2275); the audit is now clean. Versions are pinned for reproducible deploys.

## Milestone 5 decisions

### iOS app — no new packages

AI receipt processing uses `URLSession`, `Codable`, ImageIO, and the existing account session.
The Anthropic API key never exists on the device; the app talks only to the Square Up server.
`Package.resolved` is unchanged.

### Server — one new runtime package

| Package | Version | Why it is needed | License |
|---|---|---|---|
| anthropic | 1.11.0 | The official Anthropic Python SDK: Messages API with structured outputs (`output_config.format`), effort, the server-side refusal fallback beta, and typed errors for the retry/timeout policy. Using the official SDK avoids hand-written HTTP for a security-sensitive integration | MIT |

Transitive (installed by pip, audited by `pip-audit`): httpx2 2.13.1, pydantic 2.13.5 (+ pydantic-core,
annotated-types, typing-inspection), anyio 4.15.1, jiter 0.17.0, sniffio 1.3.1, docstring-parser 0.18.0,
typing-extensions 4.16.0, h11, certifi, idna. `pip-audit -r requirements.txt`: no known vulnerabilities
(October 7, 2026). The SDK is imported lazily, so a server with AI off never loads it.
Removal strategy: delete `squareup/intelligence/anthropic_provider.py` and the pin; the provider
boundary and every other provider keep working.

### Evaluation tooling (not shipped)

`App/Tools/make-eval-receipts.swift` (AppKit, Core Image, Vision on macOS) and
`Shared/receipt-eval/build_cases.py` (standard library). No packages.

## Milestone 7 decisions (no new dependencies)

Milestone 7 added **no packages** to the app or the server. Shared groups use what is already here:
`URLSession` and `Codable` for the API, CryptoKit for the account-cache directory name, Core Image for the
invitation QR code (as in milestone 4), and Firebase Authentication through its REST API for email/password
accounts. On the server, the shared ledger is a pure-Python port of the Swift rules on top of the existing
Flask, Datastore, and Firebase token verification packages. `Package.resolved` is unchanged and `requirements.txt` has
the same packages as milestone 5; `pip-audit` reports no known vulnerabilities.

## Sign-in and first-run decisions (no new dependencies)

The account flow (welcome, sign-up, email verification, sign-in, password reset, profile setup)
adds **no packages**. Firebase Authentication stays on its REST API in `AccountSession`:

- `accounts:signUp`, `signInWithPassword`, `sendOobCode` (verification and reset), `lookup`, and
  `update`;
- `securetoken` for token refresh;
- `v2/passwordPolicy` for the project's password rules.

Everything the flow needs has a documented REST endpoint, so the Firebase iOS SDK still isn't
justified. The atmosphere is a native `MeshGradient`, and the Keychain stores the refresh token and a
pending invitation.

## Client configuration (committed on purpose)

`App/Config/Remote.xcconfig` is committed with the nine values a build needs to run the full app
against production: `SQUAREUP_API_SCHEME`, `SQUAREUP_API_HOST`, `SQUAREUP_AUTH_MODE`, and Firebase's
client identifiers (`SQUAREUP_FIREBASE_API_KEY`, `_GOOGLE_APP_ID`, `_GCM_SENDER_ID`, `_PROJECT_ID`,
`_IOS_API_KEY`, `_APP_URL_SCHEME`). A fresh clone therefore builds in Xcode and reaches sign-in, Demo
Mode, shared groups, live rooms, and AI receipt reading with no private setup.

These are **client identifiers, not secrets**: they ship inside every copy of the app (anyone can read
them from the binary), and on their own they grant no access. Firebase verifies who is signing in;
Square Up's server verifies every request's Firebase ID token (or its server-issued demo or guest
credential) and enforces every rule and limit. Every privileged value stays server-side and out of
Git: the Anthropic API key (Google Secret Manager), the deployment settings (`server/deploy.env`),
and the local development key (`server/.env`).

Recommended hardening in Google Cloud (Console → APIs & Services → Credentials): restrict the iOS key
to the bundle ID `edu.ucdavis.ecs191.SquareUp`, and restrict both keys to the APIs the app uses
(Identity Toolkit, Token Service; for phone sign-in, Firebase App Check/reCAPTCHA as required).

`App/Config/Remote.local.xcconfig` (gitignored, optional) overrides any of the nine values — for a
local server or another Firebase project. See `Remote.local.xcconfig.example`.
