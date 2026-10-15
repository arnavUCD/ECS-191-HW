# Square Up — Claude Implementation and UI Engineering Guide

This file is the implementation brief for Claude when working inside `HW/App`. Read it completely before designing screens, adding packages, changing architecture, or writing application code.

**Apple documentation review date:** October 2, 2026. Recheck release notes and API availability after any Xcode or SDK upgrade.

The goal is not to produce a generic finance dashboard. Square Up should feel like a premium, modern, native iOS product: fast, calm, trustworthy, visually distinctive, accessible, and satisfying to use. Visual ambition must never compromise financial clarity or correctness.

## 1. Required context

Before making product or implementation decisions, read:

- `HW/overview.md` for the complete product definition, workflows, architecture, and scope.
- `HW/Proposal.md` for the submitted course proposal.
- The concept images in `HW/` for visual direction.

The concept images are inspiration, not pixel-perfect specifications and not permission to copy another product's branding. Extract the shared visual principles and build an original Square Up design system.

### Concept-image observations

The references consistently suggest:

- Near-black, edge-to-edge backgrounds.
- Elevated charcoal cards with soft separation rather than heavy borders.
- One highly recognizable accent color.
- Restrained aurora, mesh, and glow treatments for hero information.
- Large financial figures with excellent numeric alignment.
- Compact cards that communicate hierarchy immediately.
- Generous rounded corners and capsule controls.
- A floating or visually separated bottom navigation layer.
- Clear avatars and participant identity.
- Short, confident copy instead of dense explanatory paragraphs.
- Premium motion, depth, and tactile feedback.
- Light-mode capability even if the primary art direction is dark-first.

### Reference-image map

| File | Elements to study | How to reinterpret for Square Up |
|---|---|---|
| `12e5af2d2767683c4ff630eac755b7c3.jpg` | Electric onboarding color, avatar composition, bold primary CTA | Use for a short people-centered onboarding moment; reduce the saturation for the production palette |
| `33b4b725fbae3b3ce3ff1d02c503e827.jpg` | Dark detail screen, clear steps, strong bottom action | Use for invitations, settle-up steps, and payment-handoff explanations |
| `3f0dee21833a18248e32760ef415a5de.jpg` | Aurora balance card, compact action row, clean transactions, analytics tiles | Primary inspiration for the home hero, expense entry, and analytics hierarchy |
| `69824d083ce6dd0e4bdf3044d5f52e92.jpg` | Modular dashboard, category colors, circular visualization | Inspiration for group summaries and category colors without copying the banking layout |
| `a90da0fa8abaf93e791eb93130a12ca5.jpg` | Participant-first bill split, mint emphasis, selected avatar states | Inspiration for the Live Receipt Room and member-selection experience |
| `aa0cc54f470d7cee55b1117e4f87837f.jpg` | Violet hero gradient, premium dark surfaces, floating navigation, graph styling | Inspiration for signature motion and navigation depth |
| `d98ae0d2207f211773e6e69e3e852d02.jpg` | Extreme numeric hierarchy, central action, black/white contrast | Inspiration for simplified settlement and amount-entry screens |
| `e8c8e77cd1b2cf21a40a86dcaa5f41e1.jpg` | Bento-grid layout, large account card, restrained icons | Inspiration for the home dashboard and quick actions |

## 2. Product and experience principles

1. **Clarity before spectacle.** A balance, payer, payment state, or amount must never become harder to understand because of a visual effect.
2. **Native before imitation.** Prefer current SwiftUI and Apple platform capabilities over recreating web-style UI in Swift.
3. **Progressive complexity.** The common case (an equal split among friends) stays one short flow. Exact, percentage, share, multi-payer, and itemized options appear only when someone needs them.
4. **Identity is always visible.** Names, avatars, who paid, who is the host of a receipt room, and the active user must be unmistakable in shared financial actions.
5. **Every important state is explicit.** Reported, awaiting confirmation, confirmed, disputed, cancelled, settled, unclaimed, syncing, offline, and conflicted must have distinct labels and icons. Never rely on color alone.
6. **Motion explains change.** Animation should show where content came from, what changed, or whether an action succeeded. Decorative movement must remain subtle.
7. **AI proposes; humans confirm.** AI may extract and suggest. It must not silently finalize a financial action.
8. **Financial math is deterministic.** AI and UI code never become the source of truth for balances.
9. **Accessibility is a release requirement.** It is not a cleanup task.
10. **No dependency without a reason.** “State of the art” means using the strongest tool for the job, not maximizing package count.

## 3. Platform baseline

- Native iOS application.
- Xcode 27 and the course-required SDK.
- SwiftUI for the interface.
- Swift 6 language mode and strict concurrency should be adopted if the course project and all selected dependencies compile cleanly with it. If a dependency blocks the migration, document the blocker instead of disabling safety globally.
- Use Swift concurrency: `async`/`await`, structured tasks, actors, cancellation, and `Sendable` models where appropriate.
- Use Swift Package Manager for packages. Do not introduce CocoaPods.
- Keep the minimum deployment target as low as required for the actual tester devices. Gate newer visual features with availability checks when necessary.

### 3.1 Apple design and documentation are authoritative

For interface behavior, platform conventions, accessibility, and new SDK features, use Apple's current documentation before blogs, screenshots, or third-party examples. The concept images define mood; Apple defines correct platform behavior.

Required starting points:

- Apple Design portal: <https://developer.apple.com/design/>
- Human Interface Guidelines: <https://developer.apple.com/design/human-interface-guidelines/>
- Apple Design Resources: <https://developer.apple.com/design/resources/>
- WWDC26 Design guide: <https://developer.apple.com/wwdc26/guides/design/>
- WWDC26 iOS guide: <https://developer.apple.com/wwdc26/guides/ios/>
- SwiftUI documentation: <https://developer.apple.com/documentation/swiftui>
- SwiftUI updates: <https://developer.apple.com/documentation/updates/swiftui>
- SwiftUI sample code: <https://developer.apple.com/documentation/swiftui#Sample-code>
- Accessibility: <https://developer.apple.com/accessibility/>
- HIG accessibility guidance: <https://developer.apple.com/design/human-interface-guidelines/accessibility>
- HIG layout guidance: <https://developer.apple.com/design/human-interface-guidelines/layout>
- HIG color guidance: <https://developer.apple.com/design/human-interface-guidelines/color>
- HIG materials guidance: <https://developer.apple.com/design/human-interface-guidelines/materials>
- HIG typography guidance: <https://developer.apple.com/design/human-interface-guidelines/typography>
- HIG motion guidance: <https://developer.apple.com/design/human-interface-guidelines/motion>
- HIG writing guidance: <https://developer.apple.com/design/human-interface-guidelines/writing>
- App Review Guidelines: <https://developer.apple.com/app-store/review/guidelines/>

Apple's official iOS 27 UI kit and app-icon templates are available through Apple Design Resources for Figma and Sketch. Use the official Figma UI kit when producing detailed mockups so spacing, system bars, controls, and device conventions are current. Do not treat community UI kits as authoritative when an Apple template exists.

The design-review vocabulary should follow Apple's current principles:

- **Purpose:** every feature earns the user's time and attention.
- **Agency:** people remain in control and can undo or review consequential actions.
- **Responsibility:** privacy, safety, and AI failure modes are considered before release.
- **Familiarity:** controls that look the same behave the same.
- **Flexibility:** layouts and flows adapt to different people, devices, sizes, and abilities.
- **Simplicity:** remove friction, not necessary context.
- **Craft:** details, responsiveness, reliability, and longevity create trust.
- **Delight:** delight results from the whole experience, not decorative confetti.

Reference: <https://developer.apple.com/videos/play/wwdc2026/250/>

### 3.2 iOS 27 and Xcode 27 feature audit

Before beginning each major UI feature, check the current Xcode 27 SDK and the official SwiftUI “What’s New” material. The following 2026-era capabilities are relevant to Square Up:

- **Refreshed Liquid Glass:** standard navigation, tabs, toolbars, sheets, and controls receive the current system appearance automatically. Prefer those components before custom recreation.
- **Resizable iPhone interfaces:** build layouts that respond to the available scene size, including iPhone Mirroring and iPhone apps running in resizable contexts. Do not use fixed device assumptions, hard-coded screen dimensions, or `UIScreen.main.bounds` as a layout system.
- **Prominent tab role:** evaluate the current prominent-tab API for the central Add Expense action instead of forcing a custom floating tab bar. Confirm behavior with VoiceOver and keyboard navigation.
- **Toolbar visibility priority and automatic minimization:** use system toolbar behavior to preserve important actions when space is constrained.
- **Expanded swipe actions:** use native swipe actions for reversible, familiar row operations, but never hide the only route to a critical action behind a gesture.
- **Reordering improvements:** use native list, grid, and section reordering for user-controlled ordering where the product truly needs it.
- **Improved `AsyncImage` caching:** evaluate the latest native behavior before introducing a remote-image package.
- **Lazy initialization for Observable state:** use the latest state-management APIs to avoid expensive model creation before it is needed.
- **Live Preview resizing:** test views interactively across widths and sizes during development.
- **Advanced graphics composition:** layer SwiftUI drawing, layout, shader, timeline, and alignment APIs for signature visuals before adding a custom rendering engine.

Relevant official material:

- What’s new in SwiftUI, WWDC26: <https://developer.apple.com/videos/play/wwdc2026/269/>
- Compose advanced graphics effects with SwiftUI: <https://developer.apple.com/videos/play/wwdc2026/322/>
- SwiftUI advanced graphics sample: <https://developer.apple.com/documentation/swiftui/composing-advanced-graphics-effects-with-swiftui>

Latest-only APIs require an availability strategy. If real testers cannot run iOS 27, provide a clean fallback instead of raising the deployment target merely to use one visual effect.

## 4. Visual identity

### 4.1 Direction

Square Up should look like a confident financial utility for friends, roommates, couples, families, and trips, rather than a crypto wallet, casino, or gaming interface. Use glow and color to emphasize meaning, not to decorate every surface.

Recommended visual personality:

- **Foundation:** black, graphite, fog-white.
- **Primary accent:** electric mint or acid-lime used in controlled amounts.
- **Secondary accent:** violet for AI suggestions and other insight (never for money direction).
- **Semantic colors:** green for completed/received, amber for attention/pending, red for owed/destructive, blue for informational states.
- **Hero effect:** a restrained aurora or mesh gradient that combines mint, violet, blue, and a small warm highlight.

Do not use semantic green as the only primary brand color for every financial state. A person who owes money and a person who is owed money must be distinguishable through wording, sign, icon, and layout as well as color.

### 4.2 Initial design tokens

Create semantic tokens in `DesignSystem`, not hard-coded colors scattered across screens. Prefer Apple semantic system colors for standard labels, backgrounds, fills, and separators. Store custom brand colors in the asset catalog with light, dark, and increased-contrast variants. The hexadecimal values below are design references, not values to paste throughout runtime code.

Suggested starting values for design exploration:

| Token | Dark appearance | Light appearance | Purpose |
|---|---:|---:|---|
| `backgroundPrimary` | `#050505` | `#F6F7F8` | App background |
| `backgroundSecondary` | `#0B0C0D` | `#FFFFFF` | Secondary canvas |
| `surfacePrimary` | `#141516` | `#FFFFFF` | Standard card |
| `surfaceElevated` | `#1C1D1F` | `#F1F2F4` | Elevated card/sheet |
| `surfacePressed` | `#25272A` | `#E7E9EC` | Pressed/selected surface |
| `textPrimary` | `#F7F7F5` | `#111214` | Main text |
| `textSecondary` | `#A5A8AD` | `#62666D` | Supporting text |
| `textTertiary` | `#70747B` | `#8B9098` | Metadata |
| `accentPrimary` | `#B7FF3C` | `#69B900` | Primary action/highlight |
| `accentViolet` | `#8B5CF6` | `#7045D8` | AI suggestion/insight accent |
| `positive` | `#35D07F` | `#138A4B` | Received/complete |
| `warning` | `#FFB84D` | `#A86100` | Pending/attention |
| `negative` | `#FF5B64` | `#C72F3A` | Owed/destructive |
| `informational` | `#5EB7FF` | `#126DB2` | Neutral information |

These are starting points, not immutable values. Verify contrast in both appearances before approving them.

### 4.3 Typography

- Use San Francisco system fonts unless a deliberate brand typeface is licensed and tested.
- Use Dynamic Type styles, not fixed font sizes for ordinary content.
- Use rounded system design selectively for friendly hero numbers and onboarding headings.
- Use monospaced digits for balances, totals, percentages, and rapidly changing amounts.
- Use tabular alignment for transaction lists and comparisons.
- Keep financial hierarchy consistent: amount first, meaning second, metadata third.
- Avoid tiny gray text. Reference images often use text that would fail real accessibility requirements; improve it.

### 4.4 Layout and shape

- Base spacing unit: 4 points.
- Common spacing: 8, 12, 16, 20, 24, 32.
- Minimum touch target: 44 by 44 points.
- Standard card radius: 20–24 points.
- Compact card radius: 14–18 points.
- Capsule controls for filters, identity badges, status chips, and short actions.
- Use continuous rounded rectangles where available.
- Keep major horizontal margins consistent, normally 16–20 points.
- Do not nest multiple cards merely to create depth. Use spacing and typography first.

### 4.5 Iconography and imagery

- Use SF Symbols 27 as the default icon system and verify symbol availability against the deployment target.
- Choose one rendering mode per context; avoid mixing outline, fill, and multicolor symbols randomly.
- Use variable rendering for progress and changing values when it improves comprehension.
- Use Draw On/Draw Off, Magic Replace, Bounce, Wiggle, Rotate, and other symbol effects only when they explain an appearance, transition, state change, or response to input.
- Avatars should support photographs, initials, deterministic colors, group marks, and accessibility labels.
- Use identity and state badges that combine icon, text, and color: You, Payer, Host, Guest, Awaiting confirmation.

SF Symbols 27 includes more than 7,000 symbols, localized designs, variable rendering, multiple color-rendering modes, and expressive symbol animation. Prefer an existing symbol over drawing a custom glyph. If a custom symbol is necessary, build and annotate it using Apple's SF Symbols templates so weights, scales, localization, accessibility, and animation behave consistently.

- SF Symbols: <https://developer.apple.com/sf-symbols/>
- Apple Design Resources: <https://developer.apple.com/design/resources/>

Create the Square Up app icon with **Icon Composer** using a small number of meaningful layers. The icon must remain recognizable at small sizes and across default, dark, tinted, and accessibility appearances. Avoid putting text, currency amounts, or a detailed receipt inside the icon.

- Icon Composer: <https://developer.apple.com/icon-composer/>

## 5. State-of-the-art native UI capabilities

Use the following capabilities deliberately. Claude must confirm API availability for the chosen deployment target before implementation.

### 5.1 Liquid Glass

Use current SwiftUI Liquid Glass APIs for the functional foreground layer:

- Bottom navigation and its central add-expense action.
- Compact floating filters.
- Contextual action clusters.
- Sheet controls and important floating buttons.
- Morphing between related controls using `GlassEffectContainer` and glass identities.

Rules:

- Prefer standard `TabView`, navigation, toolbar, sheet, popover, and button components so the operating system supplies correct behavior automatically.
- Use `glassEffect` on a small number of important custom controls.
- Do not put Liquid Glass behind every card.
- Do not stack several translucent layers over financial text.
- Respect Reduce Transparency and Increase Contrast.
- Group nearby effects inside a `GlassEffectContainer` for performance and coherent morphing.

Official references:

- <https://developer.apple.com/documentation/technologyoverviews/liquid-glass>
- <https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views>

### 5.2 Aurora and mesh gradients

Use native `MeshGradient` for:

- The home balance hero.
- A group cover or header.
- Onboarding art.
- Success/settlement confirmation backgrounds.

Animate gradients slowly and subtly. Pause or simplify expensive animation when the view is offscreen, Low Power Mode is active, Reduce Motion is enabled, or the app becomes inactive.

Do not animate gradients behind long lists or text-entry forms.

Reference: <https://developer.apple.com/documentation/swiftui/meshgradient>

### 5.3 Spatial transitions

Use native navigation and matched transitions to preserve context:

- Group card to group detail.
- Expense row to expense detail.
- Receipt thumbnail to full receipt.
- Participant avatar to member detail.
- Balance card to the settle-up plan.

Prefer `matchedTransitionSource`, zoom navigation transitions, `matchedGeometryEffect`, and normal sheet presentation over custom navigation frameworks.

Reference: <https://developer.apple.com/documentation/swiftui/zoomnavigationtransition>

### 5.4 Motion system

Define a small motion vocabulary in the design system:

- **Press:** quick scale/opacity response.
- **Reveal:** short spring for cards and sheets.
- **Transfer:** matched movement between a source and destination.
- **Confirm:** checkmark, amount roll, and light haptic.
- **Attention:** one restrained pulse, never perpetual flashing.
- **Reconcile:** smoothly animate old and new allocations.

Use:

- Spring animations with consistent parameters.
- `contentTransition(.numericText())` for changing amounts.
- `PhaseAnimator` for short multi-stage sequences.
- `KeyframeAnimator` when exact timing is required.
- `symbolEffect` for icon feedback.
- `scrollTransition` only for lightweight depth and emphasis.

Never animate every list row on every appearance. Never delay a core financial action to finish decorative animation.

### 5.5 Haptics

Use system sensory feedback for ordinary selection, success, warning, and error states. Use Core Haptics only for signature moments such as:

- Successfully settling a group.
- Claiming an item in the Live Receipt Room.
- Completing receipt reconciliation.

Haptics must reinforce a visible state, not replace it. Check hardware capability and respect user settings.

Reference: <https://developer.apple.com/documentation/corehaptics>

### 5.6 Charts and financial visualization

Use Swift Charts rather than a third-party chart package.

Possible visualizations, only when a P2P screen needs them:

- Spending by category within a group or trip.
- Expense activity over time.
- Distribution of upfront spending across members (who keeps paying first).

Requirements:

- Provide accessible chart descriptions.
- Allow interaction and selection where it adds value.
- Never use a chart when two numbers and a progress bar communicate more clearly.
- Avoid pseudo-3D charts for financial information.
- Use consistent category colors throughout the application.

Reference: <https://developer.apple.com/documentation/charts>

### 5.7 Receipt capture

Use Apple frameworks first:

- `VisionKit` for document capture and live scanning where appropriate.
- `Vision` for on-device text recognition.
- `PhotosUI` for importing an existing receipt.
- `AVFoundation` only when a custom camera experience is justified.

The scan experience should include:

- Edge detection and perspective correction.
- Immediate crop/rotate confirmation.
- Progress stages: capturing, recognizing, structuring, reviewing.
- Confidence-aware highlighting of uncertain values.
- Side-by-side access to the original receipt and editable fields.
- A deterministic reconciliation check before saving.

Reference: <https://developer.apple.com/documentation/vision/recognizing-text-in-images>

### 5.8 Modern system integrations

Consider these only after the core workflow works:

- `AppIntents`: “Add an expense,” “Scan a receipt,” and “Show my balances.”
- `WidgetKit`: compact balance and pending-payment widgets without exposing sensitive detail by default.
- `ActivityKit`: a time-limited Live Receipt Room activity when it provides continuing value.
- `TipKit`: contextual education for the first multi-payer or itemized split, the first Live Receipt Room, and the first receipt scan.
- `CoreSpotlight`: index groups and expenses only if privacy expectations are clear; consider semantic search only for content that is safe to index.
- Share extensions for importing receipt images or expense details from another app.
- `AppIntentsTesting`: validate important intents instead of assuming they work through Siri and Shortcuts.
- `MetricKit`: collect first-party performance and diagnostic metrics before adding excessive custom telemetry.

Do not implement integrations merely to list them as features. Each must support a tested user need.

### 5.9 High-impact Apple-native differentiators

These features could distinguish Square Up, but they belong after the core expense workflow is reliable.

#### App Clip for joining a Live Receipt Room

**Status: paused** pending the Apple Developer Program decision. Do not create or modify an App Clip target, Associated Domains, AASA configuration, signing, or App Store Connect configuration until that decision is made.

An App Clip is an unusually strong match for the restaurant use case. A payer could display a QR code or share an invocation link, and guests could immediately claim receipt items without first installing the complete app or creating a full account.

The App Clip should do one job:

1. Open the invited receipt room.
2. Let the guest choose or confirm a lightweight identity.
3. Claim, share, or dispute items.
4. Review the resulting amount.
5. Offer the full app only after the task is complete.

Do not place the full Square Up dashboard inside the App Clip. Keep launch fast, protect privacy, and share code with the full app through deliberate packages or targets.

Reference: <https://developer.apple.com/documentation/appclip>

#### SharePlay for remote collaborative splitting

Evaluate `GroupActivities` as an optional way for participants in a FaceTime call or Messages conversation to review and claim receipt items together. This should supplement the normal server-backed Receipt Room, not become its only synchronization mechanism.

Use a `GroupActivity` to advertise the experience and `GroupSessionMessenger` for small, time-sensitive claim or selection messages. The server remains authoritative for persistence and conflict resolution.

Reference: <https://developer.apple.com/documentation/groupactivities>

#### Live Activity for a short-lived active room

A Live Activity may show that a receipt room is open, how many items remain, and whether the user must review something. It must not expose itemized purchases or sensitive balances on the Lock Screen by default. End it promptly when the room closes.

Use Apple's official Live Activities design template from Apple Design Resources and review the current ActivityKit guidance.

- ActivityKit: <https://developer.apple.com/documentation/activitykit>
- Live Activities essentials: <https://developer.apple.com/videos/play/wwdc2026/223/>

#### App Attest for sensitive production APIs

When a production server handles invitations, receipt images, AI requests, or financial records, evaluate App Attest to help the server distinguish legitimate app instances. App Attest complements authentication and server authorization; it does not replace them. Always check availability and provide a graceful strategy for unsupported devices.

Reference: <https://developer.apple.com/documentation/devicecheck/establishing-your-app-s-integrity>

#### Background Tasks for resilient sync

Use `BackgroundTasks` only for justified refresh, upload completion, and maintenance work. Do not promise exact execution times. User-visible state must remain correct even when the system does not grant background runtime.

Reference: <https://developer.apple.com/documentation/backgroundtasks>

## 6. Recommended native frameworks

| Framework | Use | Priority |
|---|---|---|
| SwiftUI | All primary interface and navigation | Required |
| Observation | `@Observable` feature state and dependency observation | Required |
| SwiftData | Local structured persistence and offline prototype | Required |
| Swift Charts | Spending visualization, only where a chart beats two numbers | Optional |
| Vision + VisionKit | Receipt capture and OCR | Required for receipt prototype |
| PhotosUI | Receipt import | Required |
| Foundation Models | On-device/private AI suggestions through a provider abstraction | Recommended experiment on supported devices |
| Core Haptics | Signature tactile interactions | Recommended |
| TipKit | Contextual feature education | Recommended later |
| AppIntents | Shortcuts and system actions | Optional after core |
| AppIntentsTesting | Automated validation of App Intents | Recommended when intents are added |
| WidgetKit + ActivityKit | Widgets and time-limited live status | Optional after core |
| App Clip | Instant, focused Live Receipt Room participation | High-value future differentiator |
| GroupActivities | Optional SharePlay receipt collaboration | Experimental after multi-user core |
| CoreSpotlight | Private, deliberate search indexing | Optional after core |
| BackgroundTasks | Resilient refresh/upload completion | Recommended for production sync |
| LocalAuthentication | Protect sensitive actions or hidden financial views | Recommended for production |
| Security/Keychain | Authentication token storage | Required for multi-user production |
| DeviceCheck/App Attest | Help protect sensitive server APIs from modified clients | Recommended for production threat model |
| OSLog | Structured, privacy-aware diagnostics | Required |
| MetricKit | First-party performance and diagnostics | Recommended for beta/production |
| Network | Connectivity awareness where useful | Optional; do not block work solely from a reachability flag |

Use the Observation macro instead of legacy `ObservableObject`/`@Published` for new code when the deployment target supports it.

References:

- <https://developer.apple.com/documentation/observation>
- <https://developer.apple.com/documentation/swiftdata>

### 6.1 Current SwiftData capabilities

Use SwiftData's current APIs where they simplify real Square Up requirements:

- Sectioned fetches for grouping activity by date or expense state.
- Persisted Codable custom types when they are stable domain values, not as a way to hide an unstructured schema.
- `ResultsObserver` for precise store-result observation outside a SwiftUI query.
- `HistoryObserver` when sync, auditing, or external changes require persistent-history awareness.

Do not adopt a new API merely because it exists. The local prototype should still have a schema that can be reasoned about, migrated, tested, and replaced by remote repositories.

Reference: <https://developer.apple.com/videos/play/wwdc2026/274/>

### 6.2 Foundation Models and Apple Intelligence strategy

Square Up should evaluate the iOS 27 Foundation Models framework as a privacy-preserving AI layer. The current framework can expose on-device Apple Foundation Models and other conforming local or cloud language models through a shared `LanguageModel` abstraction. It also supports image input, Vision tools, structured generation, model availability checks, and evaluation workflows.

Good Square Up uses:

- Parse a natural-language quick entry into an editable expense draft.
- Suggest a merchant category from recognized receipt content.
- Explain a complex split or settle-up plan in plain language.
- Assist with uncertain receipt fields after deterministic OCR.

Do not use any language model to:

- Calculate authoritative balances.
- Choose a final payer or allocation without confirmation.
- Record, confirm, or dispute a payment.
- Invent missing receipt values.
- Make an irreversible financial decision.

Implement an `AIProvider` or equivalent boundary so the product can select among:

1. On-device Foundation Models when supported and appropriate.
2. Private Cloud Compute only when entitlements, eligibility, privacy, and product requirements are understood.
3. The server-side Claude receipt pipeline (milestone 5) for cross-device consistency or capabilities unavailable locally.
4. A deterministic or manual fallback when no model is available.

Requirements:

- Check model availability at runtime.
- Keep cloud credentials off the device.
- Make local-versus-cloud processing understandable where it affects privacy.
- Use typed structured output and validate it deterministically.
- Preserve the original receipt and allow correction.
- Record model/provider/version metadata for evaluation without recording unnecessary personal content.
- Build a fixed evaluation set for receipt extraction and quick entry.
- Never make the core expense flow depend on Apple Intelligence availability.

Official references:

- Foundation Models documentation: <https://developer.apple.com/documentation/foundationmodels>
- What’s new in iOS 27: <https://developer.apple.com/wwdc26/guides/ios/>
- What’s new in Foundation Models: <https://developer.apple.com/videos/play/wwdc2026/241/>

## 7. Third-party library policy

### 7.1 Default rule

Do not add a package until a specific feature needs it. Before installation, record:

- The package URL and selected version.
- Why native APIs are insufficient.
- License.
- Supported iOS and Swift versions.
- Whether it includes a privacy manifest.
- Recent maintenance and release activity.
- Binary size and performance implications.
- Removal strategy if the package becomes incompatible.

Commit `Package.resolved` so builds remain reproducible. Prefer exact or compatible version requirements with deliberate upgrades; never track an unpinned branch for production work.

### 7.2 Recommended packages

#### Nuke

Repository: <https://github.com/kean/Nuke>

First evaluate the improved native `AsyncImage` caching behavior in the current SDK. Use `NukeUI` from the main Nuke package only when the production app demonstrates a need for more control over remote avatars, group images, or receipt thumbnails. Nuke provides caching, request coalescing, prefetching, processing, and background decompression beyond a basic implementation.

Do not install it for an entirely local prototype.

#### Rive — preferred for interactive authored animation

Repository: <https://github.com/rive-app/rive-ios>

Use Rive only if Square Up receives a deliberately designed interactive asset with state-machine behavior, such as:

- A responsive onboarding identity animation.
- A settlement animation that reacts to the number of payments eliminated.
- A Live Receipt Room illustration driven by room state.
- A high-quality empty state with meaningful interaction.

Rive is preferable when animation must react to application state. Keep it to a few prominent locations, provide static fallbacks, expose accessibility semantics, and pause rendering when offscreen.

Official runtime guide: <https://rive.app/docs/runtimes/apple/apple>

#### Lottie — alternative, not an additional animation system

Repository for Swift Package Manager: <https://github.com/airbnb/lottie-spm>

Use Lottie instead of Rive when the design workflow produces After Effects/bodymovin animations that only need timeline playback. Do not install both Rive and Lottie unless the project has a documented asset requirement that neither can satisfy alone.

#### Pow

Repository: <https://github.com/EmergeTools/Pow>

Use Pow sparingly for polished SwiftUI change effects and transitions when the exact effect would take substantial custom work. Appropriate uses include one-time invite success, settlement confirmation, or a subtle claimed-item effect.

Do not apply particle effects to ordinary form submissions, navigation, error states, or money movement.

#### SnapshotTesting

Repository: <https://github.com/pointfreeco/swift-snapshot-testing>

Add only to test targets. Use it to protect the design system and important screens across:

- Dark and light appearances.
- Small and large phones.
- Arbitrary resizable widths supported by iOS 27, iPhone Mirroring, and iPhone-on-iPad contexts.
- Long names and large currency values.
- Large Dynamic Type sizes.
- Empty, loading, populated, offline, and error states.
- Payer, participant, receipt-room host, and guest perspectives.

#### Pulse

Repository: <https://github.com/kean/Pulse>

Consider Pulse for DEBUG builds when server development begins. It can make network traffic and structured logs easier to inspect during development. Never expose sensitive receipt or authentication data in recorded logs.

#### Sentry

Repository: <https://github.com/getsentry/sentry-cocoa>

Consider for beta and production crash/error reporting. Configure data scrubbing before enabling it. Financial amounts, receipts, tokens, names, and payment identifiers must not be attached indiscriminately.

#### SwiftLint and SwiftFormat

- SwiftLint: <https://github.com/realm/SwiftLint>
- SwiftFormat: <https://github.com/nicklockwood/SwiftFormat>

Use these as development tools with repository-owned configuration. Rules must support clarity and correctness rather than create formatting churn. Do not install them in the application runtime target.

### 7.3 Libraries to avoid initially

- Third-party navigation frameworks.
- Third-party bottom-sheet frameworks.
- Third-party chart libraries.
- Generic component kits that replace native SwiftUI controls.
- Custom blur/glass packages.
- Multiple animation runtimes.
- Third-party money types without a demonstrated need.
- Networking wrappers when `URLSession` and `Codable` are sufficient.
- Large architecture frameworks introduced only because they are popular.

The project should first exhaust current native APIs. A highly polished app can still have a small dependency graph.

## 8. Recommended architecture

Use the feature-first structure already described in `overview.md`, refined as follows:

```text
SquareUp/
  App/
    SquareUpApp.swift
    AppEnvironment.swift
    AppRouter.swift
  Core/
    Money/
    Identity/
    Logging/
    Extensions/
  DesignSystem/
    Tokens/
    Components/
    Motion/
    Haptics/
    PreviewSupport/
  Models/
  Features/
    Home/
    Groups/
    Expenses/
    Receipts/
    Settlements/
    Activity/
    Profile/
  Services/
    Networking/
    Persistence/
    ReceiptProcessing/
    AI/
  Resources/
  SquareUpTests/
  SquareUpUITests/
```

### Architecture rules

- Use `@Observable` feature models or view models on the main actor.
- Views render state and forward user intent. They do not perform business calculations.
- Repositories hide local-versus-remote storage.
- Services use protocols only where substitution or testing genuinely requires it.
- Use actors for mutable services accessed across concurrency domains.
- Make task cancellation explicit when screens disappear or inputs change.
- Use typed identifiers instead of passing unrelated raw strings everywhere.
- Keep navigation state explicit and deep-linkable.
- Keep feature files focused; split a view once it contains independently meaningful components or behavior.
- Avoid global singletons except immutable system-level configuration.
- Do not adopt The Composable Architecture unless the team intentionally commits to learning and using it consistently. Half-adopting an architecture framework is worse than a clear native architecture.

## 9. Money and financial correctness

- Never represent money using `Double` or `Float`.
- Use `Decimal` with an explicit currency code and deliberate rounding policy.
- Centralize currency formatting.
- Keep stored amounts in a clearly documented representation.
- A split must reconcile exactly before it can be finalized.
- Show rounding adjustments when they affect a participant.
- Use locale-aware formatting and parsing.
- Negative values, credits, discounts, and refunds must have explicit domain meaning.
- The displayed balance must be derived from authoritative transactions, not cached UI state.
- Every destructive financial edit should communicate its downstream effect.
- Maintain an audit trail for expense edits, deletions, receipt-room actions, and payments.

Create property-based or table-driven tests for:

- Equal splits with indivisible minor units.
- Percentages totaling 100%.
- Multiple payers.
- Shared receipt items.
- Tax, tip, discount, and service-fee allocation.
- Settlement simplification.
- Currency formatting and rounding.

## 10. Design-system components to build first

Build reusable primitives before composing entire screens:

1. `SquareUpTheme`
2. Semantic colors and materials
3. Typography styles and financial-number style
4. `SUCard`
5. `SUPrimaryButton`, `SUSecondaryButton`, and destructive button style
6. `SUAvatar` and `SUAvatarStack`
7. `SURoleBadge` (identity: You, Payer)
8. `SUStatusChip`
9. `SUAmountView`
10. `SUTransactionRow`
11. `SUBalanceCard`
12. `SUEmptyState`
13. `SULoadingState` and skeleton treatment
14. `SUErrorState`
15. `SUFloatingActionBar`
16. `SUReceiptThumbnail`
17. `SUUserPickerRow`
18. `SUSplitMethodPicker`
19. `SUConfirmationBanner`

Every component needs previews for realistic long content, both appearances, and accessibility sizes where relevant.

## 11. Screen-specific recommendations

### Onboarding

- Use one bold brand moment, not a long slideshow.
- Explain Square Up in a single sentence.
- Show people becoming “square” through a simple interactive illustration.
- Ask only for information required to start.
- Defer notifications, contacts, camera, and photo permissions until the user invokes the relevant feature.

### Home

- Hero card: net position across all groups, with plain language such as “You are owed” or “You owe.”
- Quick actions: Add expense, Scan receipt, Settle.
- Groups requiring attention, people you owe first.
- Payments waiting for your confirmation, and payments you started but didn't finish.
- Unfinished receipts and open receipt rooms.
- Recent activity.
- Avoid presenting a fake bank balance; Square Up tracks obligations, not stored money.

### Group detail

- Group identity and participant stack.
- Clear net balance for the active user.
- Segmented access to Expenses, Balances, and Activity.
- Persistent primary action for adding an expense.
- Distinguish unresolved expenses from settled history.

### Add expense

- Use a focused, staged flow rather than one enormous form.
- Amount and description should be immediately accessible.
- Participant selection must use full names and avatars.
- Split method must remain visible before confirmation.
- Provide a live reconciliation summary.
- Show a final human-readable sentence before saving.

### Live Receipt Room

- Make the receipt line items the central object.
- Show live participant presence with avatars and clear names.
- Claiming an item should be immediate, reversible, and tactile.
- Shared-item allocation should be visually obvious.
- Unclaimed, partially claimed, disputed, and resolved states must be distinct.
- Tax, tip, and discount allocation must remain inspectable.
- Show sync state without making the interface feel technical.
- Handle optimistic updates and conflicts explicitly.

### Activity

- Group by day; filter by expenses and payments.
- Show each entry's effect on the active user: lent, borrowed, paid back, received.
- Use audit language: added by, changed by, reported by, confirmed by.
- If a spending view is ever added, begin with an answer, then show the chart supporting it, and do not populate it with meaningless sample complexity.

### Settlement

- Explain the optimized payment plan in plain language.
- Show the before-and-after number of transfers when simplification is enabled.
- Make external-payment recording explicit; do not imply Square Up transferred money.
- Use the strongest success animation and haptic in the app only after settlement is confirmed.

## 12. Loading, empty, offline, and error states

Every asynchronous screen must deliberately support:

- Initial loading.
- Incremental refresh without blanking existing content.
- Empty but valid state.
- Recoverable error with retry.
- Validation error beside the relevant input.
- Offline data with a last-updated indication.
- Permission denied.
- Authentication expired.
- Optimistic update in progress.
- Sync conflict requiring review.

Use native redaction and restrained shimmer for skeletons. Avoid indefinite spinners when progress stages can be explained. Never use fake progress percentages.

## 13. Accessibility and inclusion

Before a screen is considered complete, verify:

- VoiceOver order and labels.
- Dynamic Type through accessibility sizes.
- Touch targets of at least 44 points.
- Sufficient contrast in dark and light appearances.
- Meaning does not depend on color.
- Reduce Motion behavior.
- Reduce Transparency behavior.
- Increase Contrast behavior.
- Bold Text behavior.
- Differentiate Without Color behavior.
- Long names and localized text.
- Right-to-left layout where system mirroring applies.
- Voice Control names for important actions.
- Charts include accessible summaries and values.
- Haptics have visible equivalents.

Avoid using only initials to distinguish two members with the same name. Show additional identity context when ambiguity exists.

## 14. Performance standards

- Target consistently smooth interaction on the oldest supported test device.
- Profile scrolling, first render, navigation transitions, receipt image decoding, and animated hero content with Instruments.
- Use lazy containers for long lists.
- Downsample receipt images and thumbnails to their display size.
- Cache remote images deliberately.
- Move OCR, image preparation, and JSON decoding away from the main actor.
- Do not create multiple continuously animated mesh gradients or Rive/Lottie views on one screen.
- Pause animation when offscreen.
- Avoid deeply nested translucency and shadow stacks.
- Follow Apple's guidance to limit simultaneous custom glass effects.
- Treat dropped frames and delayed taps as functional defects.

## 15. Privacy and security UI

- Do not log receipt contents, tokens, personal names, or financial notes.
- Hide sensitive values in app-switcher snapshots when the production threat model requires it.
- Widgets and notifications should reveal minimal information by default.
- Ask for camera, photos, contacts, and notifications in context.
- Explain why data is needed before the system permission prompt.
- Store production credentials in Keychain.
- Keep the Anthropic API key and other server secrets off the device; they live only in the server's environment or secret manager.
- Make participant visibility understandable before sharing a receipt room or records.
- Provide a clear route to remove a receipt image or leave a group.

## 16. Testing and visual QA

### Required automated layers

- Swift Testing for money, allocation, validation, and state transitions.
- Repository tests using deterministic in-memory implementations.
- Snapshot tests for design-system components and critical screens.
- XCUITest for the primary expense flow, receipt-to-room flow, and settle-up flow.
- Fixed receipt fixtures for OCR and structured-output evaluation.
- Server tests with mocked AI output.

### Required preview matrix

For important screens, create preview fixtures covering:

- New user with no groups.
- User who owes money.
- User who is owed money.
- Large group.
- Payment awaiting the user's confirmation.
- Open Live Receipt Room with unclaimed and shared items.
- Long merchant and member names.
- Large amounts.
- Dark mode and light mode.
- Large Dynamic Type.
- Offline and error states.

### Visual review checklist

- Is the primary action obvious within two seconds?
- Can the user identify themselves and every affected participant?
- Can the user explain who owes whom without interpreting color?
- Are all numbers aligned and formatted consistently?
- Does the screen still work with animation disabled?
- Does glass improve hierarchy or merely add decoration?
- Does the interface look trustworthy rather than speculative or game-like?
- Does every control use a familiar label or include enough context?

## 17. Claude's required implementation competencies

When working on Square Up, Claude must apply or explicitly research these skills:

1. **Modern SwiftUI:** current navigation, layout, Observation, previews, animation, and presentation APIs.
2. **Apple interaction design:** Human Interface Guidelines, native component behavior, and platform conventions.
3. **Design-system engineering:** semantic tokens, reusable components, consistent states, and preview fixtures.
4. **Financial-domain correctness:** decimal arithmetic, rounding, reconciliation, auditability, and unambiguous language.
5. **Swift concurrency:** actors, task cancellation, main-actor isolation, and data-race prevention.
6. **Persistence architecture:** SwiftData boundaries, migrations, offline state, and repository substitution.
7. **Camera and Vision:** receipt scanning, OCR, image orientation, downsampling, and user correction.
8. **Accessibility:** VoiceOver, Dynamic Type, contrast, reduced motion, and inclusive identity presentation.
9. **Motion and haptics:** animation used to explain state, tactile feedback, and graceful fallbacks.
10. **Testing and visual QA:** unit, snapshot, UI, fixture-based, and device testing.
11. **Security and privacy:** permissions, secrets, logging, authorization, and sensitive UI handling.
12. **Performance profiling:** Instruments, rendering cost, image memory, and animation lifecycle.

If Claude lacks certainty about a current framework API, it must consult current official Apple documentation before inventing an API or adding a workaround.

## 18. Claude implementation workflow

For each feature:

1. Read the relevant section of `overview.md`.
2. Identify the user problem and the minimum complete workflow.
3. List normal, loading, empty, offline, permission, validation, and error states.
4. Reuse or extend design-system tokens and components.
5. Implement domain calculations outside the view.
6. Add realistic preview fixtures.
7. Add business-logic tests before relying on visual testing.
8. Build and run the relevant target.
9. Inspect the result on at least one small and one current iPhone simulator.
10. Test dark mode, light mode, and large Dynamic Type.
11. Profile any camera, image, chart, glass, or continuous-animation work.
12. Document deliberate deviations from this guide.

Claude must not:

- Silently cut a product requirement because implementation is difficult.
- Add a package without recording why it is needed.
- Put sample-only shortcuts into production architecture without labeling them.
- Use placeholder icons or random colors when a design-system option exists.
- Mark an action complete without handling failure.
- Treat AI output as authoritative financial data.
- Expose an API key in the app bundle.
- Claim an external payment occurred when the app only recorded it.
- Sacrifice accessibility to reproduce a concept image exactly.

## 19. Delivery sequence

### Foundation

- Rename the Xcode project and product identifiers deliberately.
- Establish Swift language/concurrency settings.
- Create feature folders and app environment.
- Create semantic design tokens.
- Build core components and preview fixtures.
- Define money and identity models.
- Add deterministic seeded data.

### Core personal flow

- Home.
- Groups.
- Group detail.
- Add expense.
- Flexible split.
- Balances.
- Record settlement.
- Activity history.

### Signature experience

- Receipt capture.
- OCR review.
- Live Receipt Room.
- Item claiming and reconciliation.
- Signature motion and haptic treatment.

### Real multi-user P2P groups

- Persistent accounts and server-backed personal groups.
- Group invitation links and cross-device membership.
- Cross-device expenses and synchronized balances.
- Settlement requests, payment handoff, recipient confirmation, and reminders.
- Offline recovery, conflict handling, and shared activity history.

### Production quality

- Accessibility audit.
- Snapshot coverage.
- Performance profiling.
- Error and offline states.
- Analytics/crash reporting with privacy controls.
- TestFlight feedback loop.

## 20. Final package recommendation

Start with native Apple frameworks and no runtime UI dependency. Add packages only at these decision points:

1. Add **SnapshotTesting** when the design system stabilizes.
2. Add **Nuke** when remote images actually exist.
3. Choose **Rive or Lottie**, not both, only when final authored motion assets exist.
4. Add **Pow** only for a small number of approved delight moments.
5. Add **Pulse** in DEBUG when network development begins.
6. Add **Sentry** only after privacy scrubbing is configured for beta testing.

This approach provides state-of-the-art UI without allowing dependency novelty to weaken the product.

## 21. Definition of premium quality

Square Up is ready to be described as premium only when:

- A new user can add and understand an expense without instruction.
- A participant never has to guess which person an amount belongs to.
- Every total reconciles exactly.
- Important changes animate smoothly and remain understandable without animation.
- Dark and light appearances both feel designed.
- VoiceOver and large Dynamic Type are functional, not merely technically enabled.
- Loading and error states are as polished as the ideal state.
- Receipt capture feels fast and correction feels safe.
- The Live Receipt Room makes a complex split feel simpler than discussing it manually.
- The app remains responsive on the oldest supported test device.
- Visual effects support trust, hierarchy, and comprehension.
