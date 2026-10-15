import Foundation

/// The human-readable confirmation shown before saving (CLAUDE.md §11 "Show a final
/// human-readable sentence before saving").
nonisolated struct ExpenseSentence: Equatable, Sendable {
    /// "You paid $84.00 for Dinner."
    let headline: String
    /// "Split equally between you, Maya, and Alex — $28.00 each."
    let split: String
    /// "Maya and Alex will owe you $56.00."
    let effect: String
    /// "You and Maya pay 1¢ more so the total matches exactly."
    let roundingNote: String?

    static func make(
        title: String,
        total: Money,
        payments: [Share],
        shares: [Share],
        method: SplitMethod,
        roundingAdjustments: [MemberID: Money],
        currentUserID: MemberID,
        members: [Member],
        locale: Locale = .autoupdatingCurrent
    ) -> ExpenseSentence {
        let labels = PersonIdentity.shortLabels(for: members)
        let lookup = Dictionary(members.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func name(_ id: MemberID) -> String {
            id == currentUserID ? String(localized: "you") : (labels[id] ?? lookup[id]?.displayName ?? "")
        }
        func capitalizedName(_ id: MemberID) -> String {
            id == currentUserID ? String(localized: "You") : name(id)
        }
        let format = { (money: Money) in MoneyFormatting.string(money, locale: locale) }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)

        let payerIDs = payments.map(\.memberID)
        let payerList = payerIDs.enumerated().map { $0.offset == 0 ? capitalizedName($0.element) : name($0.element) }
            .formatted(.list(type: .and))
        let headline = String(localized: "\(payerList) paid \(format(total)) for \(trimmedTitle).")

        let participants = shares.filter { !$0.amount.isZero }
        let participantList = PersonIdentity.list(
            participants.compactMap { lookup[$0.memberID] }, currentUserID: currentUserID, maximumNames: 4
        )
        let split: String
        let amounts = Set(participants.map(\.amount))
        switch method {
        case .equal where amounts.count == 1:
            split = String(localized: "Split equally between \(participantList) — \(format(participants[0].amount)) each.")
        case .equal:
            split = String(localized: "Split equally between \(participantList).")
        case .exact:
            split = String(localized: "Split by exact amounts between \(participantList).")
        case .percentage:
            split = String(localized: "Split by percentage between \(participantList).")
        case .shares:
            split = String(localized: "Split by shares between \(participantList).")
        case .itemized:
            split = String(localized: "Split between \(participantList).")
        }

        let paidByMe = payments.filter { $0.memberID == currentUserID }.map(\.amount).sum(in: total.currency)
        let myShare = shares.first { $0.memberID == currentUserID }?.amount ?? .zero(total.currency)
        let personal = paidByMe - myShare
        let effect: String
        if personal.isPositive {
            if payerIDs.count > 1 {
                effect = String(localized: "Others will owe you \(format(personal)) in total.")
            } else {
                let debtors = participants.filter { $0.memberID != currentUserID }.compactMap { lookup[$0.memberID] }
                let list = PersonIdentity.list(debtors, currentUserID: nil, maximumNames: 3)
                effect = String(localized: "\(list) will owe you \(format(personal)).")
            }
        } else if personal.isNegative {
            effect = payerIDs.count == 1
                ? String(localized: "You'll owe \(name(payerIDs[0])) \(format(personal.magnitude)).")
                : String(localized: "You'll owe \(format(personal.magnitude)) in total.")
        } else if shares.contains(where: { $0.memberID == currentUserID }) || payerIDs.contains(currentUserID) {
            effect = String(localized: "This doesn't change what you owe.")
        } else {
            effect = String(localized: "You're not part of this expense.")
        }

        var roundingNote: String?
        if !roundingAdjustments.isEmpty, let unit = roundingAdjustments.values.first {
            let people = participants.map(\.memberID).filter { roundingAdjustments[$0] != nil }
            let list = people.map(capitalizedName).formatted(.list(type: .and))
            roundingNote = people.count == 1 && people.first != currentUserID
                ? String(localized: "\(list) pays \(format(unit)) more so the total matches exactly.")
                : String(localized: "\(list) pay \(format(unit)) more so the total matches exactly.")
        }

        return ExpenseSentence(headline: headline, split: split, effect: effect, roundingNote: roundingNote)
    }
}
