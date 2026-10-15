import SwiftUI

/// Invites the host to let everyone claim on their own phone (milestone 4: local room → shared room).
struct ShareLiveCard: View {
    let share: () -> Void

    var body: some View {
        SUCard {
            VStack(alignment: .leading, spacing: SUSpacing.sm) {
                Label(String(localized: "Let everyone claim on their own phone"), systemImage: "qrcode")
                    .font(SUFont.cardTitle).foregroundStyle(SUColor.textPrimary)
                Text(String(localized: "Share a code or link. Friends can join without installing Square Up."))
                    .font(SUFont.supporting).foregroundStyle(SUColor.textSecondary)
                Button(action: share) {
                    Label(String(localized: "Share live"), systemImage: "antenna.radiowaves.left.and.right").frame(maxWidth: .infinity)
                }
                .buttonStyle(.suSecondary)
                .accessibilityIdentifier("room.shareLive")
            }
        }
    }
}

/// What sharing sends, and the button that does it. After publishing, the flow continues on the
/// live room and the invitation opens.
struct ShareRoomSheet: View {
    let roomID: ReceiptRoomID
    /// Closed through its presenter's binding, never `dismiss`: publishing replaces the local room
    /// screen that presented this sheet, and a `dismiss` from a detached sheet would close the
    /// whole receipt flow instead.
    @Binding var isPresented: Bool
    @Environment(AppEnvironment.self) private var environment
    @State private var isPublishing = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SUSpacing.lg) {
                    Text(String(localized: "Share this receipt live"))
                        .font(SUFont.screenTitle).foregroundStyle(SUColor.textPrimary).accessibilityAddTraits(.isHeader)
                    VStack(alignment: .leading, spacing: SUSpacing.sm) {
                        Label(String(localized: "Sent to Square Up's server: the merchant, date, items, amounts, how charges are split, and the names of the people in the room."),
                              systemImage: "arrow.up.doc")
                        Label(String(localized: "Not sent: the receipt photo, your groups, other expenses, or balances."), systemImage: "lock")
                        Label(String(localized: "From now on the server keeps the room in sync. You still save the final expense to your group."),
                              systemImage: "checkmark.icloud")
                    }
                    .font(SUFont.supporting)
                    .foregroundStyle(SUColor.textSecondary)
                    if let error {
                        SUConfirmationBanner(title: String(localized: "Not shared"), message: error, systemImage: "exclamationmark.triangle.fill", tone: .negative)
                    }
                    Button {
                        Task { await publish() }
                    } label: {
                        HStack {
                            if isPublishing { ProgressView() }
                            Text(String(localized: "Share live"))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.suPrimary)
                    .disabled(isPublishing)
                    .accessibilityIdentifier("share.publish")
                }
                .padding(.horizontal, SUSpacing.screenMargin)
                .padding(.vertical, SUSpacing.lg)
                .frame(maxWidth: SUMetrics.readableWidth)
                .frame(maxWidth: .infinity)
            }
            .suScreenBackground()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel")) { isPresented = false } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func publish() async {
        isPublishing = true
        error = nil
        defer { isPublishing = false }
        do {
            try await environment.sharing.publish(roomID)
            environment.sharing.inviteOnOpen = roomID
            isPresented = false
        } catch {
            self.error = LedgerErrorMessages.text(for: error)
        }
    }
}
