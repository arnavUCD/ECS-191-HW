import Foundation
@testable import SquareUp
import Testing

@Suite("M3 itemized allocation")
struct ReceiptAllocationTests {
    private func item(_ amount: String) -> ReceiptLineItem {
        ReceiptLineItem(name: ReceiptField("Item"), lineTotal: ReceiptField(dollars(amount)), isRefund: dollars(amount).isNegative)
    }

    private func claim(_ item: ReceiptLineItem, _ member: MemberID, _ mode: ClaimMode) -> ReceiptClaim {
        ReceiptClaim(itemID: item.id, memberID: member, mode: mode, createdAt: .now, updatedAt: .now, revision: 1)
    }

    private let order = [People.riley, People.maya, People.alexMorgan, People.priya]

    @Test("Equal sharing uses largest remainder with participant-order ties and discloses the cent")
    func equalShare() {
        let nachos = item("10.00")
        let result = ReceiptAllocationEngine.allocate(nachos, claims: [
            claim(nachos, People.priya, .equalShare), claim(nachos, People.riley, .equalShare), claim(nachos, People.maya, .equalShare),
        ], participants: Set(order), order: order)
        #expect(result.status == .allocated)
        #expect(result.shares == [Share(People.riley, dollars("3.34")), Share(People.maya, dollars("3.33")), Share(People.priya, dollars("3.33"))])
        #expect(result.rounding.map(\.memberID) == [People.riley])
        #expect(result.rounding.first?.amount == dollars("0.01"))
    }

    @Test("Share counts and exact amounts")
    func weightsAndExact() {
        let wine = item("45.00")
        let weighted = ReceiptAllocationEngine.allocate(wine, claims: [claim(wine, People.riley, .shares(2)), claim(wine, People.maya, .shares(1))],
                                                        participants: Set(order), order: order)
        #expect(weighted.shares.map(\.amount) == [dollars("30.00"), dollars("15.00")])

        let exact = ReceiptAllocationEngine.allocate(wine, claims: [claim(wine, People.riley, .exact(dollars("40.00"))),
                                                                    claim(wine, People.maya, .exact(dollars("4.99")))],
                                                     participants: Set(order), order: order)
        #expect(exact.status == .partial(remaining: dollars("0.01")))
        let over = ReceiptAllocationEngine.allocate(wine, claims: [claim(wine, People.riley, .exact(dollars("46.00")))],
                                                    participants: Set(order), order: order)
        #expect(over.status == .invalid(.exceeds(dollars("1.00"))))
        let mixed = ReceiptAllocationEngine.allocate(wine, claims: [claim(wine, People.riley, .exact(dollars("5.00"))),
                                                                    claim(wine, People.maya, .equalShare)],
                                                     participants: Set(order), order: order)
        #expect(mixed.status == .invalid(.mixedModes))
    }

    @Test("Shared-item editor previews add up exactly or explain the gap")
    func preview() throws {
        let pizza = item("16.00")
        #expect(try ReceiptAllocationEngine.preview(.equal([People.riley, People.maya, People.priya]), of: pizza).get().map(\.amount)
            == [dollars("5.34"), dollars("5.33"), dollars("5.33")])
        #expect(ReceiptAllocationEngine.preview(.exact([Share(People.riley, dollars("10.00"))]), of: pizza)
            == .failure(.doesNotAddUp(remaining: dollars("6.00"))))
        #expect(ReceiptAllocationEngine.preview(.exact([Share(People.riley, dollars("17.00"))]), of: pizza)
            == .failure(.doesNotAddUp(remaining: dollars("-1.00"))))
        #expect(ReceiptAllocationEngine.preview(.equal([]), of: pizza) == .failure(.noOne))
    }

    @Test("Refunds and discounts divide by magnitude and keep their sign")
    func negatives() {
        let refund = item("-10.00")
        let result = ReceiptAllocationEngine.allocate(refund, claims: [claim(refund, People.riley, .equalShare), claim(refund, People.maya, .equalShare),
                                                                       claim(refund, People.priya, .equalShare)],
                                                      participants: Set(order), order: order)
        #expect(result.shares.map(\.amount) == [dollars("-3.34"), dollars("-3.33"), dollars("-3.33")])
        #expect(result.shares.map(\.amount).sum(in: .usd) == dollars("-10.00"))
        #expect(result.rounding.first?.amount == dollars("-0.01"))
    }

    @Test("Every charge strategy on the dinner, with exact proof of equality")
    func chargeStrategies() throws {
        var room = RoomHarness()
        try room.openDinner()
        try room.claimEverything()
        var allocation = ReceiptAllocationEngine.allocate(room.room)
        #expect(allocation.isComplete)
        #expect(allocation.allocatedTotal == dollars("104.04"))
        #expect(allocation.participants.map(\.memberID) == [People.riley, People.maya, People.alexMorgan, People.priya])
        // Proportional discount: negative, and still sums to −$4.00.
        let discount = try #require(allocation.charge(room.charge(.discount).id))
        #expect(discount.shares.map(\.amount).sum(in: .usd) == dollars("-4.00"))
        #expect(discount.shares.allSatisfy { $0.amount.isNegative })

        let tip = room.charge(.tip)
        for strategy: ChargeAllocation in [
            .equal(nil), .equal([People.maya, People.priya]), .shares([MemberWeight(People.riley, 2), MemberWeight(People.maya, 1)]),
            .exact([Share(People.riley, dollars("5.00")), Share(People.alexMorgan, dollars("10.00"))]), .payer,
        ] {
            try room.run(.setChargeAllocation(room.roomID, expectedRevision: room.revision, tip.id, strategy))
            allocation = ReceiptAllocationEngine.allocate(room.room)
            #expect(allocation.charge(tip.id)?.shares.map(\.amount).sum(in: .usd) == dollars("15.00"))
            #expect(allocation.allocatedTotal == dollars("104.04"))
            #expect(allocation.isComplete)
        }
        #expect(allocation.participant(People.riley).tip == dollars("15.00"), "Payer covers the tip")
    }

    @Test("Exact charge amounts that don't add up are refused")
    func exactChargeMismatch() throws {
        var room = RoomHarness()
        try room.openDinner()
        let tip = room.charge(.tip)
        #expect(throws: LedgerError.receipt(.invalidChargeAllocation(.exactMismatch(remaining: dollars("5.00"))))) {
            try room.run(.setChargeAllocation(room.roomID, expectedRevision: room.revision, tip.id, .exact([Share(People.riley, dollars("10.00"))])))
        }
    }

    @Test("Property: random claims and strategies always conserve every cent", arguments: 0..<40)
    func conservation(seed: Int) throws {
        var generator = SeededGenerator(state: UInt64(seed + 1) &* 0x9E37_79B9_7F4A_7C15)
        var room = RoomHarness()
        try room.openDinner()
        let people = [People.riley, People.maya, People.alexMorgan, People.priya]
        for item in room.room.receipt.items {
            let count = Int.random(in: 1...4, using: &generator)
            let chosen = Array(people.shuffled(using: &generator).prefix(count))
            let split: ItemSplit = Bool.random(using: &generator)
                ? .equal(chosen)
                : .shares(chosen.map { MemberWeight($0, Int.random(in: 1...5, using: &generator)) })
            try room.run(.setItemSplit(room.roomID, expectedRevision: room.revision, item: item.id, split))
        }
        for charge in room.room.receipt.charges {
            let strategies: [ChargeAllocation] = [.proportional, .equal(nil), .payer,
                                                  .shares(people.map { MemberWeight($0, Int.random(in: 1...3, using: &generator)) })]
            try room.run(.setChargeAllocation(room.roomID, expectedRevision: room.revision, charge.id, strategies.randomElement(using: &generator)!))
        }
        let allocation = ReceiptAllocationEngine.allocate(room.room)
        #expect(allocation.isComplete)
        #expect(allocation.allocatedTotal == dollars("104.04"))
        for itemAllocation in allocation.items {
            let lineTotal = room.room.receipt.item(itemAllocation.itemID)!.amount
            #expect(itemAllocation.shares.map(\.amount).sum(in: .usd) == lineTotal)
        }
        for charge in room.room.receipt.charges {
            #expect(allocation.charge(charge.id)?.shares.map(\.amount).sum(in: .usd) == charge.value)
        }
        // Deterministic: the same room allocates identically.
        #expect(ReceiptAllocationEngine.allocate(room.room) == allocation)
    }
}

@Suite("M3 long receipts")
struct LongReceiptTests {
    /// §15 "a room with at least 100 line items": structuring, allocation, and the room summary stay
    /// fast and exact. (Scrolling uses lazy stacks; this guards the per-render derivation cost.)
    @Test("120 items across three pages structure, allocate, and summarize quickly and exactly")
    func hundredItems() throws {
        let pages = (1...3).map { ReceiptAssetID(UUID(uuidString: String(format: "AAAAAAAA-0000-4000-8000-%012d", $0))!) }
        var regions: [RecognizedRegion] = []
        var expectedUnits: Int64 = 0
        for (pageIndex, page) in pages.enumerated() {
            var rows: [(String, String?)] = pageIndex == 0 ? [("Warehouse Party Supply", nil)] : []
            for index in 0..<40 {
                let units = Int64(100 + index * 7 + pageIndex)
                expectedUnits += units
                rows.append(("Item \(pageIndex)-\(index)", String(format: "%d.%02d", units / 100, units % 100)))
            }
            if pageIndex == 2 { rows.append(("TOTAL", String(format: "%d.%02d", expectedUnits / 100, expectedUnits % 100))) }
            regions += ReceiptFixtures.regions(rows, page: page, top: 0.02).map {
                RecognizedRegion(id: ReceiptRegionID(DerivedID.make($0.id.rawValue, pageIndex)), pageID: page, text: $0.text,
                                 confidence: 1, bounds: ReceiptRect(x: $0.bounds.x, y: $0.bounds.y / 1.4, width: $0.bounds.width, height: 0.012),
                                 readingOrder: $0.readingOrder)
            }
        }
        let clock = ContinuousClock()
        let started = clock.now
        let proposal = DeterministicReceiptStructurer.propose(ReceiptStructuringInput(
            pages: pages.map { ReceiptFixtures.page($0) }, regions: regions, defaultCurrency: .usd, captureDate: .now, idSeed: UUID()
        ))
        #expect(proposal.items.count == 120)
        #expect(proposal.total.value == Money(minorUnits: expectedUnits))

        var room = RoomHarness()
        var draft = ReceiptDraft.empty(pages: pages.map { ReceiptFixtures.page($0) }, currency: .usd, date: .now)
        draft.regions = regions
        draft = proposal.applied(to: draft)
        try room.run(.createDraft(room.roomID, groupID: room.group, pages: draft.pages, currency: .usd))
        try room.run(.saveDraft(room.roomID, expectedRevision: room.revision, receipt: draft, groupID: room.group, payerID: People.riley))
        try room.run(.confirmReceipt(room.roomID, expectedRevision: room.revision))
        try room.run(.openRoom(room.roomID, expectedRevision: room.revision, participants: [People.riley, People.maya, People.alexMorgan, People.priya]))
        let people = [People.riley, People.maya, People.alexMorgan, People.priya]
        for (index, item) in room.room.receipt.items.enumerated() {
            try room.run(.claim(room.roomID, expectedRevision: room.revision, item: item.id, .share), as: people[index % 4])
        }
        let summary = ReceiptRoomSummary.make(room: room.room, snapshot: room.engine.state, actorID: People.maya)
        #expect(summary.allocation.isComplete)
        #expect(summary.allocated == Money(minorUnits: expectedUnits))
        #expect(clock.now - started < .seconds(5))
    }
}
