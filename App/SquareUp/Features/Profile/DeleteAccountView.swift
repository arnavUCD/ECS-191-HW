import SwiftUI

/// Profile → Account → Delete account. Says what deleting removes and what other people keep, lists
/// anything to finish first (balances, payments in progress, receipts being split, groups the person
/// owns, live rooms), then asks them to sign in again — their password, or a code texted to the
/// account's number — and to confirm. The server checks everything again; if any step fails,
/// nothing is deleted.
struct DeleteAccountView: View {
    let auth: AuthCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(AppRouter.self) private var router
    @State private var plan: AccountDeletionPlan?
    @State private var loadFailure: String?
    @State private var password = ""
    @State private var verificationID: String?
    @State private var code = ""
    @State private var isSendingCode = false
    @State private var isConfirming = false
    @State private var failure: String?
    @AccessibilityFocusState private var failureFocused: Bool

    /// Email accounts confirm with their password; phone-only accounts with a texted code.
    private var usesPassword: Bool { auth.email != nil }

    var body: some View {
        NavigationStack {
            Form {
                if let plan {
                    if !plan.blockers.isEmpty { blockers(plan.blockers) }
                    deleted(plan)
                    kept(plan)
                    if plan.blockers.isEmpty { confirmation }
                } else if let loadFailure {
                    Section {
                        Text(loadFailure).foregroundStyle(SUColor.textSecondary)
                        Button(String(localized: "Try again")) { Task { await load() } }
                    }
                } else {
                    Section {
                        LabeledContent(String(localized: "Checking your groups and live rooms…")) { ProgressView() }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .suScreenBackground()
            .navigationTitle(String(localized: "Delete account"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                        .disabled(auth.isWorking)
                }
            }
            .interactiveDismissDisabled(auth.isWorking)
            .overlay { if auth.isWorking { ProgressView(String(localized: "Deleting…")) } }
            .confirmationDialog(String(localized: "Delete your account?"), isPresented: $isConfirming, titleVisibility: .visible) {
                Button(String(localized: "Delete account"), role: .destructive) { Task { await delete() } }
                    .accessibilityIdentifier("deleteAccount.confirm")
            } message: {
                Text(String(localized: "This can't be undone. Your account and the data listed here are deleted right away."))
            }
            .task { await load() }
        }
        .accessibilityIdentifier("deleteAccount")
    }

    // MARK: Sections

    private func blockers(_ blockers: [AccountDeletionPlan.Blocker]) -> some View {
        Section {
            ForEach(Array(blockers.enumerated()), id: \.offset) { _, blocker in
                let explanation = explain(blocker)
                VStack(alignment: .leading, spacing: SUSpacing.xs) {
                    Text(blocker.name.isEmpty ? String(localized: "A live room") : blocker.name)
                        .font(SUFont.body.weight(.semibold))
                        .foregroundStyle(SUColor.textPrimary)
                    Text(explanation.problem)
                        .font(SUFont.metadata)
                        .foregroundStyle(SUColor.textPrimary)
                    Text(explanation.fix)
                        .font(SUFont.metadata)
                        .foregroundStyle(SUColor.textSecondary)
                    if let groupID = blocker.groupId.flatMap(GroupID.init(string:)) {
                        Button(String(localized: "Open group")) {
                            dismiss()
                            router.openGroupAfterSheet(groupID)
                        }
                        .font(SUFont.metadata.weight(.semibold))
                        .accessibilityHint(String(localized: "Closes this and opens the group."))
                    }
                }
                .accessibilityElement(children: .contain)
            }
        } header: {
            Text(String(localized: "Finish these first"))
        } footer: {
            Text(String(localized: """
            Square Up won't change anyone else's balances, so balances need to be settled and groups handed over before your \
            account can be deleted. Nothing has been deleted. Come back here when you're done.
            """))
        }
    }

    private func deleted(_ plan: AccountDeletionPlan) -> some View {
        Section(String(localized: "What's deleted")) {
            point("person.crop.circle.badge.xmark", String(localized: "Your account and how you sign in to it"))
            point("creditcard", String(localized: "Your name, profile, and the payment methods you added"))
            if !plan.groupsDeleted.isEmpty {
                point("person.2.slash", String(localized: "Groups nobody else joined, with their expenses: \(names(plan.groupsDeleted))"))
            }
            if plan.roomsDeleted > 0 {
                point("qrcode", Inflect.string("^[\(plan.roomsDeleted) ended live room](inflect: true) you hosted, with their receipt photos"))
            }
            point("doc.text.viewfinder", String(localized: "Receipt results from AI processing kept for your account"))
            point("iphone", String(localized: "Everything Square Up keeps for this account on this iPhone: groups, receipts, photos, and settings"))
        }
    }

    private func kept(_ plan: AccountDeletionPlan) -> some View {
        Section(String(localized: "What other people keep")) {
            if !plan.groupsLeft.isEmpty {
                point("person.2", String(localized: """
                You leave \(names(plan.groupsLeft)). The expenses and payments you shared stay in the other members' records, \
                shown as "Former member" instead of your name.
                """))
            }
            point("person.crop.rectangle.stack", String(localized: """
            In someone else's live room, your claims stay in its summary as "Former member" until the room is deleted.
            """))
            point("arrow.left.arrow.right", String(localized: "Payments you made or received through other apps or in cash aren't affected. Square Up never moves money."))
        }
    }

    @ViewBuilder
    private var confirmation: some View {
        Section {
            if usesPassword {
                SecureField(String(localized: "Password"), text: $password)
                    .textContentType(.password)
                    .accessibilityIdentifier("deleteAccount.password")
            } else if verificationID == nil {
                Button(codeButtonTitle) { Task { await sendCode() } }
                    .disabled(isSendingCode || auth.isWorking)
                    .accessibilityIdentifier("deleteAccount.sendCode")
            } else {
                TextField(String(localized: "6-digit code"), text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .accessibilityIdentifier("deleteAccount.code")
                Button(String(localized: "Send a new code")) { Task { await sendCode() } }
                    .disabled(isSendingCode || auth.isWorking)
            }
            Button(String(localized: "Delete account"), role: .destructive) { isConfirming = true }
                .disabled(!canDelete)
                .accessibilityIdentifier("deleteAccount.delete")
        } header: {
            Text(String(localized: "Confirm it's you"))
        } footer: {
            Text(failure ?? (usesPassword ? String(localized: "Enter your password to delete your account.")
                    : String(localized: "We'll text a code to your number to confirm it's you.")))
                .foregroundStyle(failure == nil ? SUColor.textSecondary : SUColor.negative)
                .accessibilityFocused($failureFocused)
        }
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).foregroundStyle(SUColor.textPrimary).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(SUColor.textSecondary)
        }
    }

    // MARK: Logic

    private var canDelete: Bool {
        guard plan?.blockers.isEmpty == true, !auth.isWorking else { return false }
        return usesPassword ? !password.isEmpty : verificationID != nil && code.filter(\.isNumber).count == 6
    }

    private var codeButtonTitle: String {
        guard let number = auth.details?.phoneNumber else { return String(localized: "Text me a code") }
        return String(localized: "Text a code to \(PhoneNumbers.shared.display(number))")
    }

    private func names(_ groups: [AccountDeletionPlan.GroupReference]) -> String {
        groups.map(\.name).formatted(.list(type: .and))
    }

    /// What's in the way, and exactly how to resolve it in the app.
    private func explain(_ blocker: AccountDeletionPlan.Blocker) -> (problem: String, fix: String) {
        switch blocker.kind {
        case "groupBalance":
            guard let balance = blocker.balance, let currency = blocker.currency else {
                return (String(localized: "Your balance in this group isn't settled yet."),
                        String(localized: "Open the group and tap Settle up."))
            }
            let amount = MoneyFormatting.string(Money(minorUnits: Int64(abs(balance)), currency: CurrencyCode(currency)))
            if balance < 0 {
                return (String(localized: "You owe \(amount) in this group."),
                        String(localized: "Open the group, tap Settle up, then Pay. It's settled once the person you paid confirms it."))
            }
            return (String(localized: "You're owed \(amount) in this group."),
                    String(localized: """
                    When someone pays you, confirm it. If they paid another way or you don't need it back, open the group, tap \
                    Settle up, and choose Mark as settled.
                    """))
        case "groupPayment":
            return (String(localized: "A payment with you is still in progress."),
                    String(localized: "Open the group to finish it: confirm or reject a payment to you, or cancel one you started."))
        case "groupReceipt":
            return (String(localized: "A receipt you're on is still being split."),
                    String(localized: "Open the group and finish your part. The person who posted it finalizes or cancels it."))
        case "groupOwner":
            return (String(localized: "You own this group, and other people have joined it."),
                    String(localized: "Open the group, tap People, then choose someone and Make owner."))
        case "roomHosted":
            return (String(localized: "Your live room is still open or waiting for payments."),
                    String(localized: """
                    On Home, open it under Receipts in progress. Finish or cancel it, or confirm the payments people reported. Rooms \
                    you finish can be deleted.
                    """))
        case "roomJoined":
            return (String(localized: "This live room is still being split."),
                    String(localized: "Ask the host to finish or cancel it."))
        case "roomOwed":
            return (String(localized: "You still owe the host in this live room."),
                    String(localized: "Open the room, pay the host, and tap I paid. It's settled once they confirm it."))
        default:
            return (String(localized: "Something here needs to be finished first."), String(localized: "Open it in Square Up to finish it."))
        }
    }

    private func load() async {
        loadFailure = nil
        do {
            plan = try await auth.accountDeletionPlan()
        } catch {
            plan = nil
            loadFailure = error.message
        }
    }

    private func sendCode() async {
        isSendingCode = true
        defer { isSendingCode = false }
        failure = nil
        do {
            verificationID = try await auth.sendDeletionCode()
            code = ""
        } catch {
            failure = error.message
            failureFocused = true
        }
    }

    private func delete() async {
        failure = nil
        let confirmation: AccountConfirmation = usesPassword ? .password(password) : .code(verificationID: verificationID ?? "", code: code)
        do {
            try await auth.deleteAccount(confirmation)
            // Back to Welcome: this sheet closes with the account's screens.
        } catch {
            failure = error.message
            failureFocused = true
            // Something new to finish first (a group changed meanwhile): show the latest.
            if case .server = error { await load() }
        }
    }
}
