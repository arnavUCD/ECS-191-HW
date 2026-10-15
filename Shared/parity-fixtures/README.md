# Receipt Room parity fixtures (milestone 4 §14.1)

Each JSON file is one scenario executed by **both** the Swift engine
(`SquareUpTests/Milestone4/ParityFixtureTests.swift`) and the Flask server
(`server/tests/test_parity.py`). Both must produce identical claims outcomes, errors, allocations,
rounding, readiness, and finalization. Change a rule in one implementation and these fail.

## Format

- Every identifier is a short **key** (`"riley"`, `"fries"`). Both runners derive the same UUID:
  `sha256("<file name without .json>:<key>")` as hex `h`, formatted
  `h[0:8]-h[8:12]-4h[13:16]-8h[17:20]-h[20:32]`.
- `participants` are in room order; the first is the host. `payer` is a participant key.
- Money is integer minor units of `currency`.
- `steps[]`: `{ "actor", "command", "payload", "expect" }`.
  - `expect.applied` — `true` if the room changed, `false` for an accepted no-op.
  - `expect.error` — the API error code (e.g. `item_already_claimed`); nothing changes.
  - `"expectedRevision": "stale"` submits the revision from before the previous accepted step.
  - Disputes are referred to by the key given in the creating step's `"disputeKey"`.
- `expect` (final): per-participant totals, per-item and per-charge shares and status, rounding
  recipients, `remaining`, `readiness` (normalized strings), and `state`.
- Readiness strings: `<kind>` or `<kind>:<key>` (e.g. `unclaimedItem:pizza`, `openDispute:d1`,
  `receipt:totalMismatch`).
