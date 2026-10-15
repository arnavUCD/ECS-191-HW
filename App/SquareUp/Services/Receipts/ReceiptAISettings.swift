import Foundation
import Observation

/// The person's choice about AI receipt processing (milestone 5 §7).
nonisolated enum ReceiptAIMode: String, Sendable, CaseIterable {
    /// Not asked yet: the disclosure appears before the first receipt that could be sent.
    case undecided
    /// Receipts are processed with AI automatically when available.
    case automatic
    /// Receipts never leave this iPhone for processing.
    case onDeviceOnly
}

/// Stored in `UserDefaults` (a preference, not a secret) and reversible in Profile. Agreeing is
/// tied to the disclosure's version: if what is sent changes, the version changes and the person
/// is asked again. Choosing on-device only is never asked about again.
@Observable
final class ReceiptAISettings {
    static let consentVersion = 1
    static let storageKey = "receipts.aiProcessing"

    private(set) var mode: ReceiptAIMode
    @ObservationIgnored private let defaults: UserDefaults?

    /// `defaults: nil` keeps the choice in memory only (previews and tests).
    init(defaults: UserDefaults? = .standard, initial: ReceiptAIMode = .undecided) {
        self.defaults = defaults
        mode = defaults.map { Self.decode($0.string(forKey: Self.storageKey)) } ?? initial
    }

    func choose(_ mode: ReceiptAIMode) {
        self.mode = mode
        switch mode {
        case .undecided: defaults?.removeObject(forKey: Self.storageKey)
        case .automatic: defaults?.set("automatic.v\(Self.consentVersion)", forKey: Self.storageKey)
        case .onDeviceOnly: defaults?.set("onDeviceOnly", forKey: Self.storageKey)
        }
    }

    static func decode(_ stored: String?) -> ReceiptAIMode {
        switch stored {
        case "onDeviceOnly": .onDeviceOnly
        case "automatic.v\(consentVersion)": .automatic
        default: .undecided // nothing stored, or agreement to an older disclosure
        }
    }
}
