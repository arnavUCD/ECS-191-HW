import UIKit

/// Asks the system for a little more time when the app moves to the background mid-task, so a
/// receipt being processed can finish and save (milestone 5 §"Processing interface"). If time
/// runs out the task is simply cancelled; the draft was saved before processing started.
@MainActor
final class BackgroundActivity {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(_ name: String, onExpiration: @escaping @MainActor () -> Void) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated {
                onExpiration()
                self?.end()
            }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
