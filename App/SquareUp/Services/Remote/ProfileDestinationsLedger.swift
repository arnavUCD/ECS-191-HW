import Foundation
import Observation

/// The signed-in person's own payment methods, kept on their server profile (milestone 7 §3.1,
/// §10.1), presented through the `LedgerStore` interface so "How friends pay you" works unchanged.
///
/// Changes go to the server (which validates them again) and are never applied locally first.
/// Shared groups read these methods from the profile; local groups keep their own on this iPhone.
@Observable
final class ProfileDestinationsLedger: LedgerStore {
    private(set) var revision = 0
    @ObservationIgnored private let service: SharedGroupsService
    @ObservationIgnored private let now: () -> Date

    init(service: SharedGroupsService, now: @escaping () -> Date = { .now }) {
        self.service = service
        self.now = now
    }

    func snapshot() async throws -> LedgerSnapshot {
        guard let profile = service.profile, let me = MemberID(string: profile.memberId) else { throw LedgerError.currentUserMissing }
        return LedgerSnapshot(currentUserID: me, members: [Member(id: me, displayName: profile.displayName)], groups: [], expenses: [],
                              settlements: [], paymentDestinations: service.profileDestinations, defaultCurrency: CurrencyCode(profile.currency ?? "USD"))
    }

    @discardableResult
    func perform(_ command: LedgerCommand, as actor: MemberID?) async throws -> LedgerCommandResult {
        let snapshot = try await snapshot()
        // The same rules as on this iPhone first (owner, link allowlist, preference), then the server.
        let local = try LedgerEngine.perform(command, on: snapshot, actor: snapshot.currentUserID, now: now())
        switch command {
        case .saveDestination(let saved):
            // The server applies the same preference rules to the other methods itself.
            if let destination = local.changes.lazy.compactMap({ change -> PaymentDestination? in
                if case .upsertDestination(let destination) = change, destination.id == saved.id { destination } else { nil }
            }).first {
                try await service.saveDestination(destination)
            }
        case .deleteDestination(let id):
            try await service.deleteDestination(id)
        default:
            throw LedgerError.remote(.refused(String(localized: "That isn't available here.")))
        }
        revision += 1
        return local
    }

    func resetToSampleData(referenceDate: Date) async throws { throw LedgerError.unavailable }
    func eraseAll() async throws { throw LedgerError.unavailable }
}
