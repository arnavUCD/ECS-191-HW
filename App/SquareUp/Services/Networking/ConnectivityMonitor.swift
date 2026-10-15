import Foundation
import Network
import Observation

/// Connectivity awareness for honest UI copy ("Offline · saved on this iPhone").
///
/// Never used to block work: the prototype ledger is local, and production sync will treat
/// the network as unreliable regardless of this flag (CLAUDE.md §6, Network).
@Observable
final class ConnectivityMonitor {
    enum Status: Equatable, Sendable {
        case unknown
        case online
        case offline
    }

    private(set) var status: Status = .unknown
    /// Set for previews, tests, and visual QA to force a state.
    @ObservationIgnored private let forcedStatus: Status?
    @ObservationIgnored private var monitor: NWPathMonitor?

    init(forcedStatus: Status? = nil) {
        self.forcedStatus = forcedStatus
        if let forcedStatus {
            status = forcedStatus
        }
    }

    var isOffline: Bool { status == .offline }

    func start() {
        guard forcedStatus == nil, monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let status: Status = path.status == .satisfied ? .online : .offline
            Task { @MainActor in
                self?.status = status
            }
        }
        monitor.start(queue: DispatchQueue(label: "SquareUp.Connectivity", qos: .utility))
        self.monitor = monitor
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
    }
}
