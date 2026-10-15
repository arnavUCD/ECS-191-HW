import Foundation

/// A typed identifier. `Identifier<Member>` and `Identifier<Expense>` cannot be confused at
/// compile time even though both wrap a UUID.
nonisolated struct Identifier<Tag>: Hashable, Sendable, Codable, CustomStringConvertible {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    init?(string: String) {
        guard let uuid = UUID(uuidString: string) else { return nil }
        rawValue = uuid
    }

    init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var description: String { rawValue.uuidString }

    /// Stable, process-independent bucket for deterministic styling (e.g. avatar colour).
    /// `hashValue` is randomised per launch, so it must not be used for this.
    func stableBucket(count: Int) -> Int {
        precondition(count > 0)
        let bytes = withUnsafeBytes(of: rawValue.uuid) { Array($0) }
        let sum = bytes.reduce(0) { ($0 &* 31 &+ Int($1)) & 0x7FFF_FFFF }
        return sum % count
    }
}

typealias MemberID = Identifier<Member>
typealias GroupID = Identifier<ExpenseGroup>
typealias ExpenseID = Identifier<Expense>
typealias SettlementID = Identifier<Settlement>
typealias PaymentDestinationID = Identifier<PaymentDestination>
typealias PaymentAttemptID = Identifier<PaymentAttempt>
typealias AuditEventID = Identifier<AuditEvent>
