# Square Up App Clip — prepared, not activated

**Status: prepared but not activated.** The App Clip (`SquareUpClip` target) builds and runs in the
iOS Simulator, where its UI tests pass against a local development server (October 13, 2026). It has
never been signed for distribution, invoked from a real QR code, App Clip Code, or Smart App Banner,
uploaded to App Store Connect or TestFlight, or tested on a physical iPhone. That all needs a paid
Apple Developer Program team, which doesn't exist yet.

Temporary rooms ("Split with people now") do **not** depend on the App Clip:

- Anyone with the full app joins with the QR code (via the `/r/` page), the link, or the short code
  (Home → Join a receipt).
- The `/r/<token>` page tells people without the app to install it and use the code. It mentions the
  App Clip only once the server has `SQUAREUP_APPLE_TEAM_ID`, `SQUAREUP_APP_BUNDLE_ID`,
  `SQUAREUP_CLIP_BUNDLE_ID`, and `SQUAREUP_APP_STORE_ID` configured.

## What exists now

| Piece | Where | State |
|---|---|---|
| App Clip target | `SquareUpClip/` + `SquareUp.xcodeproj` (target `SquareUpClip`, scheme `SquareUpClip`) | Builds for the simulator; not embedded in the app |
| Shared code (full app and App Clip) | `SquareUpShared/` (room wire types, `JSONValue`, invitation links and codes) | Compiled into both targets, so they parse the same links and codes |
| Identifiers (placeholders) | `Config/AppClip.xcconfig` | App ID from the existing app; clip ID = app ID + `.Clip`; team and domain left empty |
| Entitlements | `Config/SquareUpClip.entitlements` | `parent-application-identifiers` only. Associated Domains are commented out until the team exists |
| Info.plist | `Config/SquareUpClip-Info.plist` | `NSAppClip` (no ephemeral notifications or location confirmation), server host from `Remote.xcconfig` |
| AASA | `GET /.well-known/apple-app-site-association` (server) | Returns 404 until the Apple IDs are configured; then `applinks` for `/r/*` and `appclips` |
| Smart App Banner | `/r/<token>` page | Shown only with all four Apple values configured |
| Local invocation test | Scheme `SquareUpClip` → Run → Environment `_XCAppClipURL` | Set it to a `https://<server>/r/<token>` link from a test room |
| Local UI tests | `SquareUpUITests/AppClipUITests` | Two tests drive the installed DEBUG clip against a local server (`-SUClipServer`, `-SUClipOpen`, DEBUG only): join by code, claim (whole and 2 of 3), review, final amount, report a payment, "all square", reopen; a turned-off invitation, then a typed code, then the host cancelling. Both pass in the simulator. See `server/README.md`. |
| Size (measured) | Release, arm64, unsigned (`CODE_SIGNING_ALLOWED=NO`) | **1.5 MB** uncompressed app bundle (1.6 MB binary, no assets). Not a thinned, signed archive; see step 10. |

The App Clip does one job only: join a temporary room as a guest (link, QR, or code), claim items
(whole, shared, or by quantity), dispute an item, review your share, see what you owe after
finalization, report a payment, and handle the expired, cancelled, and "all square" endings. It has
no scanning, Claude processing, groups, group receipts, profile, or history.

## Activation checklist (do this once the Apple Developer Program membership is active)

1. **Register the identifiers** (developer.apple.com → Certificates, Identifiers & Profiles → Identifiers).
   - App ID for the full app: the value of `SQUAREUP_APP_BUNDLE_ID` (now `edu.ucdavis.ecs191.SquareUp`).
     Enable **Associated Domains**.
   - App ID for the App Clip: `SQUAREUP_CLIP_BUNDLE_ID` (now `edu.ucdavis.ecs191.SquareUp.Clip`). It
     must begin with the full app's ID. Enable **Associated Domains** and **On Demand Install Capable**,
     and set the parent app.
   - Put the team ID in `DEVELOPMENT_TEAM` for both targets.
   - Optional: create an App Group (for example `group.<app ID>`) on both identifiers, so the full app
     can take over an App Clip guest's place (`/link-guest`) with the same credential.

2. **Add Associated Domains to both targets.**
   - App Clip `Config/SquareUpClip.entitlements`: `appclips:<domain>`.
   - Full app: `applinks:<domain>` and `appclips:<domain>`.
   - No path, slash, or wildcard: `appclips` doesn't accept `*.` subdomains.
   - Then add the App Clip to the full app target's **Embed App Clips** build phase, give the clip the
     full app's icon (an asset catalog with `AppIcon`), and set `DEVELOPMENT_TEAM` in
     `Config/AppClip.xcconfig`.
   - Keep `?mode=developer` only while testing development-signed builds.

3. **Configure the production AASA file** on the server (`server/deploy.env`):
   `SQUAREUP_APPLE_TEAM_ID`, `SQUAREUP_APP_BUNDLE_ID`, `SQUAREUP_CLIP_BUNDLE_ID`. Deploy with
   `scripts/deploy.sh --no-promote`, then check
   `https://<domain>/.well-known/apple-app-site-association` on that version:
   - it returns 200, JSON, with no redirect;
   - `applinks.details[0].appIDs == ["TEAM.<app ID>"]`, and components include `/r/*`;
   - `appclips.apps == ["TEAM.<clip ID>"]`.

   Promote only after that check. Apple's CDN fetches the file within about a day and can't be purged.

4. **Choose and validate the HTTPS invocation domain.** Today invitation links use
   `SQUAREUP_PUBLIC_BASE_URL` (the App Engine origin).
   - It must be HTTPS with a valid certificate, serve the AASA at `/.well-known/` with no redirects,
     accept any user agent (including `AASA-Bot` and `CFNetwork`), and every subdomain needs its own file.
   - If you move to a custom domain, map it in App Engine, then update `SQUAREUP_PUBLIC_BASE_URL`,
     `SQUAREUP_INVOCATION_DOMAIN`, and the app's `SQUAREUP_API_HOST`. Codes keep working whatever the link host is.
   - Add the new host to the Cloud Logging request-log exclusion for `^/r/` (server README,
     "Request-log exclusion").

5. **Create the App Clip Experience in App Store Connect** (the app record → App Clip section):
   - the default experience: header image 1800×1200, subtitle, and a call to action such as "View";
   - App Clip invocations only work after the experience is approved.

6. **Configure invocation URLs.**
   - Default experience: Apple's link plus the Smart App Banner on `/r/<token>`. Set
     `SQUAREUP_APP_STORE_ID` so the banner appears.
   - Advanced experience: register the prefix `https://<domain>/r/`. The most specific prefix wins, so
     keep it generic. Every room's link starts with it and carries the 256-bit token after it.

7. **Create App Clip Codes or QR experiences.**
   - The in-app QR code already encodes `https://<domain>/r/<token>`. Once the advanced experience for
     `/r/` is live, scanning it with the Camera opens the App Clip card.
   - App Clip Codes (App Store Connect → App Clip Codes, or the App Clip Code Generator) are optional
     for printed codes. Apple only supports QR, App Clip Code, and NFC invocations for clips that stay
     within the smaller size limit (see step 10).
   - Don't generate public codes before the experience is approved.

8. **Upload a TestFlight build.**
   - Archive the full app with the App Clip embedded and upload it.
   - Under TestFlight → App Clip invocations, add up to three test URLs, such as
     `https://<domain>/r/<test token>`. Testers need TestFlight 2.7+.

9. **Test on a physical iPhone, app installed vs. App Clip only.**
   - **Without the full app:** register a Local Experience (Settings → Developer → Local Experiences)
     for `https://<domain>/r/` with the App Clip's bundle ID, or use a TestFlight invocation. Then:
     scan the QR, see the card, join with a name, claim, review, see the final split, report a
     payment, and see the host confirm. Kill and relaunch the clip: it returns to the room.
   - **With the full app:** the same QR or link opens the full app (universal link) at the join
     screen, signed in, as an account-backed participant.
   - Both ways: an expired or revoked invitation, a cancelled room, a room that ended (read-only
     summary), and removal by the host (access ends).

10. **Measure the App Clip's size.**
    - Archive, then Distribute App → Development/Ad Hoc with App Thinning "All compatible device variants".
    - Read `App Thinning Size Report.txt` and keep every variant's **uncompressed** size under the limit:
      - **15 MB** while it supports physical invocations (QR, App Clip Codes, NFC) or iOS 16;
      - **100 MB** only for digital-only invocations on iOS 17+, or through an App Store Connect demo link.
    - Measured October 13, 2026 without signing: the Release arm64 build is a 1.5 MB uncompressed
      bundle, far under 15 MB. Measure again on the signed, thinned archive. Adding the app icon and
      header assets will add a little.

Until all ten steps are done and checked on a real iPhone, describe the App Clip as **prepared but not
activated**: not publicly invocable, not distribution-signed, not on TestFlight, not tested on a device.
