import Foundation

/// Named fixtures for previews, snapshot tests, UI tests, and visual QA launches
/// (CLAUDE.md §16 "Required preview matrix").
///
/// Launch the app with `-SUScenario <rawValue>` (DEBUG builds) to see any of these on a device
/// or simulator, e.g. `-SUScenario longNames`.
nonisolated enum DemoScenario: String, CaseIterable, Sendable {
    /// The seeded apartment, trip, and dinner groups as a person who is owed money overall.
    case standard
    /// No groups yet.
    case newUser
    /// A person who owes money overall.
    case owes
    /// One personal group with 18 members.
    case largeGroup
    /// Long member and group names.
    case longNames
    /// Amounts × 1,000.
    case largeAmounts
    /// Never finishes loading (skeleton state).
    case loading
    /// Storage error with retry.
    case failure
    /// Seeded data while the device reports no connectivity.
    case offline

    /// A fixed instant so previews and snapshots render identical relative dates.
    static let fixedReferenceDate = Date(timeIntervalSinceReferenceDate: 812_030_400) // 2026-09-25 12:00 UTC

    func snapshot(referenceDate: Date = DemoScenario.fixedReferenceDate) -> LedgerSnapshot? {
        switch self {
        case .standard, .loading, .offline:
            SampleLedger.make(referenceDate: referenceDate)
        case .newUser:
            SampleLedger.newUser()
        case .owes:
            SampleLedger.make(referenceDate: referenceDate, options: .init(currentUser: .alexRivera))
        case .largeGroup:
            SampleLedger.largeGroup(referenceDate: referenceDate)
        case .longNames:
            SampleLedger.make(referenceDate: referenceDate, options: .init(longNames: true))
        case .largeAmounts:
            SampleLedger.make(referenceDate: referenceDate, options: .init(amountMultiplier: 1000))
        case .failure:
            nil
        }
    }

    var failure: LedgerError? {
        self == .failure ? .storage("SimulatedFailure") : nil
    }

    var latency: Duration {
        self == .loading ? .seconds(3_600) : .zero
    }

    var connectivity: ConnectivityMonitor.Status? {
        self == .offline ? .offline : nil
    }
}
