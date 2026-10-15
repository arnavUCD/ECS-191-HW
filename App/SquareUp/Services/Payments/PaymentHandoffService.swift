import Foundation
import MessageUI
import OSLog
import UIKit
import UniformTypeIdentifiers

/// The only code that touches the outside world during a payment handoff: opening allowlisted
/// links, checking Messages availability, and writing to the pasteboard.
///
/// Opening another app means only "handoff opened" — never "payment succeeded". In UI tests
/// (`-SUSimulateHandoffs`) nothing is opened; the result is reported as opened so the return
/// flow can be exercised without leaving the app or moving money.
final class PaymentHandoffService {
    private let simulatesHandoffs: Bool

    init(simulatesHandoffs: Bool = false) {
        self.simulatesHandoffs = simulatesHandoffs
    }

    /// Whether the system Messages composer can be shown on this device.
    var canComposeMessages: Bool {
        simulatesHandoffs || MFMessageComposeViewController.canSendText()
    }

    var isSimulating: Bool { simulatesHandoffs }

    /// Opens a link only if it passes the provider allowlist. Returns whether the system opened it.
    func open(_ url: URL, for provider: PaymentProviderKind) async -> Bool {
        guard ExternalURLPolicy.isAllowed(url, for: provider) else {
            Log.payments.error("Blocked a non-allowlisted handoff link for \(provider.rawValue, privacy: .public)")
            return false
        }
        if simulatesHandoffs {
            Log.payments.info("Simulated handoff for \(provider.rawValue, privacy: .public)")
            return true
        }
        let opened = await UIApplication.shared.open(url)
        // Provider and outcome only: never the URL, which can contain a username and amount.
        Log.payments.info("Handoff for \(provider.rawValue, privacy: .public) opened: \(opened, privacy: .public)")
        return opened
    }

    /// Copies text for the payer. Local to this device (no Universal Clipboard) and expires
    /// after two minutes so payment details don't linger.
    func copy(_ text: String) {
        UIPasteboard.general.setItems(
            [[UTType.plainText.identifier: text]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)]
        )
    }
}
