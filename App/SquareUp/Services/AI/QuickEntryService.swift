import Foundation
import OSLog

/// Chooses a quick-entry provider at runtime and always falls back to deterministic rules.
///
/// Selection order (CLAUDE.md §6.2):
/// 1. On-device Foundation Models, if available and the person allows it.
/// 2. Private Cloud Compute — not enabled (entitlement and privacy review pending).
/// 3. Server pipeline — not enabled until the Flask/OpenAI server exists.
/// 4. Rule-based parser — always available.
final class QuickEntryService {
    static let onDevicePreferenceKey = "allowOnDeviceAI"

    private let onDevice: any QuickEntryProviding
    private let fallback: any QuickEntryProviding
    private let defaults: UserDefaults

    init(
        onDevice: any QuickEntryProviding = FoundationModelsQuickEntryProvider(),
        fallback: any QuickEntryProviding = RuleBasedQuickEntryProvider(),
        defaults: UserDefaults = .standard
    ) {
        self.onDevice = onDevice
        self.fallback = fallback
        self.defaults = defaults
    }

    var allowsOnDeviceAI: Bool {
        defaults.object(forKey: Self.onDevicePreferenceKey) == nil ? true : defaults.bool(forKey: Self.onDevicePreferenceKey)
    }

    /// The provider that would be used right now, for disclosure before the person submits.
    func activeProvider() async -> AIProviderDescriptor {
        if allowsOnDeviceAI, await onDevice.availability().isAvailable {
            return onDevice.descriptor
        }
        return fallback.descriptor
    }

    func onDeviceAvailability() async -> AIAvailability {
        await onDevice.availability()
    }

    func suggest(
        from text: String,
        members: [Member],
        currentUserID: MemberID,
        currency: CurrencyCode
    ) async -> QuickEntrySuggestion {
        let context = QuickEntryContext(
            memberNames: members.map(\.displayName),
            currentUserName: members.first { $0.id == currentUserID }?.displayName ?? "",
            currency: currency
        )
        let clock = ContinuousClock()
        let start = clock.now

        var providers: [any QuickEntryProviding] = []
        if allowsOnDeviceAI, await onDevice.availability().isAvailable { providers.append(onDevice) }
        providers.append(fallback)

        for provider in providers {
            do {
                try Task.checkCancellation()
                let candidate = try await provider.candidate(for: text, context: context)
                let suggestion = QuickEntryResolver.resolve(
                    candidate, members: members, currentUserID: currentUserID,
                    currency: currency, provider: provider.descriptor
                )
                let elapsed = clock.now - start
                // Provider, timing, and warning count only — never the text or extracted values.
                Log.ai.info("""
                Quick entry via \(provider.descriptor.id, privacy: .public) \
                in \(elapsed.components.seconds, privacy: .public)s; \
                warnings: \(suggestion.warnings.count, privacy: .public)
                """)
                return suggestion
            } catch is CancellationError {
                break
            } catch {
                Log.ai.error("Provider \(provider.descriptor.id, privacy: .public) failed: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
        return QuickEntryResolver.resolve(
            RuleBasedQuickEntryProvider.parse(text), members: members, currentUserID: currentUserID,
            currency: currency, provider: fallback.descriptor
        )
    }
}
