import StoreKit
import SwiftUI

/// The Square Up App Clip, embedded in the full app (activation status: `HW/App/APP_CLIP_ACTIVATION.md`).
///
/// One job only: join a temporary room ("Split with people now") from its link, QR code, or short
/// code; claim what you had; review your share; and pay the payer back and report it. No scanning,
/// AI, groups, profile, or history. The invocation URL is `https://<server>/r/<token>`, the same
/// link the full app opens (once installed, the full app receives every invocation instead).
/// Launched without one (App Switcher, notification) or with the bare `/r/` prefix, it returns to
/// the last room or asks for the code.
@main
struct SquareUpClipApp: App {
    @State private var model = ClipModel()

    var body: some Scene {
        WindowGroup {
            ClipRootView(model: model)
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    guard let url = activity.webpageURL else { return }
                    Task { await model.handle(url.absoluteString) }
                }
                .onOpenURL { url in Task { await model.handle(url.absoluteString) } }
                .task {
                    if let invitation = ClipConfiguration.launchInvitation() { await model.handle(invitation) } else { await model.resume() }
                }
                .preferredColorScheme(.dark)
        }
    }
}

struct ClipRootView: View {
    let model: ClipModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var isShowingFullApp = false

    var body: some View {
        NavigationStack {
            Group {
                switch model.phase {
                case .needsInvitation: ClipCodeEntryView(model: model)
                case .loading: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                case .preview(let preview): ClipJoinView(model: model, preview: preview)
                case .inRoom: ClipRoomView(model: model)
                case .unavailable(let reason):
                    ContentUnavailableView {
                        Label(String(localized: "Can't open this receipt"), systemImage: "lock.slash")
                    } description: {
                        Text(reason)
                    } actions: {
                        Button(String(localized: "Enter a code")) { model.enterCode() }
                            .accessibilityIdentifier("clip.enterCode")
                    }
                }
            }
            .background(ClipBackground())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "Get Square Up")) { isShowingFullApp = true }
                        .accessibilityHint(String(localized: "Shows the full app on the App Store"))
                }
            }
        }
        .appStoreOverlay(isPresented: $isShowingFullApp) { SKOverlay.AppClipConfiguration(position: .bottom) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, model.phase == .inRoom { model.startPolling() } else { model.stopPolling() }
        }
    }
}

/// The app's dusk gradient (black → navy → light burgundy), drawn without the app's design system.
struct ClipBackground: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.02, green: 0.02, blue: 0.04), Color(red: 0.06, green: 0.09, blue: 0.2),
                                Color(red: 0.32, green: 0.14, blue: 0.2)],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }
}
