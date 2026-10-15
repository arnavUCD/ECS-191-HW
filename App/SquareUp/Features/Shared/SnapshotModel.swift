import Foundation
import Observation

/// Shared loading state machine for screens that derive their content from a ledger snapshot.
///
/// - First load shows `.loading`; later refreshes keep the existing content (no blanking) and
///   surface failures through `refreshError`.
/// - The derivation closure is pure and testable; the view never computes figures.
@Observable
final class SnapshotModel<Value: Equatable> {
    enum Phase: Equatable {
        case loading
        case loaded(Value)
        case failed(LedgerError)
    }

    private(set) var phase: Phase = .loading
    private(set) var refreshError: LedgerError?
    private(set) var isRefreshing = false

    private let ledger: any LedgerReading
    private let derive: (LedgerSnapshot) throws -> Value

    init(ledger: any LedgerReading, derive: @escaping (LedgerSnapshot) throws -> Value) {
        self.ledger = ledger
        self.derive = derive
    }

    var value: Value? {
        if case .loaded(let value) = phase { return value }
        return nil
    }

    func load() async {
        let hasContent = value != nil
        if hasContent { isRefreshing = true }
        defer { isRefreshing = false }
        do {
            let snapshot = try await ledger.snapshot()
            try Task.checkCancellation()
            phase = .loaded(try derive(snapshot))
            refreshError = nil
        } catch is CancellationError {
            return
        } catch {
            let ledgerError = error as? LedgerError ?? .unavailable
            if hasContent { refreshError = ledgerError } else { phase = .failed(ledgerError) }
        }
    }
}
