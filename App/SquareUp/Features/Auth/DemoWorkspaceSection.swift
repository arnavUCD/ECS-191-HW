import SwiftUI

/// Profile → Demo, in place of the account section while the app is in a demo workspace: what the
/// demo is, Reset demo data (this workspace only, back to its seed), and Leave demo.
struct DemoWorkspaceSection: View {
    let auth: AuthCoordinator
    @Environment(AppEnvironment.self) private var environment
    @State private var isConfirmingReset = false
    @State private var isConfirmingLeave = false
    @State private var isResetting = false
    @State private var outcome: Outcome?

    private enum Outcome: Equatable {
        case reset
        case failed(String)

        var message: String {
            switch self {
            case .reset: String(localized: "The demo is back to its sample data.")
            case .failed(let message): message
            }
        }
    }

    var body: some View {
        Section {
            LabeledContent(String(localized: "Account"), value: String(localized: "Demo · sample data"))
                .accessibilityIdentifier("profile.demo")
            LabeledContent(String(localized: "Your name in the demo"), value: environment.sharedGroups.profile?.displayName ?? auth.profile?.displayName ?? "")
            Button {
                isConfirmingReset = true
            } label: {
                HStack(spacing: SUSpacing.xs) {
                    Text(String(localized: "Reset demo data"))
                    if isResetting {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isResetting)
            .accessibilityIdentifier("profile.demo.reset")
            .confirmationDialog(String(localized: "Reset demo data?"), isPresented: $isConfirmingReset, titleVisibility: .visible) {
                Button(String(localized: "Reset demo data"), role: .destructive) { Task { await reset() } }
                    .accessibilityIdentifier("profile.demo.confirmReset")
            } message: {
                Text(String(localized: """
                Everything you added or changed in the demo is removed, and its sample groups, receipts, and payments go back to how \
                they started. Only this demo is affected.
                """))
            }
            if let outcome {
                Label(outcome.message, systemImage: outcome == .reset ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(SUFont.metadata)
                    .foregroundStyle(outcome == .reset ? SUColor.positive : SUColor.warning)
                    .accessibilityIdentifier("profile.demo.outcome")
            }
            Button(String(localized: "Leave demo"), role: .destructive) { isConfirmingLeave = true }
                .accessibilityIdentifier("profile.demo.leave")
                .confirmationDialog(String(localized: "Leave the demo?"), isPresented: $isConfirmingLeave, titleVisibility: .visible) {
                    Button(String(localized: "Leave demo"), role: .destructive) { Task { await auth.leaveDemo() } }
                        .accessibilityIdentifier("profile.demo.confirmLeave")
                } message: {
                    Text(String(localized: "Its sample data is deleted from this iPhone and the server. You can enter a fresh demo from the Welcome screen."))
                }
        } header: {
            Text(String(localized: "Demo"))
        } footer: {
            Text(String(localized: """
            Everyone, every receipt, and every amount in the demo's groups is fictional sample data. This demo is yours alone: it's kept \
            apart from every real account and group, and deleted after a week. Receipts you scan are read with AI like in the real app; \
            live rooms you open can be joined as a guest or from another demo, never with a real account. Group invitations and Find a \
            person are off.
            """))
        }
        .suListRows()
    }

    private func reset() async {
        isResetting = true
        outcome = nil
        defer { isResetting = false }
        do {
            try await auth.resetDemo()
            environment.haptics.play(.settle)
            outcome = .reset
        } catch {
            outcome = .failed(error.message)
        }
    }
}

