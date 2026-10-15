import Foundation

/// A validated, editable suggestion. Nothing here is saved until the person confirms it.
nonisolated struct QuickEntrySuggestion: Equatable, Sendable {
    enum Warning: Equatable, Sendable {
        case amountMissing
        case amountInvalid(String)
        case amountPrecision
        case unknownPerson(String)
        case ambiguousPerson(String)
        case payerNotFound(String)
        case nonEqualSplitRequested
    }

    var amount: Money?
    var title: String?
    var payerID: MemberID?
    var participantIDs: [MemberID]
    var warnings: [Warning]
    let provider: AIProviderDescriptor

    var isUsable: Bool { amount != nil }
}

/// Turns untrusted provider strings into typed values, matching names only against the
/// selected group's members. Never guesses: ambiguous or unknown names become warnings.
nonisolated enum QuickEntryResolver {
    static let selfReferences: Set<String> = ["me", "i", "myself", "you", "self"]

    static func resolve(
        _ candidate: QuickEntryCandidate,
        members: [Member],
        currentUserID: MemberID,
        currency: CurrencyCode,
        provider: AIProviderDescriptor
    ) -> QuickEntrySuggestion {
        var warnings: [QuickEntrySuggestion.Warning] = []

        var amount: Money?
        if let text = candidate.amountText?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
            let cleaned = text.replacingOccurrences(of: ",", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "$€£₹ "))
            if let value = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")), value > 0 {
                if value.significantFractionDigits > currency.minorUnitDigits {
                    warnings.append(.amountPrecision)
                }
                amount = Money(value, currency)
            } else {
                warnings.append(.amountInvalid(text))
            }
        } else {
            warnings.append(.amountMissing)
        }

        var payerID: MemberID? = currentUserID
        if let payerName = candidate.payerName?.trimmingCharacters(in: .whitespaces), !payerName.isEmpty {
            switch match(payerName, members: members, currentUserID: currentUserID) {
            case .matched(let id): payerID = id
            case .ambiguous: payerID = nil; warnings.append(.ambiguousPerson(payerName))
            case .unknown: payerID = nil; warnings.append(.payerNotFound(payerName))
            }
        }

        var participants: [MemberID] = []
        for name in candidate.participantNames {
            switch match(name, members: members, currentUserID: currentUserID) {
            case .matched(let id):
                if !participants.contains(id) { participants.append(id) }
            case .ambiguous:
                warnings.append(.ambiguousPerson(name))
            case .unknown:
                warnings.append(.unknownPerson(name))
            }
        }
        if !candidate.splitsEqually { warnings.append(.nonEqualSplitRequested) }

        let title = candidate.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        return QuickEntrySuggestion(
            amount: amount,
            title: (title?.isEmpty ?? true) ? nil : String(title!.prefix(80)),
            payerID: payerID,
            participantIDs: participants,
            warnings: warnings,
            provider: provider
        )
    }

    enum Match: Equatable {
        case matched(MemberID)
        case ambiguous
        case unknown
    }

    static func match(_ rawName: String, members: [Member], currentUserID: MemberID) -> Match {
        let name = normalize(rawName)
        guard !name.isEmpty else { return .unknown }
        if selfReferences.contains(name) { return .matched(currentUserID) }

        let fullMatches = members.filter { normalize($0.displayName) == name }
        if fullMatches.count == 1 { return .matched(fullMatches[0].id) }
        if fullMatches.count > 1 { return .ambiguous }

        let handleMatches = members.filter { $0.handle.map(normalize) == name.trimmingCharacters(in: CharacterSet(charactersIn: "@")) }
        if handleMatches.count == 1 { return .matched(handleMatches[0].id) }

        let firstMatches = members.filter { normalize($0.firstName) == name }
        if firstMatches.count == 1 { return .matched(firstMatches[0].id) }
        if firstMatches.count > 1 { return .ambiguous }

        guard name.count >= 3 else { return .unknown }
        let prefixMatches = members.filter { normalize($0.displayName).hasPrefix(name) }
        if prefixMatches.count == 1 { return .matched(prefixMatches[0].id) }
        return prefixMatches.isEmpty ? .unknown : .ambiguous
    }

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }
}
