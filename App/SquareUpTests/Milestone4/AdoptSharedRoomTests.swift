import Foundation
@testable import SquareUp
import Testing

/// The host's device saving a shared room's authoritative result (milestone 4: one expense,
/// created once, only when the app's totals equal the server's).
@Suite("Adopting a shared room")
struct AdoptSharedRoomTests {
    let host = MemberID()
    let maya = MemberID()
    let outsider = MemberID()
    let groupID = GroupID()
    let roomID = ReceiptRoomID()
    let fries = ReceiptItemID()
    let pizza = ReceiptItemID()
    let now = DemoScenario.fixedReferenceDate

    func money(_ minor: Int64) -> Money { Money(minorUnits: minor, currency: .usd) }

    /// A local, open room (as it was when published) in a group of Riley and Maya.
    func state() -> LedgerSnapshot {
        let group = ExpenseGroup(id: groupID, name: "Dinner", symbolName: "fork.knife",
                                 memberships: [Membership(memberID: host), Membership(memberID: maya)], createdAt: now)
        var receipt = ReceiptDraft.empty(pages: [], currency: .usd, date: now)
        receipt.merchant.value = "Fernwood"
        receipt.total.value = money(1950)
        receipt.items = [ReceiptLineItem(id: fries, name: ReceiptField("Fries"), lineTotal: ReceiptField(money(950))),
                         ReceiptLineItem(id: pizza, name: ReceiptField("Pizza"), lineTotal: ReceiptField(money(1000)))]
        var room = ReceiptRoom(id: roomID, groupID: groupID, hostID: host, receipt: receipt, createdAt: now)
        room.payerID = host
        room.state = .open
        room.participantIDs = [host, maya]
        return LedgerSnapshot(currentUserID: host, members: [Member(id: host, displayName: "Riley"), Member(id: maya, displayName: "Maya")],
                              groups: [group], expenses: [], settlements: [], receiptRooms: [room])
    }

    /// The shared room as finalized on the server (participants already mapped to members).
    func shared(_ state: LedgerSnapshot, claims: [(ReceiptItemID, MemberID)]) -> ReceiptRoom {
        var room = state.room(roomID)!
        room.claims = claims.map { ReceiptClaim(itemID: $0.0, memberID: $0.1, mode: .full, createdAt: now, updatedAt: now, revision: 9) }
        room.state = .finalized
        room.revision = 9
        return room
    }

    func adopt(_ shared: ReceiptRoom, totals: [MemberID: Money]?, on state: LedgerSnapshot, as actor: MemberID? = nil) throws -> (LedgerSnapshot, LedgerCommandResult) {
        let result = try LedgerEngine.perform(.receipt(.adoptShared(roomID, room: shared, finalTotals: totals)), on: state, actor: actor ?? host, now: now)
        return (LedgerEngine.apply(result.changes, to: state), result)
    }

    @Test func finalizedRoomCreatesOneItemizedExpense() throws {
        let start = state()
        let room = shared(start, claims: [(fries, maya), (pizza, host)])
        let (after, result) = try adopt(room, totals: [maya: money(950), host: money(1000)], on: start)
        let expenseID = try #require(result.expenseID)
        #expect(expenseID == ExpenseID(roomID.rawValue))
        let expense = try #require(after.expenses.first { $0.id == expenseID })
        #expect(expense.allocations.contains(Share(maya, money(950))))
        #expect(after.room(roomID)?.state == .finalized)
        #expect(after.room(roomID)?.history.contains { if case .sharedRoomAdopted(9) = $0.kind { true } else { false } } == true)

        // Idempotent: adopting again (poll after relaunch) changes nothing and returns the same expense.
        let (again, repeatResult) = try adopt(room, totals: [maya: money(950), host: money(1000)], on: after)
        #expect(repeatResult.isNoOp)
        #expect(repeatResult.expenseID == expenseID)
        #expect(again.expenses.count == 1)
    }

    @Test func differingTotalsSaveNothing() throws {
        let start = state()
        let room = shared(start, claims: [(fries, maya), (pizza, host)])
        #expect(throws: LedgerError.receipt(.sharedTotalsDiffer)) {
            _ = try adopt(room, totals: [maya: money(951), host: money(999)], on: start)
        }
        #expect(throws: LedgerError.receipt(.sharedTotalsDiffer)) {
            _ = try adopt(room, totals: nil, on: start)
        }
    }

    @Test func onlyTheHostAdoptsAndOnlyGroupMembersCanOwe() throws {
        let start = state()
        #expect(throws: LedgerError.receipt(.hostOnly)) {
            _ = try adopt(shared(start, claims: [(fries, maya), (pizza, host)]), totals: [:], on: start, as: maya)
        }
        // An unmatched guest isn't in the group: the expense can't be recorded for them.
        var withGuest = shared(start, claims: [(fries, outsider), (pizza, host)])
        withGuest.participantIDs.append(outsider)
        #expect(throws: LedgerError.self) {
            _ = try adopt(withGuest, totals: [outsider: money(950), host: money(1000)], on: start)
        }
    }

    @Test func cancelledRoomCancelsLocallyWithoutAnExpense() throws {
        let start = state()
        var room = start.room(roomID)!
        room.state = .cancelled
        let (after, result) = try adopt(room, totals: nil, on: start)
        #expect(result.expenseID == nil)
        #expect(after.room(roomID)?.state == .cancelled)
        #expect(after.expenses.isEmpty)
    }
}
