import Foundation
import SnapshotTesting
@testable import SquareUp
import SwiftUI
import Testing
import UIKit

/// Receipt split (October 2026): the choice after review, "Add to a group", "Split with people now"
/// without a server, joining by code, and a finalized temporary room's settle-up for the payer and
/// for someone who owes them (open, reported, all square). Fictional data only.
@Suite("Snapshots · receipt split", .serialized)
@MainActor
struct ReceiptSplitSnapshotTests {
    private static let services = ReceiptServices.temporary()

    private func assertScreen<V: View>(
        _ view: V, named name: String, size: CGSize = SnapshotHost.phone, style: UIUserInterfaceStyle = .dark,
        fileID: StaticString = #fileID, file: StaticString = #filePath, testName: String = #function, line: UInt = #line, column: UInt = #column
    ) async {
        let image = await SnapshotHost.render(view, size: size, style: style, settle: .milliseconds(1500))
        assertSnapshot(of: image, as: .image(precision: 0.99), named: name, fileID: fileID, file: file, testName: testName, line: line, column: column)
    }

    /// A reviewed draft with no group yet — where both paths start.
    private func reviewedFlow() async throws -> (ReceiptFlowModel, AppEnvironment) {
        var harness = RoomHarness()
        try harness.run(.createDraft(harness.roomID, groupID: nil, pages: [ReceiptFixtures.page()], currency: .usd))
        try harness.run(.saveDraft(harness.roomID, expectedRevision: 1, receipt: ReceiptFixtures.draft(ReceiptFixtures.dinner), groupID: nil, payerID: nil))
        let environment = AppEnvironment(ledger: InMemoryLedgerStore(harness.engine.state, now: { DemoScenario.fixedReferenceDate }),
                                         connectivity: ConnectivityMonitor(forcedStatus: .online), receipts: Self.services,
                                         configuration: LaunchConfiguration(isUITesting: true), fixedNow: DemoScenario.fixedReferenceDate)
        let model = ReceiptFlowModel(environment: environment, request: ReceiptFlowRequest(start: .resume(harness.roomID)))
        await model.load()
        return (model, environment)
    }

    private func screen(_ content: some View, _ environment: AppEnvironment) -> some View {
        NavigationStack { content }.environment(environment).environment(AppRouter()).squareUpTheme()
    }

    @Test func choosePath() async throws {
        let (model, environment) = try await reviewedFlow()
        let view = screen(ChoosePathView(flow: model), environment)
        await assertScreen(view, named: "dark")
        await assertScreen(view, named: "light", style: .light)
        await assertScreen(view, named: "narrow", size: SnapshotHost.compactPhone)
        await assertScreen(view.dynamicTypeSize(.accessibility2), named: "ax2", size: CGSize(width: 402, height: 1500))
    }

    @Test func addToGroup() async throws {
        let (model, environment) = try await reviewedFlow()
        let view = screen(AddToGroupView(flow: model), environment)
        await assertScreen(view, named: "dark")
        await assertScreen(view, named: "narrow", size: SnapshotHost.compactPhone)
    }

    /// No server in this build: explained, and "Create room" stays off.
    @Test func splitNowWithoutServer() async throws {
        let (model, environment) = try await reviewedFlow()
        let view = screen(SplitNowView(flow: model), environment)
        await assertScreen(view, named: "dark", size: CGSize(width: 402, height: 1300))
        await assertScreen(view.dynamicTypeSize(.accessibility2), named: "ax2", size: CGSize(width: 402, height: 2200))
    }

    @Test func joinByCode() async {
        let environment = AppEnvironment(ledger: InMemoryLedgerStore(sample()), configuration: LaunchConfiguration(isUITesting: true),
                                         fixedNow: DemoScenario.fixedReferenceDate)
        let view = JoinWithLinkSheet().environment(environment).environment(AppRouter()).squareUpTheme()
        await assertScreen(view, named: "dark")
    }

    // MARK: Settle-up (a finalized temporary room)

    private typealias Fix = RemoteFixtures

    /// Sam had the fries (9.50) and Riley the pizza (10.00); tax 2.15 splits 1.05 / 1.10.
    private func finalized(viewer: MemberID, payment: String, attempts: [RoomPaymentDTO.Attempt] = [], endReason: String? = nil) throws -> RoomDTO {
        let base = Fix.room(revision: 9, claims: [Fix.claim(Fix.fries, by: Fix.guest), Fix.claim(Fix.pizza, by: Fix.host)],
                            state: "finalized", viewer: viewer)
        let totals = [ParticipantTotalDTO(participantId: Fix.id(Fix.host), items: 1000, tax: 110, tip: 0, fees: 0, discounts: 0, adjustments: 0, total: 1110,
                                          itemShares: [ItemShareDTO(itemId: Fix.id(Fix.pizza), amount: 1000)]),
                      ParticipantTotalDTO(participantId: Fix.id(Fix.guest), items: 950, tax: 105, tip: 0, fees: 0, discounts: 0, adjustments: 0, total: 1055,
                                          itemShares: [ItemShareDTO(itemId: Fix.id(Fix.fries), amount: 950)])]
        var room = RoomDTO(
            roomId: base.roomId, revision: base.revision, state: base.state, hostParticipantId: base.hostParticipantId, payerId: base.payerId,
            receipt: base.receipt, participants: base.participants, participantOrder: base.participantOrder, claims: base.claims,
            disputes: [], reviews: [], needsReview: [], payerAcceptsFullReceipt: false,
            allocation: AllocationDTO(receiptTotal: 2165, allocatedTotal: 2165, remaining: 0, isComplete: true, participants: totals),
            finalization: FinalizationDTO(finalizedAt: "2026-09-25T12:30:00.000000Z", finalizedBy: Fix.id(Fix.host), revision: 8, participants: totals,
                                          payments: [ParticipantAmountDTO(participantId: Fix.id(Fix.guest), amount: 1055)], total: 2165),
            assets: [], viewer: base.viewer, updatedAt: base.updatedAt
        )
        room.kind = "temporary"
        room.unreviewed = []
        room.expiresAt = "2026-10-25T12:30:00.000000Z"
        room.payments = [RoomPaymentDTO(participantId: Fix.id(Fix.guest), amount: 1055, state: payment, attempts: attempts,
                                        confirmedAt: payment == "confirmed" ? "2026-09-26T09:00:00.000000Z" : nil)]
        if let endReason {
            room.endReason = endReason
            room.closedAt = "2026-09-26T09:00:00.000000Z"
        }
        return room
    }

    private func reported(_ state: String = "reportedSent") -> RoomPaymentDTO.Attempt {
        RoomPaymentDTO.Attempt(id: "a1", provider: "venmo", destinationId: nil, state: state,
                               history: [.init(state: "reportedSent", actorId: Fix.id(Fix.guest), at: "2026-09-25T13:00:00.000000Z", note: nil)],
                               externalReference: nil, amount: 1055)
    }

    private func settle(_ room: RoomDTO) async -> some View {
        let transport = ScriptedTransport { request, _ in
            if request.url?.path().hasSuffix("/payment-destinations") == true { return (403, Fix.errorBody("reveal_not_allowed")) }
            return (200, Fix.roomBody(room))
        }
        let session = Fix.session(transport)
        let environment = AppEnvironment(ledger: session, connectivity: ConnectivityMonitor(forcedStatus: .online), receipts: Self.services,
                                         configuration: LaunchConfiguration(isUITesting: true), fixedNow: DemoScenario.fixedReferenceDate,
                                         remoteRoom: session)
        let model = ReceiptFlowModel(environment: environment, request: ReceiptFlowRequest(start: .resume(Fix.roomID)))
        await model.load()
        return screen(TemporaryRoomSettleView(flow: model, done: {}), environment)
    }

    @Test func settleOwed() async throws {
        let view = await settle(try finalized(viewer: Fix.guest, payment: "owed"))
        await assertScreen(view, named: "guest-dark", size: CGSize(width: 402, height: 1300))
        await assertScreen(view, named: "guest-narrow", size: SnapshotHost.compactPhone)
    }

    @Test func settleReportedForThePayer() async throws {
        let view = await settle(try finalized(viewer: Fix.host, payment: "reportedSent", attempts: [reported()]))
        await assertScreen(view, named: "host-dark", size: CGSize(width: 402, height: 1300))
        await assertScreen(view.dynamicTypeSize(.accessibility2), named: "host-ax2", size: CGSize(width: 402, height: 2400))
    }

    @Test func settleAllSquare() async throws {
        let view = await settle(try finalized(viewer: Fix.guest, payment: "confirmed", attempts: [reported("confirmed")], endReason: "allSquare"))
        await assertScreen(view, named: "guest-dark", size: CGSize(width: 402, height: 1300))
        await assertScreen(view, named: "guest-light", size: CGSize(width: 402, height: 1300), style: .light)
    }
}
