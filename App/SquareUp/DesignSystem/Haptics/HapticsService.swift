import CoreHaptics
import OSLog
import SwiftUI

/// Signature tactile moments (CLAUDE.md §5.5). Ordinary selection, success, warning, and error
/// feedback uses SwiftUI's `sensoryFeedback`; Core Haptics is reserved for these.
///
/// Every signature haptic accompanies a visible state change — never replaces one.
nonisolated enum SignatureHaptic: String, CaseIterable, Sendable {
    /// A group becomes fully settled.
    case settle
    /// An item is claimed in the Live Receipt Room.
    case claim
    /// A receipt allocation reconciles exactly.
    case reconcile
}

/// A hardware-independent description of a haptic event, so patterns are unit-testable.
nonisolated struct HapticEventSpec: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case transient
        case continuous(duration: TimeInterval)
    }

    let kind: Kind
    let time: TimeInterval
    /// 0...1
    let intensity: Float
    /// 0...1
    let sharpness: Float
}

nonisolated extension SignatureHaptic {
    var events: [HapticEventSpec] {
        switch self {
        case .settle:
            // A soft swell resolving into two confident taps: "everyone is square".
            [
                .init(kind: .continuous(duration: 0.28), time: 0, intensity: 0.35, sharpness: 0.15),
                .init(kind: .transient, time: 0.30, intensity: 0.85, sharpness: 0.55),
                .init(kind: .transient, time: 0.44, intensity: 1.0, sharpness: 0.75),
            ]
        case .claim:
            [.init(kind: .transient, time: 0, intensity: 0.7, sharpness: 0.8)]
        case .reconcile:
            [
                .init(kind: .transient, time: 0, intensity: 0.5, sharpness: 0.4),
                .init(kind: .transient, time: 0.09, intensity: 0.8, sharpness: 0.6),
            ]
        }
    }

    var duration: TimeInterval {
        events.map { event in
            switch event.kind {
            case .transient: event.time
            case .continuous(let duration): event.time + duration
            }
        }.max() ?? 0
    }
}

/// Plays signature haptics through Core Haptics when the hardware supports it.
///
/// Respects the person's in-app preference (`isEnabled`) in addition to the system's own
/// haptics settings, which Core Haptics honours automatically.
final class HapticsService {
    static let preferenceKey = "signatureHapticsEnabled"

    private var engine: CHHapticEngine?
    private let supportsHaptics: Bool
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    }

    var isEnabled: Bool {
        defaults.object(forKey: Self.preferenceKey) == nil ? true : defaults.bool(forKey: Self.preferenceKey)
    }

    var isAvailable: Bool { supportsHaptics }

    func play(_ haptic: SignatureHaptic) {
        guard supportsHaptics, isEnabled else { return }
        do {
            let engine = try preparedEngine()
            let player = try engine.makePlayer(with: Self.pattern(for: haptic))
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            Log.haptics.error("Signature haptic failed: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    nonisolated static func pattern(for haptic: SignatureHaptic) throws -> CHHapticPattern {
        let events = haptic.events.map { spec in
            let parameters = [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: spec.intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: spec.sharpness),
            ]
            switch spec.kind {
            case .transient:
                return CHHapticEvent(eventType: .hapticTransient, parameters: parameters, relativeTime: spec.time)
            case .continuous(let duration):
                return CHHapticEvent(eventType: .hapticContinuous, parameters: parameters, relativeTime: spec.time, duration: duration)
            }
        }
        return try CHHapticPattern(events: events, parameters: [])
    }

    private func preparedEngine() throws -> CHHapticEngine {
        if let engine { return engine }
        let engine = try CHHapticEngine()
        engine.isAutoShutdownEnabled = true
        engine.resetHandler = { [weak engine] in
            try? engine?.start()
        }
        try engine.start()
        self.engine = engine
        return engine
    }
}
