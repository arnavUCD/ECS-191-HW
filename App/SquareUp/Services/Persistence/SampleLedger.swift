import Foundation

/// Deterministic demonstration data (SAMPLE-ONLY — labeled as such in Profile).
///
/// Four personal groups: Apartment 4B (roommates), Tahoe Ski Weekend (a trip with a payment
/// awaiting confirmation), Friday Dinner Crew (fully settled), and the Coastal Weekend Trip, which
/// shows every way to split — equal, shares, exact, two payers — plus a recorded payment, an
/// unsettled balance, and an open Live Receipt Room for the dinner. Identifiers are fixed and dates
/// are offsets from `referenceDate`, so the same inputs always produce the same ledger.
nonisolated enum SampleLedger {
    nonisolated enum Person: Int, CaseIterable, Sendable {
        case riley = 1, maya, alexMorgan, jordan, priya, sam, alexRivera, dev, lena

        var id: MemberID { MemberID(SampleLedger.uuid(rawValue)) }

        func member(longNames: Bool) -> Member {
            switch self {
            case .riley: Member(id: id, displayName: longNames ? "Riley Alexandra Park-Montgomery" : "Riley Park", handle: "riley")
            case .maya: Member(id: id, displayName: longNames ? "Maya Isabella Chen-Rodríguez" : "Maya Chen", handle: "maya.c")
            case .alexMorgan: Member(id: id, displayName: "Alex Morgan", handle: "alexm")
            case .jordan: Member(id: id, displayName: longNames ? "Jordan Bartholomew Brooks III" : "Jordan Brooks", handle: "jbrooks")
            case .priya: Member(id: id, displayName: longNames ? "Priya Lakshmi Natarajan-Venkataraman" : "Priya Natarajan", handle: "priya")
            case .sam: Member(id: id, displayName: "Sam Okafor", handle: "sam")
            case .alexRivera: Member(id: id, displayName: "Alex Rivera", handle: "arivera")
            case .dev: Member(id: id, displayName: "Dev Kapoor", handle: "dev")
            case .lena: Member(id: id, displayName: longNames ? "Maximiliana Alejandra Fernández-Castellanos" : "Lena Fischer", handle: "lena")
            }
        }
    }

    nonisolated struct Options: Sendable {
        var currentUser: Person = .riley
        /// Multiplies every amount (large-amount layout fixtures).
        var amountMultiplier: Decimal = 1
        var longNames = false

        init(currentUser: Person = .riley, amountMultiplier: Decimal = 1, longNames: Bool = false) {
            self.currentUser = currentUser
            self.amountMultiplier = amountMultiplier
            self.longNames = longNames
        }
    }

    /// 103 belonged to the retired sample organization; it is reserved for its removal
    /// (`LegacyRecords.retiredSampleOrganizationID`) and never reused.
    enum GroupKey: Int {
        case apartment = 101, tahoe = 102, friday = 104, coastal = 105
        var id: GroupID { GroupID(SampleLedger.uuid(rawValue)) }
    }

    static func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "5A5A5A5A-0000-4000-8000-%012d", value))!
    }

    // Declarative fixture data reads best as one list; splitting it would scatter the scenario.
    // swiftlint:disable:next function_body_length
    static func make(referenceDate: Date, options: Options = Options()) -> LedgerSnapshot {
        func daysAgo(_ days: Double) -> Date { referenceDate.addingTimeInterval(-days * 86_400) }
        func usd(_ value: Decimal) -> Money { Money(value * options.amountMultiplier, .usd) }

        let members = Person.allCases.map { $0.member(longNames: options.longNames) }
        var expenseCounter = 1000

        func nextExpenseID() -> ExpenseID {
            expenseCounter += 1
            return ExpenseID(uuid(expenseCounter))
        }

        /// Any split: `allocate` divides the total with the same calculator manual entry uses.
        func expense(
            _ group: GroupKey, _ title: String, merchant: String?, total: Money, payments: [Share], method: SplitMethod,
            category: ExpenseCategory, date: Date, allocate: (Money) throws -> SplitResult
        ) -> Expense {
            guard let split = try? allocate(total) else { preconditionFailure("Invalid sample split for \(title)") }
            return Expense(
                id: nextExpenseID(), groupID: group.id, title: title, merchant: merchant, date: date, total: total,
                category: category, splitMethod: method, payments: payments, allocations: split.shares,
                createdBy: payments.first?.memberID ?? options.currentUser.id
            )
        }

        func equal(
            _ group: GroupKey, _ title: String, merchant: String?, total: Money, paidBy payer: Person,
            among people: [Person], category: ExpenseCategory, date: Date
        ) -> Expense {
            expense(group, title, merchant: merchant, total: total, payments: [Share(payer.id, total)], method: .equal,
                    category: category, date: date) { try SplitCalculator.equal($0, among: people.map(\.id)) }
        }

        let coastal: [Person] = [.riley, .maya, .dev, .priya]

        let groups = [
            ExpenseGroup(
                id: GroupKey.apartment.id,
                name: options.longNames ? "Apartment 4B — Graduate Housing on Russell Boulevard" : "Apartment 4B",
                symbolName: "house.fill",
                memberships: [.init(memberID: Person.riley.id), .init(memberID: Person.maya.id), .init(memberID: Person.jordan.id)],
                createdAt: daysAgo(120)
            ),
            ExpenseGroup(
                id: GroupKey.tahoe.id, name: "Tahoe Ski Weekend", symbolName: "mountain.2.fill",
                memberships: [Person.riley, .alexMorgan, .alexRivera, .sam, .lena].map { .init(memberID: $0.id) },
                createdAt: daysAgo(30)
            ),
            ExpenseGroup(
                id: GroupKey.coastal.id, name: options.longNames ? "Coastal Weekend Trip — Mendocino Beach House" : "Coastal Weekend Trip",
                symbolName: "beach.umbrella.fill", memberships: coastal.map { .init(memberID: $0.id) },
                createdAt: daysAgo(10), details: "Beach house, Friday to Sunday"
            ),
            ExpenseGroup(
                id: GroupKey.friday.id, name: "Friday Dinner Crew", symbolName: "fork.knife",
                memberships: [Person.riley, .maya, .alexMorgan, .priya].map { .init(memberID: $0.id) },
                createdAt: daysAgo(90)
            ),
        ]

        let expenses: [Expense] = [
            // Apartment 4B
            equal(.apartment, "October utilities", merchant: "PG&E", total: usd(186.42), paidBy: .maya,
                  among: [.riley, .maya, .jordan], category: .utilities, date: daysAgo(3)),
            equal(.apartment, "Costco run", merchant: "Costco", total: usd(97.35), paidBy: .riley,
                  among: [.riley, .maya, .jordan], category: .groceries, date: daysAgo(1)),
            equal(.apartment, "Wi-Fi", merchant: "Sonic", total: usd(65.00), paidBy: .jordan,
                  among: [.riley, .maya, .jordan], category: .utilities, date: daysAgo(9)),
            // Tahoe
            equal(.tahoe, "Cabin rental", merchant: "Lakeview Cabins", total: usd(1240.00), paidBy: .riley,
                  among: [.riley, .alexMorgan, .alexRivera, .sam, .lena], category: .travel, date: daysAgo(12)),
            equal(.tahoe, "Lift tickets", merchant: "Palisades Tahoe", total: usd(845.50), paidBy: .alexMorgan,
                  among: [.riley, .alexMorgan, .alexRivera, .sam, .lena], category: .entertainment, date: daysAgo(11)),
            equal(.tahoe, "Gas & snacks", merchant: "Chevron", total: usd(112.80), paidBy: .sam,
                  among: [.riley, .sam, .lena], category: .transport, date: daysAgo(10)),
            // Coastal Weekend Trip — every split method
            equal(.coastal, "Beach house rental", merchant: "Driftwood Cottages", total: usd(640.00), paidBy: .riley,
                  among: coastal, category: .travel, date: daysAgo(8)),
            expense(.coastal, "Groceries for the house", merchant: "Harbor Market", total: usd(96.00),
                    payments: [Share(Person.maya.id, usd(96.00))], method: .shares, category: .groceries, date: daysAgo(7.5)) {
                try SplitCalculator.shares($0, weights: [(Person.riley.id, 2), (Person.maya.id, 1), (Person.dev.id, 1), (Person.priya.id, 2)])
            },
            expense(.coastal, "Gas", merchant: "Coastline Fuel", total: usd(58.40),
                    payments: [Share(Person.dev.id, usd(58.40))], method: .exact, category: .transport, date: daysAgo(7)) {
                try SplitCalculator.exact($0, amounts: [(Person.riley.id, usd(20.00)), (Person.dev.id, usd(20.00)), (Person.priya.id, usd(18.40))])
            },
            equal(.coastal, "Beach parking", merchant: "Pelican Point Lot", total: usd(24.00), paidBy: .priya,
                  among: coastal, category: .transport, date: daysAgo(6.5)),
            // Two payers: Riley and Maya each put part of the kayak tour on their cards.
            expense(.coastal, "Kayak tour", merchant: "Blue Cove Paddle Co.", total: usd(180.00),
                    payments: [Share(Person.riley.id, usd(100.00)), Share(Person.maya.id, usd(80.00))], method: .equal,
                    category: .entertainment, date: daysAgo(6)) {
                try SplitCalculator.equal($0, among: coastal.map(\.id))
            },
            // Friday Dinner Crew — fully settled
            equal(.friday, "Nopa dinner", merchant: "Nopa", total: usd(156.00), paidBy: .alexMorgan,
                  among: [.riley, .maya, .alexMorgan, .priya], category: .food, date: daysAgo(20)),
        ]

        let settlements: [Settlement] = [
            Settlement(id: SettlementID(uuid(2001)), groupID: GroupKey.apartment.id, fromID: Person.jordan.id,
                       toID: Person.riley.id, amount: usd(10.78), date: daysAgo(0.5), recordedBy: Person.jordan.id),
            Settlement(id: SettlementID(uuid(2002)), groupID: GroupKey.tahoe.id, fromID: Person.lena.id,
                       toID: Person.riley.id, amount: usd(248.00), date: daysAgo(4), recordedBy: Person.riley.id),
            Settlement(id: SettlementID(uuid(2003)), groupID: GroupKey.friday.id, fromID: Person.riley.id,
                       toID: Person.alexMorgan.id, amount: usd(39.00), date: daysAgo(18), recordedBy: Person.riley.id),
            Settlement(id: SettlementID(uuid(2004)), groupID: GroupKey.friday.id, fromID: Person.maya.id,
                       toID: Person.alexMorgan.id, amount: usd(39.00), date: daysAgo(18), recordedBy: Person.maya.id),
            Settlement(id: SettlementID(uuid(2005)), groupID: GroupKey.friday.id, fromID: Person.priya.id,
                       toID: Person.alexMorgan.id, amount: usd(39.00), date: daysAgo(17), recordedBy: Person.alexMorgan.id),
            // Coastal: Priya paid Riley back part of what she owes; the rest is still unsettled.
            Settlement(id: SettlementID(uuid(2006)), groupID: GroupKey.coastal.id, fromID: Person.priya.id,
                       toID: Person.riley.id, amount: usd(100.00), date: daysAgo(3), recordedBy: Person.riley.id, provider: .zelle,
                       confirmedAt: daysAgo(3), confirmedBy: Person.riley.id),
        ]

        let destinations = sampleDestinations(createdAt: daysAgo(30))

        // A payment Alex Rivera reported sending Riley for the Tahoe trip, awaiting Riley's
        // confirmation — demonstrates the recipient side without switching identities.
        let reportedID = PaymentAttemptID(uuid(4001))
        let venmo = destinations.first { $0.ownerID == Person.riley.id && $0.provider == .venmo }
        let reported = PaymentAttempt(
            id: reportedID, groupID: GroupKey.tahoe.id, payerID: Person.alexRivera.id, recipientID: Person.riley.id,
            destinationID: venmo?.id, provider: .venmo, amount: usd(417.10),
            memo: "Square Up · Tahoe Ski Weekend · \(PaymentAttempt.reference(for: reportedID))",
            state: .reportedSent,
            history: [
                PaymentAttemptTransition(state: .methodSelected, actorID: Person.alexRivera.id, date: daysAgo(0.3)),
                PaymentAttemptTransition(state: .reportedSent, actorID: Person.alexRivera.id, date: daysAgo(0.25)),
            ],
            externalReference: nil
        )
        let events = [
            AuditEvent(id: AuditEventID(uuid(5001)), groupID: GroupKey.tahoe.id, actorID: Person.alexRivera.id, date: daysAgo(0.25),
                       sequence: 1, kind: .paymentReported(PaymentEventInfo(reported))),
        ]

        return LedgerSnapshot(
            currentUserID: options.currentUser.id,
            members: members,
            groups: groups,
            expenses: expenses,
            settlements: settlements,
            paymentDestinations: destinations,
            paymentAttempts: options.amountMultiplier == 1 ? [reported] : [],
            events: options.amountMultiplier == 1 ? events : [],
            receiptRooms: options.amountMultiplier == 1 ? [coastalDinnerRoom(referenceDate: referenceDate)] : []
        )
    }

    /// The Coastal Weekend Trip dinner as an open Live Receipt Room (entered by hand, no image):
    /// Riley and Maya have claimed and are sharing the calamari; the rest is still unclaimed.
    static func coastalDinnerRoom(referenceDate: Date) -> ReceiptRoom {
        let opened = referenceDate.addingTimeInterval(-5 * 86_400)
        let host = Person.riley.id
        func money(_ value: Decimal) -> Money { Money(value, .usd) }
        func field<V: Hashable & Codable & Sendable>(_ value: V) -> ReceiptField<V> { .entered(value, by: host, at: opened) }
        func item(_ key: Int, _ name: String, _ total: Decimal, quantity: Int? = nil, unit: Decimal? = nil) -> ReceiptLineItem {
            ReceiptLineItem(id: ReceiptItemID(uuid(key)), name: field(name), quantity: quantity, unitPrice: unit.map(money),
                            lineTotal: field(money(total)))
        }
        let items = [
            item(7101, "Fish Tacos", 19.00, quantity: 2, unit: 9.50),
            item(7102, "Clam Chowder", 8.50),
            item(7103, "Grilled Salmon", 24.00),
            item(7104, "Veggie Burger", 15.50),
            item(7105, "Shared Calamari", 14.00),
            item(7106, "Lemonade", 8.00, quantity: 2, unit: 4.00),
        ]
        var receipt = ReceiptDraft.empty(pages: [], currency: .usd, date: opened)
        receipt.merchant = field("Driftwood Kitchen")
        receipt.date = field(opened)
        receipt.currency = field(.usd)
        receipt.items = items
        receipt.charges = [
            ReceiptCharge(id: ReceiptChargeID(uuid(7201)), kind: .tax, label: "Tax", amount: field(money(7.79))),
            ReceiptCharge(id: ReceiptChargeID(uuid(7202)), kind: .tip, label: "Tip", amount: field(money(16.00))),
        ]
        receipt.subtotal = field(Optional(money(89.00)))
        receipt.total = field(Optional(money(112.79)))
        receipt.recognition.status = .skipped
        receipt.recognition.provider = .manual

        let participants = [Person.riley, .maya, .dev, .priya].map(\.id)
        func claim(_ item: Int, _ member: Person, _ mode: ClaimMode, revision: Int) -> ReceiptClaim {
            ReceiptClaim(itemID: ReceiptItemID(uuid(item)), memberID: member.id, mode: mode, createdAt: opened, updatedAt: opened, revision: revision)
        }
        var room = ReceiptRoom(id: ReceiptRoomID(uuid(7001)), groupID: GroupKey.coastal.id, hostID: host, receipt: receipt, createdAt: opened)
        room.payerID = host
        room.state = .open
        room.participantIDs = participants
        room.confirmedAt = opened
        room.openedAt = opened
        room.claims = [
            claim(7101, .riley, .full, revision: 4),
            claim(7103, .maya, .full, revision: 5),
            claim(7105, .riley, .equalShare, revision: 6),
            claim(7105, .maya, .equalShare, revision: 7),
        ]
        room.revision = 7
        room.history = [
            ReceiptRoomEvent(sequence: 1, actorID: host, date: opened, revision: 1, kind: .created(source: nil)),
            ReceiptRoomEvent(sequence: 2, actorID: host, date: opened, revision: 2,
                             kind: .receiptConfirmed(groupID: GroupKey.coastal.id, payerID: host, total: money(112.79))),
            ReceiptRoomEvent(sequence: 3, actorID: host, date: opened, revision: 3, kind: .opened(participants: participants)),
        ] + room.claims.enumerated().map { index, claim in
            ReceiptRoomEvent(sequence: 4 + index, actorID: claim.memberID, date: opened, revision: claim.revision,
                             kind: .claimed(claim.itemID, claim.mode))
        }
        return room
    }

    /// Realistic accepted methods. Sam has none, to demonstrate the "no method" state.
    static func sampleDestinations(createdAt: Date) -> [PaymentDestination] {
        var counter = 6000
        func destination(_ person: Person, _ provider: PaymentProviderKind, _ value: DestinationValue,
                         link: String? = nil, label: String? = nil, preferred: Bool = false) -> PaymentDestination {
            counter += 1
            return PaymentDestination(
                id: PaymentDestinationID(uuid(counter)), ownerID: person.id, provider: provider, label: label, value: value,
                link: link.flatMap(URL.init(string:)), isPreferred: preferred, createdAt: createdAt
            )
        }
        return [
            destination(.riley, .appleCash, .phone("+15305550142"), preferred: true),
            destination(.riley, .paypal, .username("rileypark")),
            destination(.riley, .venmo, .username("riley-park")),
            destination(.maya, .appleCash, .phone("+15305554821"), preferred: true),
            destination(.maya, .paypal, .username("mayachen")),
            destination(.maya, .cashApp, .username("MayaC"), link: "https://cash.app/$MayaC"),
            destination(.maya, .zelle, .email("maya.chen@ucdavis.edu")),
            destination(.alexMorgan, .venmo, .username("alex-morgan"), preferred: true),
            destination(.alexMorgan, .zelle, .phone("+14155550199")),
            destination(.jordan, .cashApp, .username("JBrooks"), preferred: true),
            destination(.priya, .zelle, .email("priya.n@example.com"), preferred: true),
            destination(.dev, .venmo, .username("dev-kapoor"), preferred: true),
            destination(.lena, .paypal, .username("lenafischer"), preferred: true),
            destination(.alexRivera, .cash, .instructions("Cash when we meet up"), preferred: true),
            // Appended last so the earlier destination identifiers stay stable.
            destination(.dev, .other, .instructions("Leave cash in the jar on the beach house counter"), label: "Trip jar"),
        ]
    }

    /// A brand-new person with no groups.
    static func newUser() -> LedgerSnapshot {
        LedgerSnapshot(
            currentUserID: Person.riley.id,
            members: [Person.riley.member(longNames: false)],
            groups: [],
            expenses: [],
            settlements: []
        )
    }

    /// A personal group with many members (layout and avatar-stack fixture).
    static func largeGroup(referenceDate: Date) -> LedgerSnapshot {
        let names = ["Riley Park", "Maya Chen", "Alex Morgan", "Jordan Brooks", "Priya Natarajan", "Sam Okafor",
                     "Alex Rivera", "Dev Kapoor", "Lena Fischer", "Noah Kim", "Ava Thompson", "Mateo García",
                     "Zoe Williams", "Omar Haddad", "Hana Suzuki", "Liam O'Brien", "Isla Novak", "Kofi Mensah"]
        let members = names.enumerated().map { Member(id: MemberID(uuid(3000 + $0.offset)), displayName: $0.element) }
        let group = ExpenseGroup(
            id: GroupID(uuid(3100)), name: "Spring Break Road Trip", symbolName: "car.fill",
            memberships: members.map { Membership(memberID: $0.id) }, createdAt: referenceDate.addingTimeInterval(-86_400 * 10)
        )
        let total = Money(1834.17, .usd)
        let split = (try? SplitCalculator.equal(total, among: members.map(\.id)))?.shares ?? []
        let expense = Expense(
            id: ExpenseID(uuid(3200)), groupID: group.id, title: "Beach house", merchant: "Airbnb",
            date: referenceDate.addingTimeInterval(-86_400 * 2), total: total, category: .travel,
            splitMethod: .equal, payments: [Share(members[1].id, total)], allocations: split,
            createdBy: members[1].id
        )
        return LedgerSnapshot(currentUserID: members[0].id, members: members, groups: [group], expenses: [expense], settlements: [])
    }
}
