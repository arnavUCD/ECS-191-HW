import CoreHaptics
@testable import SquareUp
import Testing
import UIKit

/// Enforces the colour-token contract: every text-bearing token meets WCAG AA (4.5:1) against
/// every surface it is placed on, in light, dark, and both increased-contrast appearances.
@Suite("Colour contrast")
@MainActor
struct ContrastTests {
    static let textTokens: [(String, ColorResource)] = [
        ("textPrimary", .textPrimary), ("textSecondary", .textSecondary), ("textTertiary", .textTertiary),
        ("accent", .accentPrimary), ("violet", .accentViolet), ("positive", .positive),
        ("warning", .warning), ("negative", .negative), ("informational", .informational),
    ]
    static let surfaces: [(String, ColorResource)] = [
        ("backgroundPrimary", .backgroundPrimary), ("surfacePrimary", .surfacePrimary), ("surfaceElevated", .surfaceElevated),
    ]

    static let appearances: [(String, UITraitCollection)] = [
        ("light", UITraitCollection { $0.userInterfaceStyle = .light; $0.accessibilityContrast = .normal }),
        ("dark", UITraitCollection { $0.userInterfaceStyle = .dark; $0.accessibilityContrast = .normal }),
        ("light-high", UITraitCollection { $0.userInterfaceStyle = .light; $0.accessibilityContrast = .high }),
        ("dark-high", UITraitCollection { $0.userInterfaceStyle = .dark; $0.accessibilityContrast = .high }),
    ]

    static func luminance(_ color: UIColor) -> Double {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func channel(_ value: CGFloat) -> Double {
            let v = Double(value)
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    static func contrast(_ a: UIColor, _ b: UIColor) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    @Test("Text tokens meet 4.5:1 on every surface in every appearance")
    func textContrast() {
        for (appearance, traits) in Self.appearances {
            for (textName, text) in Self.textTokens {
                for (surfaceName, surface) in Self.surfaces {
                    let ratio = Self.contrast(
                        UIColor(resource: text).resolvedColor(with: traits),
                        UIColor(resource: surface).resolvedColor(with: traits)
                    )
                    #expect(ratio >= 4.5, "\(textName) on \(surfaceName) (\(appearance)) is \(String(format: "%.2f", ratio)):1")
                }
            }
        }
    }

    @Test("Labels on accent fills meet 4.5:1")
    func onAccent() {
        for (appearance, traits) in Self.appearances {
            let ratio = Self.contrast(
                UIColor(resource: .onAccent).resolvedColor(with: traits),
                UIColor(resource: .accentPrimary).resolvedColor(with: traits)
            )
            #expect(ratio >= 4.5, "onAccent (\(appearance)) is \(ratio):1")
        }
    }

    @Test("Avatar initials meet 4.5:1 on their fills")
    func avatars() {
        let pairs: [(ColorResource, ColorResource)] = [
            (.Avatar.fill1, .Avatar.ink1), (.Avatar.fill2, .Avatar.ink2), (.Avatar.fill3, .Avatar.ink3), (.Avatar.fill4, .Avatar.ink4),
            (.Avatar.fill5, .Avatar.ink5), (.Avatar.fill6, .Avatar.ink6), (.Avatar.fill7, .Avatar.ink7), (.Avatar.fill8, .Avatar.ink8),
        ]
        #expect(pairs.count == AvatarPalette.count)
        for (appearance, traits) in Self.appearances {
            for (fill, ink) in pairs {
                let ratio = Self.contrast(UIColor(resource: fill).resolvedColor(with: traits), UIColor(resource: ink).resolvedColor(with: traits))
                #expect(ratio >= 4.5, "Avatar pair (\(appearance)) is \(ratio):1")
            }
        }
    }
}

@Suite("Signature haptics")
struct HapticPatternTests {
    @Test("Every signature pattern is valid Core Haptics input", arguments: SignatureHaptic.allCases)
    func validPattern(haptic: SignatureHaptic) throws {
        _ = try HapticsService.pattern(for: haptic)
        #expect(haptic.duration < 1, "Signature haptics are brief")
        for event in haptic.events {
            #expect((0...1).contains(event.intensity))
            #expect((0...1).contains(event.sharpness))
        }
    }

    @Test("Settling is the strongest moment in the app")
    func settleIsStrongest() {
        let peak = { (haptic: SignatureHaptic) in haptic.events.map(\.intensity).max() ?? 0 }
        #expect(SignatureHaptic.allCases.allSatisfy { peak($0) <= peak(.settle) })
    }

    @Test("The in-app preference disables signature haptics")
    @MainActor
    func preference() {
        let defaults = UserDefaults(suiteName: "HapticPatternTests-\(UUID().uuidString)")!
        let service = HapticsService(defaults: defaults)
        #expect(service.isEnabled)
        defaults.set(false, forKey: HapticsService.preferenceKey)
        #expect(!service.isEnabled)
    }
}

@Suite("Motion vocabulary")
struct MotionTests {
    @Test("Reduce Motion collapses every motion to one cross-fade")
    @MainActor
    func reduceMotion() {
        let motions: [SUMotion] = [.press, .reveal, .transfer, .confirm, .attention, .reconcile]
        for motion in motions {
            #expect(motion.resolved(reduceMotion: true) == SUMotion.reducedMotionFallback)
        }
    }
}
