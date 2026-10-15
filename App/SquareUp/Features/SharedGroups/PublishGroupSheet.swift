import SwiftUI

/// "Share this group" (milestone 7 §8): reviews a local group against every publication rule,
/// says exactly what will and won't be shared, and publishes it once. A failure leaves the local
/// group untouched; retrying reuses the same publication, so it can never be shared twice.
struct PublishGroupSheet: View {
    let groupID: GroupID
    let groupName: String
    let onPublished: (GroupID) -> Void
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var review: SharedGroupsService.PublicationReview?
    @State private var isPublishing = false
    @State private var error: String?
    @State private var accountSheet: AccountSheet.Mode?
    @State private var isChoosingName = false
    @AccessibilityFocusState private var errorFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                if let review {
                    Section {
                        LabeledContent(String(localized: "People"), value: "\(review.memberCount)")
                        LabeledContent(String(localized: "Expenses"), value: "\(review.expenseCount)")
                    } header: {
                        Text(groupName)
                    }
                    .suListRows()
                    if !review.blockers.isEmpty {
                        Section {
                            ForEach(review.blockers, id: \.self) { blocker in
                                Label(blocker, systemImage: "xmark.octagon").foregroundStyle(SUColor.negative)
                            }
                        } header: {
                            Text(String(localized: "Fix these first"))
                        } footer: {
                            Text(String(localized: "Nothing has been uploaded."))
                        }
                        .suListRows()
                    }
                    Section {
                        ForEach(review.disclosures, id: \.self) { line in
                            Label(line, systemImage: "info.circle").foregroundStyle(SUColor.textSecondary)
                        }
                    } header: {
                        Text(String(localized: "What sharing does"))
                    }
                    .suListRows()
                    accountGate
                    if let error {
                        Section {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(SUColor.negative)
                                .accessibilityFocused($errorFocused)
                                .accessibilityIdentifier("publish.error")
                        } footer: {
                            Text(String(localized: "Your group on this iPhone is unchanged. You can try again — it will never be shared twice."))
                        }
                        .suListRows()
                    }
                } else {
                    Section { ProgressView(String(localized: "Checking the group…")) }
                        .suListRows()
                }
            }
            .scrollContentBackground(.hidden)
            .suScreenBackground()
            .navigationTitle(String(localized: "Share this group"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel")) { dismiss() }.disabled(isPublishing) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Share")) { Task { await publish() } }
                        .disabled(!(review?.canPublish ?? false) || isPublishing || !environment.sharedGroups.isReady)
                        .accessibilityIdentifier("publish.confirm")
                }
            }
            .overlay {
                if isPublishing {
                    ProgressView(String(localized: "Sharing…"))
                        .padding(SUSpacing.lg)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            .sheet(item: $accountSheet) { mode in AccountSheet(mode: mode) }
            .sheet(isPresented: $isChoosingName) { DisplayNameSheet() }
            .interactiveDismissDisabled(isPublishing)
        }
        .task { review = await environment.sharedGroups.publicationReview(of: groupID) }
    }

    @ViewBuilder
    private var accountGate: some View {
        switch environment.sharedGroups.accountState {
        case .ready:
            EmptyView()
        case .needsProfile:
            Section {
                Button(String(localized: "Choose the name people will see")) { isChoosingName = true }
            }
            .suListRows()
        case .signedOut, .deviceOnly, .sessionEnded:
            Section {
                Button(String(localized: "Add an email and password")) { accountSheet = .create }
                Button(String(localized: "Sign in to an existing account")) { accountSheet = .signIn }
            } footer: {
                Text(String(localized: "Shared groups need an account you can recover on another iPhone."))
            }
            .suListRows()
        case .notConfigured:
            Section { Text(String(localized: "Shared groups aren't set up in this build of Square Up.")) }
                .suListRows()
        }
    }

    private func publish() async {
        isPublishing = true
        error = nil
        defer { isPublishing = false }
        do {
            let id = try await environment.sharedGroups.publish(groupID)
            AccessibilityNotification.Announcement(String(localized: "\(groupName) is shared")).post()
            dismiss()
            onPublished(id)
        } catch {
            let ledgerError = error
            self.error = ledgerError == .remote(.offline)
                ? LedgerErrorMessages.text(for: RemoteIssue.connectionRequired) : LedgerErrorMessages.text(for: ledgerError)
            errorFocused = true
        }
    }
}
