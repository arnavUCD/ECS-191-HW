import AppIntents
import Foundation
import OSLog

/// "Add an expense" — opens the composer in the foreground.
struct AddExpenseIntent: AppIntent {
    static let title: LocalizedStringResource = "Add an Expense"
    static let description = IntentDescription("Opens Square Up to record a shared expense.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Dependency private var router: AppRouter

    @MainActor
    func perform() async throws -> some IntentResult {
        Log.intents.info("AddExpenseIntent")
        router.presentComposer()
        return .result()
    }
}

/// Milestone 3 (optional §4.2): "Scan a receipt" — opens the app at the capture flow. It never
/// captures, recognizes, or saves anything by itself; the person reviews everything in the app.
struct ScanReceiptIntent: AppIntent {
    static let title: LocalizedStringResource = "Scan a Receipt"
    static let description = IntentDescription("Opens Square Up to scan or import a receipt and split it item by item.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Dependency private var router: AppRouter

    @MainActor
    func perform() async throws -> some IntentResult {
        Log.intents.info("ScanReceiptIntent")
        router.presentReceiptCapture()
        return .result()
    }
}

/// "Show my balances" — answers with the same deterministic summary Home shows.
///
/// Requires the device to be unlocked: balances are sensitive and Siri may speak them aloud.
struct ShowBalancesIntent: AppIntent {
    static let title: LocalizedStringResource = "Show My Balances"
    static let description = IntentDescription("Tells you who owes you, what you owe, and which payments need you, across your groups.")
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Dependency private var session: AppSession

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        Log.intents.info("ShowBalancesIntent")
        // Only the signed-in account's own ledger; nothing while signed out.
        guard let ledger = session.scope?.environment.ledger else {
            return .result(dialog: IntentDialog(stringLiteral: String(localized: "Open Square Up and sign in first.")))
        }
        let snapshot = try await ledger.snapshot()
        guard let summary = HomeSummaryBuilder.build(from: snapshot) else {
            return .result(dialog: IntentDialog(stringLiteral: String(localized: "Open Square Up to finish setting up.")))
        }
        return .result(dialog: IntentDialog(stringLiteral: BalanceSpeech.summary(summary)))
    }
}

struct SquareUpShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddExpenseIntent(),
            phrases: [
                "Add an expense in \(.applicationName)",
                "Split a bill in \(.applicationName)",
            ],
            shortTitle: "Add Expense",
            systemImageName: "plus.circle"
        )
        AppShortcut(
            intent: ScanReceiptIntent(),
            phrases: [
                "Scan a receipt in \(.applicationName)",
                "Split a receipt in \(.applicationName)",
            ],
            shortTitle: "Scan Receipt",
            systemImageName: "doc.viewfinder"
        )
        AppShortcut(
            intent: ShowBalancesIntent(),
            phrases: [
                "Show my balances in \(.applicationName)",
                "Who owes me in \(.applicationName)",
            ],
            shortTitle: "My Balances",
            systemImageName: "person.2.circle"
        )
    }
}

/// Plain-language balance summaries for Siri, Shortcuts, and accessibility announcements.
nonisolated enum BalanceSpeech {
    static func summary(_ summary: HomeSummary, locale: Locale = .autoupdatingCurrent) -> String {
        guard summary.hasGroups else {
            return String(localized: "You aren't in any groups yet.")
        }
        let net = MoneyFormatting.string(summary.position.net.magnitude, locale: locale)
        var sentence: String
        switch summary.position.direction {
        case .owed:
            sentence = Inflect.string("Overall, you're owed \(net) across ^[\(summary.activeGroupCount) group](inflect: true).")
        case .owe:
            sentence = Inflect.string("Overall, you owe \(net) across ^[\(summary.activeGroupCount) group](inflect: true).")
        case .square:
            sentence = Inflect.string("You're all square across ^[\(summary.activeGroupCount) group](inflect: true).")
        }
        if summary.position.owedToYou.isPositive, summary.position.youOwe.isPositive {
            let owed = MoneyFormatting.string(summary.position.owedToYou, locale: locale)
            let owe = MoneyFormatting.string(summary.position.youOwe, locale: locale)
            sentence += " " + String(localized: "Friends owe you \(owed), and you owe \(owe).")
        }
        // Pending settlement actions: payments to confirm, and payments you started but didn't finish.
        let pendingPayments = summary.paymentsToConfirm.count + summary.unfinishedPayments.count
        if pendingPayments > 0 {
            sentence += " " + Inflect.string("You have ^[\(pendingPayments) payment](inflect: true) to confirm or finish.")
        }
        return sentence
    }
}
