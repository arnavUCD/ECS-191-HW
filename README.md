# Square Up

Square Up is a native Swift/iOS app for splitting shared expenses with friends, roommates, and
travel groups, and for coordinating how everyone settles up. It is an ECS 191 (Homework Part 2)
interpretation of the core problem Splitwise solves: keep a fair, shared record of who paid for
what, show everyone where they stand, and make paying each other back simple.

**The core loop:**

> A bill arrives → **scan the receipt** → **review** the items and total the app read → **add it to a
> group** (assigning who had what) or **start a live room** for the people at the table → **split
> and settle**.

Square Up records and coordinates settlements that happen elsewhere (Apple Cash, Venmo, PayPal, Cash
App, Zelle, cash). **It never moves money itself**: it opens the payment app you choose, the payer
reports the payment, and the person being paid confirms that it arrived.

## Requirements

- A Mac running macOS with **Xcode 27** (the app targets iOS 27).
- An internet connection: Swift Package Manager downloads the app's dependencies on first build, and
  the app talks to Square Up's deployed backend.
- Optional: an iPhone on iOS 27, for the camera (see [Testing on an iPhone](#testing-on-an-iphone)).

## Build and run (clean clone)

1. Clone the repository and open the project:
   ```sh
   git clone <this repository's URL>
   cd <the cloned folder>
   open App/SquareUp.xcodeproj
   ```
2. Wait for Xcode to finish resolving Swift packages (Firebase, PhoneNumberKit,
   swift-snapshot-testing). The versions are pinned in `Package.resolved`.
3. Choose the **SquareUp** scheme and an **iPhone Simulator running iOS 27** as the destination.
4. Press **Run** (⌘R).

No configuration files, accounts, or keys need to be added: the project already contains the client
configuration for the production backend (see [Configuration and security](#configuration-and-security)).
The app opens on the Welcome screen.

To run it on your own iPhone instead, select the **SquareUp** target → *Signing & Capabilities*,
choose your own development team, and, if Xcode asks, give the bundle identifier a unique suffix.

## Try it with Enter Demo

On the Welcome screen, tap **Enter Demo** (below *Create account* and *Sign in*). In a few seconds the
app opens a demo workspace that belongs to your device alone. It's created on the server, with fictional
people, groups, and amounts:

- **Apartment 4B** (household costs, with a confirmed payment), **Tahoe Ski Weekend** (a trip), and
  **Friday Dinner Crew** (dinners where you owe a little). A **Demo** chip on Home marks it as sample data.

A good walk-through of the core loop:

1. On Home, tap **Scan receipt**, then **Scan with Camera** or **Choose from Photos**.
2. The first time, choose whether to use AI processing for receipts. With AI on, Claude reads the
   items; otherwise (or if AI isn't available) the receipt is read on the device.
3. **Review** the merchant, items, tax, tip, and total; anything uncertain is highlighted. Tap **Continue**.
4. Choose **Add to a group** → pick a group → choose who was there → assign who had what (or
   **Split everything equally**) → **Add**. The receipt becomes one itemized expense and balances update.
   Or choose **Split with people now** → **Create room and invite** to show a QR code and short code
   for the people at the table.
5. Open the group and tap **Settle up** to see who pays whom. Pay, then confirm received payments.

Other things to try: **Add expense** from Home, the **Groups** and **Activity** tabs, and
**Profile → Demo → Reset demo data** to put the sample data back (or **Leave demo** to delete it).

About the demo:
- Everything in it is fictional. It's kept apart from real accounts and groups, and deleted after a week.
- Inviting real people (invitation links, *Find a person*) is off in the demo. A live room opened
  from the demo can be joined from another device that's also in the demo (by its code or QR).
- AI receipt reading in the demo has a daily allowance. When it's used up, receipts are read on
  the device, and the review screen says so.

## Real accounts

Tap **Create account** or **Sign in** on the Welcome screen:

- **Email and password**: the account is created with Firebase Authentication, and Square Up asks
  you to confirm your email address (a link is sent to it) before the app opens.
- **Phone number**: Firebase sends a six-digit code by SMS; entering it signs you in or creates the
  account.
- After signing in, choose the name other people see. Each account's data stays separate on the
  device, and shared groups sync through the backend.

## Configuration and security

`App/Config/Remote.xcconfig` contains Square Up's **client configuration**: the production API host and
Firebase's client identifiers (project ID, app ID, and the public API keys used by Firebase
Authentication). They are included on purpose so a clean clone builds and runs: values like these
ship inside every copy of a mobile app and grant no access by themselves.

**All privileged keys stay on the server and are not in this repository.** The Claude (Anthropic) API key
lives in the backend's secret store. The server verifies every request: a Firebase ID token for an
account, or a credential it issued itself for a demo or a room guest. It also enforces every rule
and limit. An optional, git-ignored `App/Config/Remote.local.xcconfig` can override the client
configuration for local development; see `App/Config/Remote.local.xcconfig.example`.

## Testing on an iPhone

The Simulator runs the whole app, but some things are best checked on a physical iPhone:

- **Camera scanning.** The Simulator has no camera, so use **Choose from Photos** there (drag a receipt
  image onto the Simulator window to add it to Photos).
- **Phone-number sign-in.** Firebase can verify the app silently (no reCAPTCHA step) only on a
  physical iPhone whose build is set up for push notifications; in the Simulator, and on a device
  without that setup, it shows a reCAPTCHA check before sending the code.

## Repository layout

| Path | Contents |
|---|---|
| `App/` | The iOS app (SwiftUI): `SquareUp/` source and assets, `SquareUpTests/`, `SquareUpUITests/`, an App Clip target (prepared, not activated), `Config/` |
| `App/ARCHITECTURE.md`, `App/DEPENDENCIES.md` | How the app is built, and why each dependency is used |
| `server/` | The backend (Python/Flask): shared groups, live receipt rooms, Demo Mode, and receipt intelligence. See `server/README.md` and `server/API.md` |
| `Shared/` | Fictional fixtures shared by app and server tests (ledger parity cases, a receipt evaluation set) |
| `overview.md`, `milestone *.md` | Product definition and milestone plans |

## Tests

In Xcode, **Product → Test** (⌘U) runs the app's tests. Snapshot reference images aren't in the
repository, so the first snapshot test run records them (those tests report a failure until the
references exist). The backend has its own test suite, described in `server/README.md`.
