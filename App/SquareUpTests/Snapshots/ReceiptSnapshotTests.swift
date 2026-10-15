import Foundation
import SnapshotTesting
@testable import SquareUp
import SwiftUI
import Testing
import UIKit

/// Milestone 3 visual regression (milestone 3 §17.5): every major receipt and room state, light and
/// dark, narrow, and at an accessibility text size. Uses the fictional sample receipt image.
@Suite("Snapshots · M3 receipts", .serialized)
@MainActor
struct ReceiptSnapshotTests {
    private static let services = ReceiptServices.temporary()

    private func assertScreen<V: View>(
        _ view: V, named name: String, size: CGSize = SnapshotHost.phone, style: UIUserInterfaceStyle = .dark,
        fileID: StaticString = #fileID, file: StaticString = #filePath, testName: String = #function, line: UInt = #line, column: UInt = #column
    ) async {
        let image = await SnapshotHost.render(view, size: size, style: style, settle: .milliseconds(1800))
        assertSnapshot(of: image, as: .image(precision: 0.99), named: name, fileID: fileID, file: file, testName: testName, line: line, column: column)
    }

    /// The bundled image stored once as a page, with a fixed identity.
    private func samplePage() async throws -> ReceiptAsset {
        let data = try Data(contentsOf: #require(SampleReceipt.imageURL))
        return try await Self.services.assets.importImage(
            data, id: ReceiptAssetID(UUID(uuidString: "AAAAAAAA-0000-4000-8000-0000000000AA")!), source: .sample,
            createdAt: DemoScenario.fixedReferenceDate
        )
    }

    /// A draft structured from the prerecorded recognition (includes the deliberate misreading).
    private func sampleDraft(page: ReceiptAsset, corrected: Bool) async throws -> ReceiptDraft {
        let regions = try await FixtureReceiptRecognizer().recognize(page: page, imageURL: Self.services.fileURL(page.pageFileName), seed: ReceiptFixtures.seed)
        var draft = ReceiptDraft.empty(pages: [page], currency: .usd, date: DemoScenario.fixedReferenceDate)
        draft.regions = regions
        draft = DeterministicReceiptStructurer.propose(ReceiptStructuringInput(
            pages: [page], regions: regions, defaultCurrency: .usd, captureDate: DemoScenario.fixedReferenceDate, idSeed: ReceiptFixtures.seed,
            timeZone: .gmt
        )).applied(to: draft)
        draft.recognition.status = .completed
        draft.recognition.provider = .fixture
        if corrected, let index = draft.items.firstIndex(where: { $0.name.value == "Tiramisu" }) {
            draft.items[index].lineTotal.edit(Money(8.50), by: People.riley, at: DemoScenario.fixedReferenceDate)
        }
        return draft
    }

    private enum Stage { case review, open, finalReview }

    private func harness(_ stage: Stage, corrected: Bool = true) async throws -> RoomHarness {
        let page = try await samplePage()
        var harness = RoomHarness()
        try harness.run(.createDraft(harness.roomID, groupID: stage == .review ? nil : Groups.friday, pages: [page], currency: .usd))
        try await harness.run(.saveDraft(harness.roomID, expectedRevision: harness.revision, receipt: try sampleDraft(page: page, corrected: corrected),
                                         groupID: stage == .review ? nil : Groups.friday, payerID: stage == .review ? nil : People.riley))
        guard stage != .review else { return harness }
        try harness.run(.confirmReceipt(harness.roomID, expectedRevision: harness.revision))
        try harness.run(.openRoom(harness.roomID, expectedRevision: harness.revision,
                                  participants: [People.riley, People.maya, People.alexMorgan, People.priya]))
        return harness
    }

    private func flow(_ state: LedgerSnapshot, room: ReceiptRoomID?) -> some View {
        let environment = AppEnvironment(
            ledger: InMemoryLedgerStore(state, now: { DemoScenario.fixedReferenceDate }),
            connectivity: ConnectivityMonitor(forcedStatus: .online), receipts: Self.services,
            configuration: LaunchConfiguration(isUITesting: true), fixedNow: DemoScenario.fixedReferenceDate
        )
        let request = ReceiptFlowRequest(start: room.map { .resume($0) } ?? .new(groupID: Groups.friday))
        return ReceiptFlowView(request: request)
            .environment(environment)
            .environment(AppRouter())
            .squareUpTheme()
    }

    @Test func captureChooser() async {
        let view = flow(sample(), room: nil)
        await assertScreen(view, named: "dark")
    }

    @Test func processing() async throws {
        let harness = try await harness(.review)
        let environment = AppEnvironment(ledger: InMemoryLedgerStore(harness.engine.state), receipts: Self.services,
                                         configuration: LaunchConfiguration(isUITesting: true), fixedNow: DemoScenario.fixedReferenceDate)
        let model = ReceiptFlowModel(environment: environment, request: ReceiptFlowRequest(start: .resume(harness.roomID)))
        await model.load()
        model.showProcessingState(ReceiptProcessingUpdate(stage: .understanding, completedPages: 1, pageCount: 1))
        let view = NavigationStack { ReceiptProcessingView(model: model) }
            .environment(environment).environment(AppRouter()).squareUpTheme()
        await assertScreen(view, named: "dark")
    }

    @Test func reviewWithMismatch() async throws {
        let harness = try await harness(.review, corrected: false)
        let view = flow(harness.engine.state, room: harness.roomID)
        await assertScreen(view, named: "mismatch-dark")
        await assertScreen(view, named: "long-dark", size: CGSize(width: 402, height: 2300))
    }

    @Test func reviewReconciled() async throws {
        let harness = try await harness(.review)
        let view = flow(harness.engine.state, room: harness.roomID)
        await assertScreen(view, named: "clean-dark")
        await assertScreen(view, named: "narrow", size: SnapshotHost.compactPhone)
        await assertScreen(view.dynamicTypeSize(.accessibility2), named: "ax2", size: CGSize(width: 402, height: 1600))
    }

    @Test func openRoom() async throws {
        var harness = try await harness(.open)
        try harness.claim("Mushroom Risotto", as: People.riley)
        try harness.claim("Shared Nachos", .share, as: People.riley)
        try harness.claim("Shared Nachos", .share, as: People.maya)
        let view = flow(harness.engine.state, room: harness.roomID)
        await assertScreen(view, named: "host-dark", size: CGSize(width: 402, height: 2000))
        await assertScreen(view, named: "narrow", size: SnapshotHost.compactPhone)
        await assertScreen(view.dynamicTypeSize(.accessibility2), named: "ax2", size: CGSize(width: 402, height: 1600))
    }

    @Test func disputeState() async throws {
        var harness = try await harness(.open)
        try harness.claimEverything()
        try harness.run(.dispute(harness.roomID, expectedRevision: harness.revision, .item(harness.item("Truffle Fries").id),
                                 note: "I only had a couple"), as: People.maya)
        let view = flow(harness.engine.state, room: harness.roomID)
        await assertScreen(view, named: "dark", size: CGSize(width: 402, height: 2600))
    }

    @Test func sharedItemEditor() async throws {
        var harness = try await harness(.open)
        try harness.claim("Truffle Fries", .share, as: People.riley)
        try harness.claim("Truffle Fries", .share, as: People.maya)
        try harness.claim("Truffle Fries", .share, as: People.priya)
        let environment = AppEnvironment(ledger: InMemoryLedgerStore(harness.engine.state), receipts: Self.services,
                                         configuration: LaunchConfiguration(isUITesting: true), fixedNow: DemoScenario.fixedReferenceDate)
        let model = ReceiptFlowModel(environment: environment, request: ReceiptFlowRequest(start: .resume(harness.roomID)))
        await model.load()
        let summary = ReceiptRoomSummary.make(room: harness.room, snapshot: harness.engine.state, actorID: People.riley)
        let view = SharedItemEditor(flow: model, summary: summary, itemID: harness.item("Truffle Fries").id)
            .environment(environment).environment(AppRouter()).squareUpTheme()
        await assertScreen(view, named: "dark")
    }

    @Test func finalReview() async throws {
        var harness = try await harness(.open)
        try harness.claimEverything()
        try harness.run(.transition(harness.roomID, expectedRevision: harness.revision, .requestFinalReview))
        let view = flow(harness.engine.state, room: harness.roomID)
        await assertScreen(view, named: "dark", size: CGSize(width: 402, height: 2200))
    }

    @Test func itemizedExpenseDetail() async throws {
        var harness = try await harness(.open)
        try harness.claimEverything()
        try harness.run(.transition(harness.roomID, expectedRevision: harness.revision, .requestFinalReview))
        let expenseID = try #require(try harness.run(.finalize(harness.roomID, expectedRevision: harness.revision)).expenseID)
        let environment = AppEnvironment(ledger: InMemoryLedgerStore(harness.engine.state), receipts: Self.services,
                                         configuration: LaunchConfiguration(isUITesting: true), fixedNow: DemoScenario.fixedReferenceDate)
        let view = NavigationStack { ExpenseDetailView(expenseID: expenseID) }
            .environment(environment).environment(AppRouter()).squareUpTheme()
        await assertScreen(view, named: "dark", size: CGSize(width: 402, height: 2600))
    }
}
