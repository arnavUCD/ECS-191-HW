# Square Up server

This is the authoritative backend for multi-device Live Receipt Rooms (milestone 4), hybrid AI
receipt intelligence (milestone 5), real multi-user P2P shared groups (milestone 7), and the receipt
split (October 2026: temporary "Split with people now" rooms and receipts posted to a group). It uses Python 3.13 and Flask blueprints, and runs on App
Engine Standard (Gunicorn) with Firestore in Datastore mode and a private Cloud Storage bucket.
See [`API.md`](API.md) for the `/v1` contract.

```text
squareup/
  domain/     pure money, allocation, readiness, and command engine (ported from the Swift engine)
  ledger/     shared-group ledger rules (splits, validation, balances, settlement plan, payment
              attempts) ported from the Swift LedgerEngine, and the group aggregate + commands
  intelligence/  receipt AI: settings + Secret, request/response schema, prompt, deterministic
              validation, provider boundary (Unavailable, Fake, Recorded, Claude), metrics
  services/   rooms, invitations, assets, rate limits, retention, accounts/profiles, shared
              groups (commands, changes, invitations, publication): every rule and transaction
  api/        thin Flask blueprints: parse → service → JSON
  auth/       Firebase ID tokens, room-scoped guest credentials, principals
  storage/    Store/Transaction boundary; MemoryStore (tests/local) and DatastoreStore
tests/        API, security, concurrency, idempotency, privacy, store contract, Swift parity
```

## Local development

```sh
python3.13 -m venv .venv
.venv/bin/pip install -r requirements-dev.txt
SQUAREUP_ALLOW_DEV_AUTH=1 .venv/bin/python main.py      # http://127.0.0.1:8080, in-memory storage
```

With `SQUAREUP_ALLOW_DEV_AUTH=1`, the header `Authorization: Dev <uid>` acts as an account. The
server refuses it when `SQUAREUP_ENV=production` or on App Engine. To reach the server from an
iPhone on the same network, set `SQUAREUP_BIND_HOST=0.0.0.0`.

To develop against the real storage adapter, use the Datastore emulator (installed with the
Google Cloud SDK `cloud-datastore-emulator` component):

```sh
# Either `gcloud beta emulators datastore start --no-store-on-disk --host-port=localhost:8081`, or the emulator
# binary directly (needs Java; the gcloud wrapper may prompt to install the beta component):
EMU="$(gcloud info --format='value(installation.sdk_root)')/platform/cloud-datastore-emulator/cloud_datastore_emulator"
"$EMU" create /tmp/squareup-dsemu && "$EMU" start --host=localhost --port=8081 --store_on_disk=false --consistency=1.0 /tmp/squareup-dsemu
export DATASTORE_EMULATOR_HOST=localhost:8081 DATASTORE_PROJECT_ID=squareup-emulator
SQUAREUP_STORAGE=datastore GOOGLE_CLOUD_PROJECT=squareup-emulator SQUAREUP_ALLOW_DEV_AUTH=1 .venv/bin/python main.py
```

### Two simulators against a local server

```sh
DATASTORE_EMULATOR_HOST=localhost:8081 DATASTORE_PROJECT_ID=squareup-emulator GOOGLE_CLOUD_PROJECT=squareup-emulator \
SQUAREUP_STORAGE=datastore SQUAREUP_ALLOW_DEV_AUTH=1 SQUAREUP_PUBLIC_BASE_URL=http://127.0.0.1:8080 \
.venv/bin/gunicorn --bind 127.0.0.1:8080 --workers 2 --threads 4 main:app
```

Then create `../App/Config/Remote.local.xcconfig` with `SQUAREUP_API_SCHEME = http`, `SQUAREUP_API_HOST = 127.0.0.1:8080`,
and `SQUAREUP_AUTH_MODE = development` (simulators share the Mac's loopback; a physical iPhone needs the Mac's LAN
address and `SQUAREUP_BIND_HOST=0.0.0.0`). The Swift end-to-end test runs against the same server:
`TEST_RUNNER_SQUAREUP_TEST_SERVER=http://127.0.0.1:8080 xcodebuild test -only-testing:SquareUpTests/LiveServerTests …`.

The two-device UI test runs the host and participant at the same time on two simulators (hand-off files in an
empty directory):

```sh
xcodebuild … build-for-testing
for role in "<host simulator id> testHostSharesResolvesAndFinalizes" "<second simulator id> testParticipantJoinsClaimsDisputesAndSeesTheResult"; do
  set -- $role
  TEST_RUNNER_SQUAREUP_TEST_SERVER=http://127.0.0.1:8080 TEST_RUNNER_SQUAREUP_TWO_DEVICE_DIR=/tmp/squareup-twodev \
    xcodebuild … -destination "id=$1" test-without-building -only-testing:"SquareUpUITests/SharedRoomUITests/$2" &
done; wait
```

Direct invitations ("Find a person") run the same way with
`DirectInvitationTwoDeviceUITests/testDirectInvitationRileyFindsMayaAndSeesHerJoin` and
`…/testDirectInvitationMayaAcceptsInGroups` (each app finds the other as `<development ID>@squareup.test`); the
one-simulator `DirectInvitationUITests` and `LiveSharedGroupTests` need only `TEST_RUNNER_SQUAREUP_TEST_SERVER`.

## Receipt intelligence (milestone 5)

`POST /v1/receipt-intelligence/parse` sends a receipt's processing image and Vision OCR evidence to
Claude, validates the answer against a strict schema and deterministically, and returns an editable
proposal. AI is **off by default**; the rest of the server never depends on it.

| Variable | Default | Meaning |
|---|---|---|
| `SQUAREUP_AI_PROVIDER` | `off` | `off`, `anthropic`, or `recorded` (development and evaluation only; refused in production) |
| `SQUAREUP_ANTHROPIC_SECRET` | — | Production: the Secret Manager **resource name** of the key, e.g. `projects/<project>/secrets/anthropic-api-key/versions/latest` (not the key) |
| `ANTHROPIC_API_KEY` | — | **Secret.** Local development only (ignored in production; see below) |
| `SQUAREUP_AI_MODEL` | `claude-opus-5-5` | The only place a model is named |
| `SQUAREUP_AI_EFFORT` | `medium` | `low` … `max` |
| `SQUAREUP_AI_REFUSAL_FALLBACK` | `default` | Server-side refusal fallback (`fallbacks: "default"`); `off` to disable |
| `SQUAREUP_AI_TIMEOUT_SECONDS` | `50` | Deadline per parse, including at most one retry |
| `SQUAREUP_AI_MAX_OUTPUT_TOKENS` | `16000` | |
| `SQUAREUP_AI_CACHE_HOURS` | `24` | How long a structured result (never the image) is kept for identical requests |
| `SQUAREUP_AI_RECORDED_DIR` | — | Recorded fictional responses for the `recorded` provider |
| `SQUAREUP_AI_DAILY_LIMIT_PER_ACCOUNT` | `10` | Provider calls per verified account per day |
| `SQUAREUP_AI_DAILY_LIMIT_PROJECT` | `50` | Provider calls per day across the whole project |
| `SQUAREUP_AI_MINUTE_LIMIT` | `6` | Parse requests per account per minute (cache hits included) |
| `SQUAREUP_AI_DEMO_DAILY_LIMIT_PER_WORKSPACE` | `50` | Demo Mode: provider calls per demo workspace per day (separate from the real-account limits) |
| `SQUAREUP_AI_DEMO_DAILY_LIMIT_PROJECT` | `50` | Demo Mode: provider calls per day across all demo workspaces together |

The daily limits count only requests that reach the provider; cache hits are free. The defaults are
deliberately conservative while paid AI is new.

**Verified email required.** `POST /v1/receipt-intelligence/parse` accepts only Firebase accounts whose
ID token says `email_verified: true` (the app's own check isn't enough). Others get `403
email_not_verified`, which names the requirement and nothing about the account. Deleting cached results
(`DELETE /v1/receipt-intelligence/cache`) works for any signed-in account.

### Setting the Claude API key (never in Git)

The key must never appear in Swift code, the Xcode project, `Info.plist`, Python source, fixtures,
documentation, Git history, or logs. The server reads it only from the environment, wraps it in a
`Secret` that refuses to print itself, and never logs it.

- **Local development:** either export it in the shell that starts the server, or put it in the
  gitignored `server/.env` (`main.py` loads that file locally; values already in the environment
  win; it is excluded from deployment by `.gcloudignore`):

  ```sh
  cd server
  printf 'SQUAREUP_AI_PROVIDER=anthropic\nANTHROPIC_API_KEY=' > .env   # then paste the key after "=" in an editor
  chmod 600 .env
  SQUAREUP_ALLOW_DEV_AUTH=1 .venv/bin/python main.py
  ```

  Avoid typing the key directly on a command line, where shell history keeps it.
- **Production:** the key lives only in Google Secret Manager (`anthropic-api-key`). The App Engine
  service account has `roles/secretmanager.secretAccessor` on that one secret.
  - `deploy.env` carries only the resource name:
    `SQUAREUP_ANTHROPIC_SECRET=projects/<project>/secrets/anthropic-api-key/versions/latest`.
  - At startup the server reads that version once with Application Default Credentials
    (`squareup/intelligence/secret_manager.py`). It verifies the payload's CRC32C checksum as Google
    documents, checks the key's shape, and wraps it in `Secret`.
  - The key is never placed in `Config`, Flask configuration, logs, exceptions, `app.yaml`, or
    storage. In production `ANTHROPIC_API_KEY` is ignored.
  - With `SQUAREUP_ENV=production` and `SQUAREUP_AI_PROVIDER=anthropic`, any failure **stops the app
    from starting** (fail closed). That covers a missing resource, not found, no permission, a
    disabled version, a checksum mismatch, or a malformed key. The log shows only a reason code
    such as `secret_permission_denied`.
  - Secret Manager is never contacted when AI is off, in the test suite, or when a provider is
    injected.
- **Deployment files:** `scripts/render_app_yaml.py` never copies `ANTHROPIC_API_KEY` and stops if
  any value looks like a key. `scripts/deploy.sh` refuses a `deploy.env` that contains
  `ANTHROPIC_API_KEY`, and runs the quality gate before loading `deploy.env`.
- If the key is ever exposed (in output, a file, or Git), revoke it in the Anthropic Console and
  create a new one.

### Evaluation (opt-in, paid)

```sh
.venv/bin/python scripts/run_receipt_eval.py            # every fictional receipt once, needs ANTHROPIC_API_KEY
SQUAREUP_RUN_LIVE=1 .venv/bin/python -m pytest -m live tests/test_live_claude.py   # two live tests; needs the key exported in the shell (the suite never reads .env)
```

The runner writes responses and usage to `../Shared/receipt-eval/results/claude/` (gitignored), and
the Swift test `ReceiptEvaluationTests` scores them. See `../Shared/receipt-eval/README.md`.

## Receipt split (October 2026)

After reviewing a receipt, the app offers two paths (API: [`API.md`](API.md)):

- **Split with people now**: a temporary room (`kind: "temporary"`). The scanner paid; people join
  with the QR code, link, or a 12-character short code (`/v1/receipt-room-codes/…`, code in the
  body). After finalization each person reports paying the payer and only the payer confirms. The
  room closes when everyone is confirmed, when the host cancels, or when it expires, and stays
  readable until retention ends, then the cleanup job deletes it with its invitations, codes, guest
  credentials, and images.
- **Add to a group**: a pending receipt allocation inside a shared group (`postReceipt`,
  `receiptCommand`, `finalizeReceipt`, `cancelReceipt` group commands). Only the selected active
  members see and act on it; it syncs with the group's change pages; finalizing creates exactly one
  itemized expense; it never affects balances before that. The receipt image stays on the host's
  phone.

Both use the room engine (`domain/engine.py`), including unit claims (`claimUnits`: "2 of 3 beers")
and the review rule (finalizing past an unreviewed share needs the host's explicit acknowledgement,
recorded as `hostResolved`). The parity fixture `../Shared/parity-fixtures/units-and-quantities.json`
runs here and in Swift.

| Setting | Default | Meaning |
|---|---:|---|
| `SQUAREUP_TEMPORARY_ROOM_TTL_HOURS` | 72 | How long a temporary room is open before it's finalized. |
| `SQUAREUP_TEMPORARY_ROOM_PAYMENT_DAYS` | 30 | After finalization: how long payments can be reported and confirmed. |
| `SQUAREUP_TEMPORARY_ROOM_RETENTION_DAYS` | 30 | After it closed or expired: how long the read-only summary stays. |
| `SQUAREUP_APP_STORE_ID` | — | The full app's App Store ID. Only with the Apple IDs below does `/r/` mention the App Clip. |

The App Clip target (`../App/SquareUpClip`) is prepared but **not activated**: see
[`../App/APP_CLIP_ACTIVATION.md`](../App/APP_CLIP_ACTIVATION.md). Its DEBUG build can be driven
against a local server:

```sh
SQUAREUP_SKIP_LOCAL_ENV=1 SQUAREUP_ALLOW_DEV_AUTH=1 SQUAREUP_PUBLIC_BASE_URL=http://127.0.0.1:8095 \
.venv/bin/gunicorn --bind 127.0.0.1:8095 --workers 1 --threads 8 main:app      # in-memory: one worker
xcodebuild -scheme SquareUpClip -destination 'id=<simulator>' -derivedDataPath /tmp/clip-dd build
xcrun simctl install <simulator> /tmp/clip-dd/Build/Products/Debug-iphonesimulator/SquareUpClip.app
TEST_RUNNER_SQUAREUP_TEST_SERVER=http://127.0.0.1:8095 xcodebuild … test-without-building -only-testing:SquareUpUITests/AppClipUITests
```

The two-device `SharedRoomUITests` above now runs "Split with people now": the host creates a
temporary room and the second simulator joins by typing its code.

## Shared groups (milestone 7)

Accounts (`/v1/account`, profile and payment destinations), shared groups (`/v1/groups…`), group invitations
(`/v1/group-invitations/…`), and the invitation page `/g/<code>` are documented in [`API.md`](API.md). The
server is authoritative: every command is revalidated against the ported ledger rules, applied with an
expected revision (strict for owner/membership changes, rebased for expenses) and an idempotency key, and
recorded as an event page that clients read with a cursor. Shared groups need a **recoverable** account
with a **verified identity** (Firebase email/password with `email_verified: true`, a phone number
Firebase verified with an SMS code, or `Dev` auth locally); anonymous accounts are refused with
`account_required` and unverified ones with `email_not_verified`. Phone codes are sent and checked by
Firebase only — there is no SMS endpoint here.

A group starts with its creator alone and holds up to 25 active members. The owner makes one single-use
invitation per person (code, link, and QR; 7 days; only a digest is stored) and sees each one's state
(unused, accepted, expired, revoked). Leaving, removal, and archiving need everyone involved to be square
with no payment in progress; ownership transfer is explicit and recorded. Seat invitations from groups
published before this remain readable and usable.

Local two-account testing uses dev auth (each simulator has its own Keychain, so its own `Dev` user ID). A
separate namespace and port keep it apart from other local servers, `SQUAREUP_SKIP_LOCAL_ENV=1` stops
`main.py` from loading `.env` (so no Claude key is read), and AI is off:

```sh
DATASTORE_EMULATOR_HOST=localhost:8081 DATASTORE_PROJECT_ID=squareup-emulator GOOGLE_CLOUD_PROJECT=squareup-emulator \
SQUAREUP_STORAGE=datastore SQUAREUP_DATASTORE_NAMESPACE=m7live SQUAREUP_ALLOW_DEV_AUTH=1 \
SQUAREUP_PUBLIC_BASE_URL=http://127.0.0.1:8093 SQUAREUP_SKIP_LOCAL_ENV=1 SQUAREUP_AI_PROVIDER=off \
.venv/bin/gunicorn --bind 127.0.0.1:8093 --workers 2 --threads 4 main:app
```

- Four Swift clients over real HTTP (separate invitations, a member who joins after an expense, the
  optimized plan paid and confirmed by each recipient, an unrelated member refused, leaving, identical
  balances everywhere) are part of the same suite (`fourPeople`).
- One simulator as the owner, with other people joining over HTTP as `Dev` accounts (several invitations,
  each accepted, one turned off, removing someone settled):
  `TEST_RUNNER_SQUAREUP_TEST_SERVER=http://127.0.0.1:8093 xcodebuild … test-without-building -only-testing:SquareUpUITests/MultiPersonGroupUITests`
- Two Swift clients over real HTTP (create, invite, join, multi-payer expense, stale-revision conflict, receipt
  adoption once, report → confirm, identical balances; publication with a lost response and seat binding):
  `TEST_RUNNER_SQUAREUP_TEST_SERVER=http://127.0.0.1:8093 xcodebuild … test -only-testing:SquareUpTests/LiveSharedGroupTests`
- Two simulators through the real UI (Riley creates and invites; Maya joins by `squp://join-group/<code>`; Riley
  adds an expense; Maya reports paying; Riley confirms on Home; both are square): run
  `SharedGroupUITests/testOwnerCreatesInvitesAddsExpenseAndConfirmsPayment` and
  `SharedGroupUITests/testMemberJoinsWithCodeSeesTheSplitAndPays` at the same time on two simulators, as in the
  receipt-room example above, with `TEST_RUNNER_SQUAREUP_TEST_SERVER=http://127.0.0.1:8093` and an empty
  `TEST_RUNNER_SQUAREUP_TWO_DEVICE_DIR`.
- The ledger parity fixtures in `../Shared/parity-fixtures/ledger` run here (`tests/test_ledger_parity.py`;
  re-record with `PARITY_RECORD=1`) and in `SquareUpTests/LedgerParityTests`.

The committed `../App/Config/Remote.xcconfig` points the app at production with real Firebase accounts (client
identifiers only — every secret stays here on the server; see `../App/DEPENDENCIES.md`, "Client configuration").
To use real Firebase accounts against a local server instead, override `SQUAREUP_API_SCHEME`/`SQUAREUP_API_HOST` in
`../App/Config/Remote.local.xcconfig` and run the server with `SQUAREUP_FIREBASE_PROJECT_ID` (no
`SQUAREUP_ALLOW_DEV_AUTH`).

## Quality gate

```sh
scripts/check.sh            # pytest (fake AI provider; live tests excluded), ruff, ruff format, mypy --strict, bandit, pip-audit
DATASTORE_EMULATOR_HOST=localhost:8081 scripts/check.sh   # also runs the full suite on DatastoreStore
```

The parity fixtures in `../Shared/parity-fixtures` run through the real services here and through
the Swift engine in `SquareUpTests`. After an intentional engine change, re-record them with
`PARITY_RECORD=1 .venv/bin/python -m pytest tests/test_parity.py`, then review the diff.

## Deploying to App Engine

Prerequisites, done once by the project owner (none of these values are stored in the repository):

1. A Google Cloud project with billing enabled. Run `gcloud app create --region=<region>`.
2. Firestore in **Datastore mode** for that project.
3. A private bucket with uniform bucket-level access and public access prevention:
   `gcloud storage buckets create gs://<bucket> --uniform-bucket-level-access --public-access-prevention`.
   Grant the App Engine default service account `roles/storage.objectAdmin` on that bucket only.
4. Firebase added to the same project, with the **Anonymous** and **Email/Password** sign-in
   providers enabled (shared groups require Email/Password accounts; Anonymous keeps device-only
   receipt rooms working). The iOS app reads the Firebase Web API key from its xcconfig (see
   `../App/Config`). Create two safe test accounts for the two-account check.
5. `cp .env.example deploy.env` and fill in `GOOGLE_CLOUD_PROJECT` and `SQUAREUP_ASSET_BUCKET`
   (and `SQUAREUP_FIREBASE_PROJECT_ID` if Firebase is a different project; `SQUAREUP_PUBLIC_BASE_URL`
   if invitation pages should use a custom origin). `index.yaml` includes the shared-group indexes.

Then run:

```sh
scripts/deploy.sh   # runs the quality gate, renders app.deploy.yaml from deploy.env, deploys app + cron + indexes
curl https://<project>.appspot.com/healthz
```

The invitation origin defaults to `https://<project>.appspot.com`. To enable App Clip invocation
and universal links, add `SQUAREUP_APPLE_TEAM_ID`, `SQUAREUP_APP_BUNDLE_ID`,
`SQUAREUP_CLIP_BUNDLE_ID`, and `SQUAREUP_APP_STORE_ID` to `deploy.env`. This requires a paid Apple
Developer Program team. Follow the ten steps in `../App/APP_CLIP_ACTIVATION.md`.

To deploy a changed backend without moving traffic, use `scripts/deploy.sh --no-promote`, verify the
new version at its own URL, and promote only after it passes; the previous version stays available
for rollback (`gcloud app services set-traffic default --splits=<old version>=1`).

## Security and privacy notes

- Logs are structured JSON. They include request ID, route template, status, latency, actor kind,
  and salted short hashes of room IDs. They **never** include tokens, credentials, names, item
  descriptions, notes, amounts, image object names, or exception messages. A test enforces this.
- Invitation tokens and guest credentials are 256-bit random values. Only their SHA-256 hashes are
  stored, and they are compared in constant time.
- Every mutation runs in one Datastore transaction (room, idempotency record, side records), or
  nothing is written.
- Receipt images are private objects, served only through authenticated API requests, with
  metadata removed. They are deleted 30 days after a room is finalized or cancelled, and with a
  temporary room when it's deleted. A temporary room's photo is uploaded only if the host turns it on;
  a receipt posted to a group never uploads its image.
- Room short codes are 60 random bits (12 Crockford Base32 characters), stored only as hashes, one per
  invitation, revocable, and expire with it. They travel only in request bodies (so no log exclusion is
  needed for them) and are rate-limited (`code`, 20 per minute per client, plus `preview`/`join`).
  Guest credentials for a temporary room last until its summary is deleted, then go with it.
- Request logging: the app logs each request with its route template only, and gunicorn's access log
  is off because it prints full paths. App Engine's own request log records full URLs, and six routes
  carry a secret in the path (group-invitation preview and accept, `/g/<code>`, room-invitation
  preview and join, `/r/<token>`). Those entries are dropped before storage by an exclusion on the
  `_Default` sink (below). See "Request-log exclusion".
- Shared groups: a non-member gets the same `404` as a group that doesn't exist. Group invitation
  codes are 100 random bits (20 Crockford Base32 characters), stored only as hashes, expire after
  `SQUAREUP_GROUP_INVITATION_TTL_HOURS` (default 168), can be revoked, and are single-use per seat. The
  preview shows only the group name, inviter, member count, and open seat names. Payment-destination
  details are revealed only to a member who currently owes that person (a planned payment or an open
  attempt) and the reveal is rate-limited. Only the recipient's confirmation creates a settlement.
  Group logs carry salted hashes of group IDs, never names, amounts, codes, or destinations.
- Receipt intelligence: images and OCR text sent for AI processing are held in memory for the
  request only and forwarded to Anthropic. Only the structured result is cached (24 hours, per
  account, deleted on request). `ai.parse` log events carry outcome codes, counts, sizes, token
  counts, latency, model, and a salted user hash — never receipt text, images, prompts, provider
  output, or credentials. Tests enforce this.

## Request-log exclusion (Cloud Logging)

Exclusion **`squareup-secret-token-request-urls`** on the `_Default` sink drops only App Engine's
platform request-log entries (`appengine.googleapis.com/request_log`) whose path carries a secret.
Application logs (route templates only), startup, readiness, errors, audit logs, and every other
request stay. Filter:

```
resource.type="gae_app" AND logName="projects/square-up-ecs-191/logs/appengine.googleapis.com%2Frequest_log"
AND (protoPayload.resource=~"^/v1/group-invitations/[^/?]+" OR protoPayload.resource=~"^/v1/receipt-room-invitations/[^/?]+"
     OR protoPayload.resource=~"^/g/[^/?]+" OR protoPayload.resource=~"^/r/[^/?]+")
```

- Inspect: `gcloud logging sinks describe _Default --project square-up-ecs-191`
- Update: `gcloud logging sinks update _Default --project square-up-ecs-191 --update-exclusion=name=squareup-secret-token-request-urls,filter='…'`
- Remove: `gcloud logging sinks update _Default --project square-up-ecs-191 --remove-exclusions=squareup-secret-token-request-urls`
- Verify with synthetic, non-production strings only (e.g. `/v1/group-invitations/SYNTHQQQQ…`), and a
  control request (e.g. `/readyz?probe=…`) that must still appear. A new or changed exclusion takes a
  few minutes to apply everywhere; test again after ~5 minutes.
- When adding a route with a secret in its path, add it here too.

Exclusion keeps secrets out of storage; it doesn't stop them leaving the client in a URL. **Planned
structural migration:** move secrets out of HTTP paths. Invitation pages would take the code in the
URL fragment (`/g/#<code>`, never sent to the server) and hand it to the app, and the API would take
it in an authenticated request body (`POST /v1/group-invitations/preview {"code"}`,
`POST /v1/group-invitations/accept {"code"}`, and the same for room invitations), keeping the old
routes for one release. After that the exclusion only guards older app versions and can be retired.

