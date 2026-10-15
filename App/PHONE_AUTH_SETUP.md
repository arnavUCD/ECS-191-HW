# Phone sign-in — setup you need to do

The app's phone sign-in is built (Firebase phone authentication through the Firebase iOS SDK; see
`ARCHITECTURE.md`, "Phone sign-in"). It stays **off** — the app offers email only — until the steps
below give the build a registered Firebase iOS app. Nothing here was changed for you in the Firebase
Console or Apple Developer; no IDs were made up.

What a read-only check of project `square-up-ecs-191` found on 13 October 2026:

| Setting | Now | Needed |
|---|---|---|
| Phone sign-in provider | Enabled | — |
| Fictional test numbers | 1 configured | Add the ones below (step 9) |
| SMS region policy | Allowlist with **no regions** — real numbers get no SMS | Step 1 |
| iOS app in Firebase | **None registered** | Step 2 |
| Authorized domains | `localhost`, `square-up-ecs-191.firebaseapp.com`, `square-up-ecs-191.web.app` | Fine for reCAPTCHA (step 3) |
| APNs key | Not checked (needs the paid Apple team) | Step 4 (optional) |

1. **SMS region policy.** Firebase Console → Authentication → Settings → SMS region policy → *Allow*
   only the regions you launch in (for example United States). An empty allowlist blocks every real
   number; fictional numbers still work.

2. **Register the iOS app.** Project settings → General → Add app → iOS, with bundle ID
   `edu.ucdavis.ecs191.SquareUp`. Download `GoogleService-Info.plist` but **don't add it to the
   project**. Copy these values into `Config/Remote.xcconfig` (committed: they're client
   identifiers that ship in the app, not secrets — see DEPENDENCIES.md "Client configuration"), or
   into the optional, gitignored `Config/Remote.local.xcconfig` to override them locally:

   ```
   SQUAREUP_FIREBASE_GOOGLE_APP_ID = <GOOGLE_APP_ID>      // 1:<number>:ios:<hash>
   SQUAREUP_FIREBASE_GCM_SENDER_ID = <GCM_SENDER_ID>
   SQUAREUP_FIREBASE_PROJECT_ID = square-up-ecs-191
   SQUAREUP_FIREBASE_IOS_API_KEY = <API_KEY>
   SQUAREUP_FIREBASE_APP_URL_SCHEME = app-<GOOGLE_APP_ID with ":" replaced by "-">
   ```

   The app checks that the URL scheme matches the app ID; if it doesn't, phone sign-in stays off
   (Firebase would otherwise stop the app). Keep the plist itself out of source control.

3. **API key and the reCAPTCHA domain.** Google Cloud Console → APIs & Services → Credentials. For the
   key in `SQUAREUP_FIREBASE_IOS_API_KEY`: if it has an iOS app restriction, it must list the bundle ID
   above; if it has HTTP referrer restrictions, add `square-up-ecs-191.firebaseapp.com/*`. Its API
   restrictions must include the Identity Toolkit API. (reCAPTCHA runs on
   `square-up-ecs-191.firebaseapp.com`, already an authorized domain.)

4. **APNs authentication key (needs the paid Apple Developer Program).** Apple Developer → Keys → new
   key with Apple Push Notifications service, then Firebase Console → Project settings → Cloud
   Messaging → Apple app configuration → upload the `.p8`, its Key ID, and your Team ID. Without it,
   phone sign-in still works: Firebase shows its reCAPTCHA check instead of verifying silently.

5. **Capabilities in Xcode.** Background Modes → *Background fetch* and *Remote notifications* are
   already in `Config/SquareUp-Info.plist`. **Push Notifications** is deliberately not added: a free
   (personal) team can't sign it, and adding it would stop the build installing on your iPhone. With
   the paid team: Signing & Capabilities → + Capability → Push Notifications (this creates the
   entitlements file with `aps-environment`).

6. **reCAPTCHA URL scheme.** The scheme from step 2 (`SQUAREUP_FIREBASE_APP_URL_SCHEME`) is already
   wired into the app's URL types. Square Up's own links (`squp://`, invitation pages) are unaffected:
   the app hands only Firebase's `app-…` redirect to Firebase.

7. **Physical iPhone, Background App Refresh on and off.** Settings → General → Background App
   Refresh. With APNs (step 4) and refresh on, verification is silent; with it off (or without APNs),
   Firebase opens reCAPTCHA in a sheet first. Both must reach the code screen.

8. **Simulator.** The Simulator can't receive APNs, so it always uses reCAPTCHA (step 3 must be done).
   For fictional numbers only you can skip the check with the DEBUG launch argument
   `-SUPhoneAuthTestNumbers` (`isAppVerificationDisabledForTesting`; never in Release builds).

9. **Fictional numbers for development.** Authentication → Sign-in method → Phone → *Phone numbers for
   testing*. Suggested (no SMS is sent, no quota is used):

   | Number | Code | Use |
   |---|---|---|
   | +1 650-555-3434 | 123456 | A new account |
   | +1 650-555-1234 | 123456 | An existing account (sign it up once, choose a name) |
   | +1 650-555-0123 | 123456 | Adding a number in Profile → Sign-in methods |

   The app's automated tests never call Firebase: they use an in-process stand-in with the same
   numbers and code.

## The server

`squareup/auth/identity.py` now accepts a Firebase-verified phone number as a verified identity
(email accounts still need `email_verified`). **It has to be deployed before phone accounts can use
groups, receipt rooms with an account, or AI processing** — until then the current server answers
`403 email_not_verified` for them. Deploy it the usual way (`scripts/deploy.sh --no-promote`, check the
new version, then promote) when you're ready.

## Manual tests once steps 1–3 are done

**Simulator (reCAPTCHA):**
1. Fresh install → Create account → the phone screen opens (not email). Type `650 555 3434`; it
   formats as `(650) 555-3434`.
2. Continue → reCAPTCHA sheet → solve → code screen showing "+1 650-555-3434" and "Resend code in 1:00".
3. Enter `123456` → "What should we call you?" → name → payment step → app.
4. Profile → Sign out → Sign in → `650 555 3434` → code → straight into the app (no name step).
5. Sign out, then **Sign in** with a fictional number that has no account yet (add one more in step 9,
   e.g. +1 650-555-0144) → after the code, the name step explains the number was new.
6. Code screen: enter `000000` → "That code isn't right"; Change number → back with the number kept.
7. Use email instead → the email form in place; Use phone instead → the number is still there; Back →
   Welcome with both choices.
8. Signed in with email: Profile → Account → Sign-in methods → Add phone number →
   `650 555 0123` → code → the number shows as Verified. Try `650 555 1234` (another account's) →
   "already used by another Square Up account"; nothing changes.

**iPhone with Background App Refresh on (after step 4):** steps 1–4 with your real number (in an
allowed region): no reCAPTCHA; the code arrives by text and iOS offers it above the keyboard — tap it
and the code verifies by itself. Leave for Messages mid-way, come back: still on the code screen.

**iPhone with Background App Refresh off:** the same, but expect the reCAPTCHA sheet before the text
is sent. Also force-quit Square Up on the code screen and reopen within 15 minutes: it returns to
the code screen for the same number.

Throughout: the app switcher shows the Square Up shield, not the number or code; nothing about the
number appears in Xcode's console.
