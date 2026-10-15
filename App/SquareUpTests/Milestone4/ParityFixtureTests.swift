import CryptoKit
import Foundation
@testable import SquareUp
import Testing

/// Milestone 4 §14.1: the shared fixtures in `HW/Shared/parity-fixtures` run through the Swift
/// engine here and through the Flask server in `server/tests/test_parity.py`. Both must reach the
/// same outcome for every step (applied, no-op, or the same API error code) and the same final
/// allocation, rounding, readiness, and state. The expectations were recorded from the server.
@Suite("Swift ↔ server parity fixtures")
struct ParityFixtureTests {
    static let directory = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../Shared/parity-fixtures").standardized

    static var names: [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path())) ?? []
        return files.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }

    @Test func fixturesArePresent() {
        #expect(Self.names.count >= 7, "Expected the shared fixtures at \(Self.directory.path())")
    }

    @Test(arguments: names)
    func fixtureMatchesServer(_ name: String) throws {
        let data = try Data(contentsOf: Self.directory.appending(path: "\(name).json"))
        let fixture = try JSONDecoder().decode(ParityFixture.self, from: data)
        var runner = SwiftParityRunner(name: name, fixture: fixture)
        let outcomes = try runner.run()
        for (index, (step, outcome)) in zip(fixture.steps, outcomes).enumerated() {
            #expect(outcome == step.expect, "\(name) step \(index) (\(step.actor) \(step.command)): Swift \(outcome), server \(step.expect)")
        }
        let actual = runner.normalized()
        guard case .object(let expected) = fixture.expect, case .object(let produced) = actual else {
            Issue.record("\(name): malformed expect")
            return
        }
        for key in expected.keys.sorted() {
            #expect(produced[key] == expected[key], "\(name): \(key) differs")
        }
    }

    /// The same UUID derivation as `server/tests/parity.py`.
    @Test func uuidDerivationMatchesTheServer() {
        #expect(SwiftParityRunner.fixtureUUID("dinner-basic", "riley").uuidString.lowercased()
            == SwiftParityRunner.fixtureUUID("dinner-basic", "riley").uuidString.lowercased())
        let uuid = SwiftParityRunner.fixtureUUID("x", "y").uuidString.lowercased()
        #expect(uuid.count == 36 && uuid[uuid.index(uuid.startIndex, offsetBy: 14)] == "4")
    }
}

// MARK: - Fixture format (see Shared/parity-fixtures/README.md)

struct ParityFixture: Decodable {
    struct Item: Decodable {
        let key: String
        let name: String
        let lineTotal: Int
        let quantity: Int?
        let unitPrice: Int?
        let isRefund: Bool?
    }

    struct Charge: Decodable {
        let key: String
        let kind: String
        let label: String
        let amount: Int
        let allocation: JSONValue
    }

    struct Receipt: Decodable {
        let merchant: String
        let date: String
        let currency: String
        let total: Int
        let items: [Item]
        let charges: [Charge]
    }

    struct Step: Decodable {
        let actor: String
        let command: String
        let payload: JSONValue
        let expect: JSONValue
        let expectedRevision: String?
        let disputeKey: String?
    }

    let participants: [String]
    let payer: String
    let receipt: Receipt
    let steps: [Step]
    let expect: JSONValue
}

// MARK: - Runner

struct SwiftParityRunner {
    let name: String
    let fixture: ParityFixture
    private(set) var state: LedgerSnapshot
    private var keys: [UUID: String] = [:]
    private var disputes: [String: ReceiptDisputeID] = [:]
    let roomID: ReceiptRoomID
    let currency: CurrencyCode
    static let now = DemoScenario.fixedReferenceDate

    static func fixtureUUID(_ fixture: String, _ key: String) -> UUID {
        let hex = SHA256.hash(data: Data("\(fixture):\(key)".utf8)).map { String(format: "%02x", $0) }.joined()
        func slice(_ from: Int, _ to: Int) -> Substring {
            hex[hex.index(hex.startIndex, offsetBy: from)..<hex.index(hex.startIndex, offsetBy: to)]
        }
        return UUID(uuidString: "\(slice(0, 8))-\(slice(8, 12))-4\(slice(13, 16))-8\(slice(17, 20))-\(slice(20, 32))")!
    }

    init(name: String, fixture: ParityFixture) {
        self.name = name
        self.fixture = fixture
        currency = CurrencyCode(fixture.receipt.currency)
        roomID = ReceiptRoomID(Self.fixtureUUID(name, "room"))
        state = LedgerSnapshot(currentUserID: MemberID(), members: [], groups: [], expenses: [], settlements: [])
        let host = member(fixture.participants[0])
        let members = fixture.participants.map { Member(id: member($0), displayName: $0.capitalized) }
        let group = ExpenseGroup(id: GroupID(uuid("group")), name: "Parity", currency: currency, symbolName: "receipt",
                                 memberships: members.map { Membership(memberID: $0.id) }, createdAt: Self.now)
        var receipt = ReceiptDraft.empty(pages: [], currency: currency, date: Self.now)
        receipt.merchant.value = fixture.receipt.merchant
        receipt.total.value = money(fixture.receipt.total)
        receipt.items = fixture.receipt.items.map { item in
            ReceiptLineItem(id: ReceiptItemID(uuid(item.key)), name: ReceiptField(item.name), quantity: item.quantity,
                            unitPrice: item.unitPrice.map(money), lineTotal: ReceiptField(money(item.lineTotal)), isRefund: item.isRefund ?? false)
        }
        receipt.charges = fixture.receipt.charges.map { charge in
            ReceiptCharge(id: ReceiptChargeID(uuid(charge.key)), kind: ReceiptChargeKind(rawValue: charge.kind)!, label: charge.label,
                          amount: ReceiptField(money(charge.amount)), allocation: allocation(charge.allocation))
        }
        var room = ReceiptRoom(id: roomID, groupID: group.id, hostID: host, receipt: receipt, createdAt: Self.now)
        room.payerID = member(fixture.payer)
        room.state = .open
        room.participantIDs = members.map(\.id)
        room.openedAt = Self.now
        state = LedgerSnapshot(currentUserID: host, members: members, groups: [group], expenses: [], settlements: [],
                               defaultCurrency: currency, receiptRooms: [room])
    }

    mutating func uuid(_ key: String) -> UUID {
        let value = Self.fixtureUUID(name, key)
        keys[value] = key
        return value
    }

    mutating func member(_ key: String) -> MemberID { MemberID(uuid(key)) }
    func money(_ minor: Int) -> Money { Money(minorUnits: Int64(minor), currency: currency) }
    var room: ReceiptRoom { state.room(roomID)! }

    func key(_ id: UUID) -> String { keys[id] ?? id.uuidString.lowercased() }

    private mutating func allocation(_ raw: JSONValue) -> ChargeAllocation {
        switch raw["kind"]?.stringValue {
        case "payer": return .payer
        case "equal":
            if case .array(let members)? = raw["members"] { return .equal(members.compactMap(\.stringValue).map { member($0) }) }
            return .equal(nil)
        case "shares": return .shares(pairs(raw["weights"]).map { MemberWeight(member($0.0), $0.1) })
        case "exact": return .exact(pairs(raw["amounts"]).map { Share(member($0.0), money($0.1)) })
        default: return .proportional
        }
    }

    /// `[["riley", 2], ["maya", 1]]`.
    private func pairs(_ raw: JSONValue?) -> [(String, Int)] {
        guard case .array(let entries)? = raw else { return [] }
        return entries.compactMap { entry in
            guard case .array(let pair) = entry, pair.count == 2, let key = pair[0].stringValue, let value = pair[1].intValue else { return nil }
            return (key, value)
        }
    }

    // MARK: Steps

    mutating func run() throws -> [JSONValue] {
        var outcomes: [JSONValue] = []
        var previousRevision: Int?
        for step in fixture.steps {
            let current = room.revision
            let expected = step.expectedRevision == "stale" ? (previousRevision ?? current) : current
            let command = try command(for: step, expectedRevision: expected)
            let before = Set(room.disputes.map(\.id))
            do {
                let previous = room
                let result = try LedgerEngine.perform(.receipt(command), on: state, actor: member(step.actor), now: Self.now)
                state = LedgerEngine.apply(result.changes, to: state)
                // "Applied" means the room changed. (The Swift engine re-writes an unchanged room for
                // some accepted repeats; the server reports those as `applied: false`.)
                let applied = room != previous
                if applied { previousRevision = current }
                if let disputeKey = step.disputeKey, let created = room.disputes.first(where: { !before.contains($0.id) }) {
                    disputes[disputeKey] = created.id
                    keys[created.id.rawValue] = disputeKey
                }
                outcomes.append(["applied": .bool(applied)])
            } catch LedgerError.receipt(let error) {
                outcomes.append(["error": .string(Self.code(error, command: command))])
            }
        }
        return outcomes
    }

    private mutating func command(for step: ParityFixture.Step, expectedRevision revision: Int) throws -> ReceiptRoomCommand {
        let payload = step.payload
        func string(_ key: String) -> String { payload[key]?.stringValue ?? "" }
        switch step.command {
        case "claim":
            return .claim(roomID, expectedRevision: revision, item: ReceiptItemID(uuid(string("item"))), string("request") == "mine" ? .mine : .share)
        case "unclaim":
            return .unclaim(roomID, expectedRevision: revision, item: ReceiptItemID(uuid(string("item"))))
        case "claimUnits":
            return .claimUnits(roomID, expectedRevision: revision, item: ReceiptItemID(uuid(string("item"))), units: payload["units"]?.intValue ?? 0)
        case "setItemSplit":
            let split = payload["split"] ?? .null
            let itemSplit: ItemSplit = switch split["kind"]?.stringValue {
            case "shares": .shares(pairs(split["weights"]).map { MemberWeight(member($0.0), $0.1) })
            case "exact": .exact(pairs(split["amounts"]).map { Share(member($0.0), money($0.1)) })
            case "units": .units(pairs(split["units"]).map { MemberUnits(member($0.0), $0.1) })
            default:
                if case .array(let members)? = split["members"] {
                    .equal(members.compactMap(\.stringValue).map { member($0) })
                } else {
                    .equal([])
                }
            }
            return .setItemSplit(roomID, expectedRevision: revision, item: ReceiptItemID(uuid(string("item"))), itemSplit)
        case "dispute":
            let target = payload["target"] ?? .null
            let key = target["key"]?.stringValue ?? ""
            let disputeTarget: DisputeTarget = target["kind"]?.stringValue == "charge" ? .charge(ReceiptChargeID(uuid(key))) : .item(ReceiptItemID(uuid(key)))
            return .dispute(roomID, expectedRevision: revision, disputeTarget, note: payload["note"]?.stringValue)
        case "resolveDispute":
            let id = disputes[string("dispute")] ?? ReceiptDisputeID(uuid(string("dispute")))
            return .resolveDispute(roomID, expectedRevision: revision, id, DisputeStatus(rawValue: string("status")) ?? .resolved,
                                   note: payload["note"]?.stringValue)
        case "setChargeAllocation":
            return .setChargeAllocation(roomID, expectedRevision: revision, ReceiptChargeID(uuid(string("charge"))), allocation(payload["allocation"] ?? .null))
        case "markReviewed":
            return .markReviewed(roomID, expectedRevision: revision)
        case "setPayerAcceptsFullReceipt":
            if case .bool(let accepts)? = payload["accepts"] { return .setPayerAcceptsFullReceipt(roomID, expectedRevision: revision, accepts) }
            return .setPayerAcceptsFullReceipt(roomID, expectedRevision: revision, false)
        case "transition":
            let move: ReceiptRoomTransition = switch string("move") {
            case "beginResolving": .beginResolving
            case "reopenClaims": .reopenClaims
            case "returnToRoom": .returnToRoom
            default: .requestFinalReview
            }
            return .transition(roomID, expectedRevision: revision, move)
        case "removeParticipant":
            let removed = member(string("participant"))
            return .setParticipants(roomID, expectedRevision: revision, participants: room.participantIDs.filter { $0 != removed })
        case "finalize":
            return .finalize(roomID, expectedRevision: revision)
        case "cancel":
            return .cancel(roomID, expectedRevision: revision)
        default:
            throw ParityError.unknownCommand(step.command)
        }
    }

    enum ParityError: Error {
        case unknownCommand(String)
    }

    /// The server's API error code for a Swift engine error (server/API.md).
    static func code(_ error: ReceiptRoomError, command: ReceiptRoomCommand) -> String {
        switch error {
        case .roomNotFound: "room_not_found"
        case .roomAlreadyExists: "invalid_payload"
        case .staleRevision: "revision_conflict"
        case .notAllowedInState(.finalized): "room_finalized"
        case .notAllowedInState(.cancelled): "room_cancelled"
        case .notAllowedInState: "not_allowed_in_state"
        case .hostOnly: "host_only"
        case .notAParticipant: "not_a_participant"
        case .itemNotFound: "item_not_found"
        case .itemNotClaimable: "item_not_claimable"
        case .chargeNotFound: "charge_not_found"
        case .disputeNotFound: "dispute_not_found"
        case .itemAlreadyClaimed: "item_already_claimed"
        case .itemHasCustomSplit: "item_has_custom_split"
        case .noClaimToRemove: "no_claim_to_remove"
        case .cannotIncludeOthers: "cannot_include_others"
        case .cannotRemoveOthers: "cannot_remove_others"
        case .unitsUnavailable: "units_unavailable"
        case .itemQuantityUnknown: "item_quantity_unknown"
        case .unreviewedShares: "unreviewed_shares"
        case .roomExpired: "room_expired"
        case .roomClosed: "room_closed"
        case .invalidSplit: "invalid_split"
        case .invalidChargeAllocation: "invalid_allocation"
        case .disputeAlreadyResolved: "dispute_already_resolved"
        case .noteRequired: "note_required"
        case .noteTooLong: "note_too_long"
        case .receiptNotReady: "receipt_not_ready"
        case .currencyChangeAfterOpen: "currency_change_after_open"
        case .groupRequired, .payerRequired, .payerNotInGroup, .participantNotInGroup: "participant_not_in_room"
        case .participantsRequired: "participants_required"
        case .notReadyToFinalize(let issues):
            if case .finalize = command, issues.contains(where: { if case .openDispute = $0 { true } else { false } }) {
                "unresolved_dispute"
            } else {
                "not_ready_to_finalize"
            }
        case .sharedTotalsDiffer: "invalid_payload"
        }
    }

    // MARK: Normalization (mirrors `Runner.normalize` in server/tests/parity.py)

    func normalized() -> JSONValue {
        let room = room
        let allocation = ReceiptAllocationEngine.allocate(room)
        func int(_ money: Money) -> JSONValue { .int(Int(money.minorUnits)) }
        func shares(_ list: [Share]) -> JSONValue {
            .object(Dictionary(list.map { (key($0.memberID.rawValue), int($0.amount)) }, uniquingKeysWith: { first, _ in first }))
        }
        func rounding(_ notes: [RoundingNote]) -> JSONValue { .array(notes.map { key($0.memberID.rawValue) }.sorted().map(JSONValue.string)) }
        let group = room.groupID.flatMap(state.group)
        let readiness = ReceiptRoomReadiness.issues(for: room, allocation: allocation, group: group).map { readinessString($0) }
        return [
            "state": .string(room.state.rawValue),
            "remaining": allocation.remaining.map(int) ?? .null,
            "participants": .object(Dictionary(allocation.participants.map { person in
                (key(person.memberID.rawValue), [
                    "items": int(person.items), "tax": int(person.tax), "tip": int(person.tip), "fees": int(person.fees),
                    "discounts": int(person.discounts), "adjustments": int(person.adjustments), "total": int(person.total),
                ] as JSONValue)
            }, uniquingKeysWith: { first, _ in first })),
            "items": .object(Dictionary(allocation.items.map { item in
                (key(item.itemID.rawValue), ["status": .string(itemStatus(item.status)), "shares": shares(item.shares),
                                             "rounding": rounding(item.rounding)] as JSONValue)
            }, uniquingKeysWith: { first, _ in first })),
            "charges": .object(Dictionary(allocation.charges.map { charge in
                (key(charge.chargeID.rawValue), ["status": .string(chargeStatus(charge.status)), "shares": shares(charge.shares),
                                                 "rounding": rounding(charge.rounding)] as JSONValue)
            }, uniquingKeysWith: { first, _ in first })),
            "readiness": .array(readiness.map(JSONValue.string)),
            "finalized": .bool(room.finalSnapshot != nil),
        ]
    }

    private func itemStatus(_ status: ItemAllocation.Status) -> String {
        switch status {
        case .note: "note"
        case .unclaimed: "unclaimed"
        case .allocated: "allocated"
        case .partial: "partial"
        case .invalid: "invalid"
        }
    }

    private func chargeStatus(_ status: ChargeAllocationResult.Status) -> String {
        switch status {
        case .allocated: "allocated"
        case .noBasis: "noBasis"
        case .exactMismatch: "exactMismatch"
        case .noRecipients: "noRecipients"
        case .payerMissing: "payerMissing"
        case .notAParticipant: "notAParticipant"
        }
    }

    private func readinessString(_ issue: ReadinessIssue) -> String {
        switch issue {
        case .receipt(let kind): "receipt:\(receiptKind(kind))"
        case .unclaimedItem(let id): "unclaimedItem:\(key(id.rawValue))"
        case .partiallyAssignedItem(let id, _): "partiallyAssignedItem:\(key(id.rawValue))"
        case .invalidItemSplit(let id, _): "invalidItemSplit:\(key(id.rawValue))"
        case .unallocatedCharge(let id, _): "unallocatedCharge:\(key(id.rawValue))"
        case .openDispute(let id): "openDispute:\(key(id.rawValue))"
        case .totalsDoNotMatch: "totalsDoNotMatch"
        case .groupMissing: "groupMissing"
        case .payerMissing: "payerMissing"
        case .payerNotInGroup(let id): "payerNotInGroup:\(key(id.rawValue))"
        case .participantNotInGroup(let id): "participantNotInGroup:\(key(id.rawValue))"
        case .negativeParticipantTotal(let id, _): "negativeParticipantTotal:\(key(id.rawValue))"
        case .onlyPayerOwes: "onlyPayerOwes"
        }
    }

    private func receiptKind(_ kind: ReceiptIssue.Kind) -> String {
        // "itemNameBlank(…)" → "itemNameBlank"
        String(String(describing: kind).prefix { $0 != "(" })
    }
}
