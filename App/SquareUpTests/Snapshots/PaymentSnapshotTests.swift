import Foundation
import SnapshotTesting
@testable import SquareUp
import SwiftUI
import Testing
import UIKit

/// Milestone 2 visual regression: every major payment and confirmation state (milestone 2 §19).
@Suite("Snapshots · M2 payments", .serialized)
@MainActor
struct PaymentSnapshotTests {
    private func assertScreen<V: View>(
        _ view: V, named name: String, size: CGSize = SnapshotHost.phone, style: UIUserInterfaceStyle = .dark,
        contrast: UIAccessibilityContrast = .normal,
        fileID: StaticString = #fileID, file: StaticString = #filePath, testName: String = #function,
        line: UInt = #line, column: UInt = #column
    ) async {
        let image = await SnapshotHost.render(view, size: size, style: style, contrast: contrast)
        assertSnapshot(of: image, as: .image(precision: 0.99), named: name,
                       fileID: fileID, file: file, testName: testName, line: line, column: column)
    }

    /// Riley → Maya, Apartment 4B, with the attempt advanced to `state` (nil: no attempt).
    private func attemptState(_ state: PaymentAttemptState?) throws -> (LedgerSnapshot, PaymentAttemptID?) {
        var harness = EngineHarness(sample())
        guard let state else { return (harness.state, nil) }
        let attempt = try #require(try harness.run(.startPayment(PaymentRequest(
            groupID: Groups.apartment, payerID: People.riley, recipientID: People.maya, amount: dollars("29.69"),
            provider: .appleCash, destinationID: destination(of: People.maya, .appleCash, in: harness.state)?.id
        ))).attempt)
        try harness.run(.advancePayment(attempt.id, .openHandoff))
        if state != .handoffOpened { try harness.run(.advancePayment(attempt.id, .reportSent(externalReference: "TX-4821"))) }
        switch state {
        case .disputed: try harness.run(.advancePayment(attempt.id, .dispute(reason: "Not in my Apple Cash yet")), as: People.maya)
        case .rejected: try harness.run(.advancePayment(attempt.id, .reject(reason: nil)), as: People.maya)
        case .confirmed: try harness.run(.advancePayment(attempt.id, .confirm), as: People.maya)
        default: break
        }
        return (harness.state, attempt.id)
    }

    @Test func payingScreen() async {
        let state = sample()
        let view = SnapshotHost.screen(state) { PayingView(groupID: Groups.apartment, recipientID: People.maya) }
        await assertScreen(view, named: "all-methods-dark")
        await assertScreen(view, named: "narrow", size: SnapshotHost.compactPhone)
        await assertScreen(view, named: "increased-contrast-dark", contrast: .high)
        await assertScreen(view.dynamicTypeSize(.accessibility2), named: "ax2", size: CGSize(width: 402, height: 1400))
    }

    @Test func payingEdgeStates() async throws {
        var harness = EngineHarness(sample())
        for destination in harness.state.destinations(of: People.maya) {
            try harness.run(.deleteDestination(destination.id), as: People.maya)
        }
        await assertScreen(SnapshotHost.screen(harness.state) { PayingView(groupID: Groups.apartment, recipientID: People.maya) },
                           named: "no-methods")

        // An incomplete method stored by an older build: shown as unavailable, never opened.
        let broken = PaymentDestination(ownerID: People.maya, provider: .paypal, value: .username("not valid"), isPreferred: false,
                                        createdAt: DemoScenario.fixedReferenceDate)
        let withBroken = LedgerEngine.apply([.upsertDestination(broken)], to: sample())
        await assertScreen(SnapshotHost.screen(withBroken) { PayingView(groupID: Groups.apartment, recipientID: People.maya) },
                           named: "incomplete-method")
    }

    @Test func handoffSheet() async throws {
        let (state, id) = try attemptState(.handoffOpened)
        let attemptID = try #require(id)
        let attempt = try #require(state.attempt(attemptID))
        let view = HandoffSheet(active: ActiveHandoff(
            attempt: attempt, destination: destination(of: People.maya, .appleCash, in: state),
            recipient: try #require(state.members[People.maya]), groupName: "Apartment 4B"
        ))
        .environment(SnapshotHost.environment(state))
        .squareUpTheme()
        await assertScreen(view, named: "apple-cash")
    }

    @Test func attemptStates() async throws {
        for (state, style) in [(PaymentAttemptState.reportedSent, UIUserInterfaceStyle.dark), (.disputed, .dark), (.rejected, .dark), (.confirmed, .dark)] {
            let (ledger, id) = try attemptState(state)
            await assertScreen(SnapshotHost.screen(ledger) { PaymentAttemptView(attemptID: id!) }, named: "\(state.rawValue)", style: style)
        }
    }

    @Test func recipientConfirmation() async throws {
        let state = sample()
        let seeded = try #require(state.paymentAttempts.first { $0.state == .reportedSent })
        await assertScreen(SnapshotHost.screen(state) { PaymentAttemptView(attemptID: seeded.id) }, named: "recipient-dark")
    }

    @Test func settlementPlan() async throws {
        let (state, _) = try attemptState(.reportedSent)
        await assertScreen(SnapshotHost.screen(state) { SettlementPlanView(groupID: Groups.apartment) }, named: "apartment-pending")
        await assertScreen(SnapshotHost.screen(sample()) { SettlementPlanView(groupID: Groups.tahoe) }, named: "tahoe-dark")
    }

    @Test func groupAndExpenseScreens() async throws {
        var harness = EngineHarness(sample())
        var costco = expense("Costco run", in: harness.state)
        costco.title = "Costco run (bulk)"
        try harness.run(.updateExpense(costco))
        try harness.run(.deleteExpense(expense("Wi-Fi", in: harness.state).id))
        await assertScreen(SnapshotHost.screen(harness.state) { ExpenseDetailView(expenseID: costco.id) }, named: "expense-edited")
        await assertScreen(SnapshotHost.screen(harness.state) { GroupDetailView(groupID: Groups.apartment) }, named: "group-with-deleted",
                           size: CGSize(width: 402, height: 1300))
        await assertScreen(GroupEditorView(request: .create).environment(SnapshotHost.environment(sample())).environment(AppRouter()).squareUpTheme(),
                           named: "new-group")
        await assertScreen(SnapshotHost.screen(sample()) { PaymentProfileView() }, named: "payment-profile")
    }
}
