import Foundation

/// Polling for a shared group (milestone 7 §7.3): quick while someone is looking at it or a payment
/// involving this person is waiting, slower otherwise, with backoff after failures. Split from
/// `SharedGroupLedger.swift` for size; same type, same rules.
extension SharedGroupLedger {
    /// A screen that shows live collaboration (group detail, a payment) asks for quick polling.
    func beginCollaborating() {
        collaborators += 1
        startPolling()
    }

    func endCollaborating() {
        collaborators = max(0, collaborators - 1)
        if collaborators == 0 { stopPolling() }
    }

    /// Starts polling with an immediate refresh (also used on returning to the foreground).
    func startPolling() {
        guard pollTask == nil, syncState != .accessEnded else { return }
        pollTask = Task { [weak self] in await self?.pollLoop() }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    var isPolling: Bool { pollTask != nil }

    /// Quick while someone is collaborating or a payment involving this person is waiting.
    var currentPollInterval: Duration {
        let waiting = base?.attempts.contains { attempt in
            ["reportedSent", "disputed", "methodSelected", "handoffOpened"].contains(attempt.state)
                && [attempt.payerId, attempt.recipientId].contains(base?.viewer.memberId ?? "")
        } ?? false
        return collaborators > 0 || waiting ? fastPollInterval : slowPollInterval
    }

    private func pollLoop() async {
        var failures = 0
        var delay = Duration.zero
        while !Task.isCancelled {
            if delay > .zero {
                try? await Task.sleep(for: delay)
                if Task.isCancelled { break }
            }
            if inFlight > 0 {
                delay = currentPollInterval
                continue
            }
            do {
                try await refresh()
                failures = 0
                delay = currentPollInterval
            } catch LedgerError.remote(.removedFromGroup) {
                break
            } catch LedgerError.remote(.signInFailed) {
                break
            } catch {
                failures += 1
                delay = min(fastPollInterval * Int(pow(2.0, Double(min(failures, 5)))), maximumBackoff)
            }
        }
        pollTask = nil
    }
}
