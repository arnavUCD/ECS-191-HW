import Foundation
import Observation

/// Home's state machine. Owns no financial logic — it asks the repository for a snapshot and
/// `HomeSummaryBuilder` for the numbers.
@Observable
final class HomeModel {
    enum Phase: Equatable {
        case loading
        case loaded(HomeSummary)
        case failed(LedgerError)
    }

    private(set) var phase: Phase = .loading
    private(set) var isRefreshing = false
    /// A refresh failed while older content is still on screen. Content is kept, not blanked.
    private(set) var refreshError: LedgerError?
    private(set) var lastUpdated: Date?

    private let ledger: any LedgerReading
    private let now: () -> Date
    /// Milestone 7: the workspaces of the account's shared groups (each with its own "you").
    private let sharedSnapshots: () async -> [LedgerSnapshot]

    init(ledger: any LedgerReading, now: @escaping () -> Date, sharedSnapshots: @escaping () async -> [LedgerSnapshot] = { [] }) {
        self.ledger = ledger
        self.now = now
        self.sharedSnapshots = sharedSnapshots
    }

    var summary: HomeSummary? {
        if case .loaded(let summary) = phase { return summary }
        return nil
    }

    func load() async {
        let hasContent = summary != nil
        if hasContent { isRefreshing = true }
        defer { isRefreshing = false }
        do {
            let snapshot = try await ledger.snapshot()
            try Task.checkCancellation()
            guard let local = HomeSummaryBuilder.build(from: snapshot) else {
                throw LedgerError.currentUserMissing
            }
            let shared = await sharedSnapshots().compactMap(HomeSummaryBuilder.build(from:))
            try Task.checkCancellation()
            phase = .loaded(shared.isEmpty ? local : HomeSummaryBuilder.merging(local, with: shared))
            refreshError = nil
            lastUpdated = now()
        } catch is CancellationError {
            return
        } catch {
            let ledgerError = error as? LedgerError ?? .unavailable
            if hasContent {
                refreshError = ledgerError
            } else {
                phase = .failed(ledgerError)
            }
        }
    }

    func greeting(calendar: Calendar = .autoupdatingCurrent) -> String {
        switch calendar.component(.hour, from: now()) {
        case 5..<12: String(localized: "Good morning")
        case 12..<17: String(localized: "Good afternoon")
        default: String(localized: "Good evening")
        }
    }
}
