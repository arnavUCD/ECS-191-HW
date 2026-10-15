import Foundation
import Observation

/// Whether the entered split adds up, and if not, by how much.
nonisolated struct Reconciliation: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case balanced
        /// Money still to assign (exact amounts).
        case remaining(Money)
        /// Assigned more than the total (exact amounts).
        case over(Money)
        /// Percentage points still to assign.
        case percentRemaining(Decimal)
        /// Percentages over 100.
        case percentOver(Decimal)
        /// Not yet splittable, with a reason to show beside the input.
        case incomplete(Reason)
    }

    enum Reason: Equatable, Sendable {
        case noParticipants
        case noAmount
        case zeroShares
        case unreadableValue
    }

    let state: State
    var isBalanced: Bool { state == .balanced }
}

/// The staged Add Expense flow: amount → split → review.
///
/// All split math is delegated to `SplitCalculator`; this type only holds what the person
/// entered and reports whether it reconciles. Nothing is saved until `save` is called from the
/// review step, and the repository re-validates every invariant.
@Observable
final class ComposeExpenseModel {
    enum Step: Int, CaseIterable, Comparable {
        case amount, split, review
        static func < (lhs: Step, rhs: Step) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Fields last filled by an AI/parser suggestion and not yet edited by the person.
    enum SuggestedField: Hashable {
        case amount, title, payer, participants
    }

    enum SaveState: Equatable {
        case idle
        case saving
        case saved
        case failed(String)
    }

    // MARK: Inputs

    private(set) var snapshot: LedgerSnapshot?
    private(set) var loadError: LedgerError?
    var step: Step = .amount
    private(set) var entry = AmountEntry()
    var title = "" {
        didSet {
            guard title != oldValue else { return }
            suggestedFields.remove(.title)
            if !isCategoryExplicit { category = CategoryGuesser.guess(title) }
        }
    }

    private(set) var category: ExpenseCategory = .other
    private(set) var isCategoryExplicit = false
    private(set) var groupID: GroupID?
    private(set) var payerID: MemberID?
    /// Several people contributed to the paid amount (milestone 2 §8 "Multiple payers").
    private(set) var isMultiplePayers = false
    /// Each payer's contribution as typed, when `isMultiplePayers`.
    var payerAmountText: [MemberID: String] = [:]
    /// The saved expense being edited, if any. Edits start from these values.
    private(set) var original: Expense?
    private(set) var participantIDs: [MemberID] = []
    var method: SplitMethod = .equal
    var exactText: [MemberID: String] = [:]
    var percentText: [MemberID: String] = [:]
    var shareWeights: [MemberID: Int] = [:]
    private(set) var suggestion: QuickEntrySuggestion?
    private(set) var suggestedFields: Set<SuggestedField> = []
    private(set) var saveState: SaveState = .idle
    /// Increments on every rejected key so the view can play a warning haptic.
    private(set) var rejectionCount = 0
    private(set) var lastRejection: AmountEntry.Rejection?

    private let request: ComposerRequest
    let locale: Locale

    init(request: ComposerRequest, locale: Locale = .autoupdatingCurrent) {
        self.request = request
        self.locale = locale
    }

    // MARK: Loading

    func load(from ledger: any LedgerReading) async {
        do {
            await load(snapshot: try ledger.snapshot())
            loadError = nil
        } catch {
            loadError = error as? LedgerError ?? .unavailable
        }
    }

    /// Shared by the app, tests, and previews.
    func load(snapshot: LedgerSnapshot) {
        self.snapshot = snapshot
        if let id = request.editingExpenseID {
            guard let expense = snapshot.expense(id), !expense.isDeleted else {
                loadError = .rule(.expenseNotFound)
                return
            }
            prefill(from: expense)
            return
        }
        let preferred = request.groupID.flatMap { id in snapshot.groupsForCurrentUser.first { $0.id == id } }
        if let group = preferred ?? snapshot.groupsForCurrentUser.first {
            selectGroup(group.id)
        }
    }

    /// Edit starts from the saved values (milestone 2 §8). Equal splits stay equal; other
    /// methods reopen as their saved exact amounts, which reproduce the same split.
    private func prefill(from expense: Expense) {
        original = expense
        groupID = expense.groupID
        entry = AmountEntry(money: expense.total)
        title = expense.title
        category = expense.category
        isCategoryExplicit = true
        participantIDs = expense.allocations.map(\.memberID)
        if expense.payments.count == 1, let only = expense.payments.first {
            payerID = only.memberID
            isMultiplePayers = false
        } else {
            payerID = expense.payments.first?.memberID
            isMultiplePayers = true
            payerAmountText = Dictionary(uniqueKeysWithValues: expense.payments.map { ($0.memberID, editable($0.amount)) })
        }
        if expense.splitMethod == .equal {
            method = .equal
        } else {
            method = .exact
            exactText = Dictionary(uniqueKeysWithValues: expense.allocations.map { ($0.memberID, editable($0.amount)) })
        }
    }

    private func editable(_ money: Money) -> String {
        money.amount.formatted(.number.locale(locale).grouping(.never).precision(.fractionLength(money.currency.minorUnitDigits)))
    }

    var isEditing: Bool { original != nil }

    // MARK: Derived

    var currentUserID: MemberID? { snapshot?.currentUserID }
    var groups: [ExpenseGroup] { snapshot?.groupsForCurrentUser ?? [] }
    var group: ExpenseGroup? { groupID.flatMap { snapshot?.group($0) } }
    /// Active members, plus anyone already on the expense being edited (a removed member keeps
    /// their place on old expenses but can't be added to new ones).
    var members: [Member] {
        guard let group, let snapshot else { return [] }
        let grandfathered = Set(original?.participantIDs ?? [])
        return group.memberIDs
            .filter { group.isActiveMember($0) || grandfathered.contains($0) }
            .compactMap { snapshot.members[$0] }
    }

    var currency: CurrencyCode { group?.currency ?? .usd }
    var total: Money { entry.money }
    var payer: Member? { payerID.flatMap { snapshot?.members[$0] } }

    var hasChanges: Bool {
        if let original, let draft = try? buildExpense(now: original.date) {
            return ExpenseChangeSummary.make(from: original, to: draft).hasChanges
        }
        return !entry.isEmpty || !title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: Amount step

    func press(_ key: AmountEntry.Key) {
        if let rejection = entry.apply(key) {
            lastRejection = rejection
            rejectionCount += 1
        } else {
            lastRejection = nil
            suggestedFields.remove(.amount)
        }
    }

    func chooseCategory(_ category: ExpenseCategory) {
        self.category = category
        isCategoryExplicit = true
    }

    func selectGroup(_ id: GroupID) {
        guard let snapshot, let group = snapshot.group(id) else { return }
        let changedCurrency = group.currency != entry.currency
        groupID = id
        if changedCurrency {
            entry = entry.isEmpty ? AmountEntry(currency: group.currency) : AmountEntry(money: Money(entry.money.amount, group.currency))
        }
        let ids = group.activeMemberIDs
        payerID = ids.contains(snapshot.currentUserID) ? snapshot.currentUserID : ids.first
        participantIDs = ids
        exactText = [:]
        percentText = [:]
        shareWeights = [:]
        isMultiplePayers = false
        payerAmountText = [:]
    }

    /// Why the person cannot continue from the amount step, if anything.
    var amountStepIssue: String? {
        if group == nil { return String(localized: "Choose a group") }
        if !total.isPositive { return String(localized: "Enter an amount") }
        if trimmedTitle.isEmpty { return String(localized: "Add what it was for") }
        return nil
    }

    // MARK: Split step

    func setPayer(_ id: MemberID) {
        payerID = id
        suggestedFields.remove(.payer)
    }

    /// Switches between one payer and several explicit contributions.
    func setMultiplePayers(_ enabled: Bool) {
        guard enabled != isMultiplePayers else { return }
        isMultiplePayers = enabled
        suggestedFields.remove(.payer)
        if enabled, payerAmountText.isEmpty, let payerID {
            payerAmountText = [payerID: editable(total)]
        }
    }

    func parsedPayerAmount(_ id: MemberID) -> Money? {
        guard let text = payerAmountText[id], !text.isEmpty else { return nil }
        return MoneyFormatting.parse(text, currency: currency, locale: locale)
    }

    /// The payments as entered, or nil if a contribution can't be read.
    var payments: [Share]? {
        guard isMultiplePayers else { return payerID.map { [Share($0, total)] } }
        var shares: [Share] = []
        for member in members {
            let text = payerAmountText[member.id] ?? ""
            guard !text.isEmpty else { continue }
            guard let amount = parsedPayerAmount(member.id) else { return nil }
            if amount.isPositive { shares.append(Share(member.id, amount)) }
        }
        return shares
    }

    /// Whether payer contributions add up to the total.
    var payerReconciliation: Reconciliation {
        guard isMultiplePayers else {
            return Reconciliation(state: payerID == nil ? .incomplete(.noParticipants) : .balanced)
        }
        guard let payments else { return Reconciliation(state: .incomplete(.unreadableValue)) }
        guard !payments.isEmpty else { return Reconciliation(state: .incomplete(.noParticipants)) }
        let remaining = total - payments.map(\.amount).sum(in: currency)
        if remaining.isZero { return Reconciliation(state: .balanced) }
        return Reconciliation(state: remaining.isPositive ? .remaining(remaining) : .over(remaining.magnitude))
    }

    func toggleParticipant(_ id: MemberID) {
        if let index = participantIDs.firstIndex(of: id) {
            participantIDs.remove(at: index)
        } else {
            // Keep group order so lists and rounding are stable.
            let order = group?.memberIDs ?? []
            participantIDs.append(id)
            participantIDs.sort { (order.firstIndex(of: $0) ?? .max) < (order.firstIndex(of: $1) ?? .max) }
        }
        suggestedFields.remove(.participants)
    }

    func setAllParticipants(_ selected: Bool) {
        participantIDs = selected ? members.map(\.id) : []
        suggestedFields.remove(.participants)
    }

    func isParticipant(_ id: MemberID) -> Bool { participantIDs.contains(id) }

    func shareWeight(for id: MemberID) -> Int { shareWeights[id] ?? 1 }

    /// The split as currently entered, or why it cannot be computed.
    var splitOutcome: Result<SplitResult, SplitError> {
        let total = total
        do {
            switch method {
            case .equal, .itemized:
                return .success(try SplitCalculator.equal(total, among: participantIDs))
            case .exact:
                let amounts = participantIDs.map { ($0, parsedExact($0) ?? .zero(currency)) }
                return .success(try SplitCalculator.exact(total, amounts: amounts))
            case .percentage:
                let values = participantIDs.map { ($0, parsedPercent($0) ?? 0) }
                return .success(try SplitCalculator.percentage(total, percentages: values))
            case .shares:
                let weights = participantIDs.map { ($0, shareWeight(for: $0)) }
                return .success(try SplitCalculator.shares(total, weights: weights))
            }
        } catch let error as SplitError {
            return .failure(error)
        } catch {
            return .failure(.noParticipants)
        }
    }

    var reconciliation: Reconciliation {
        guard total.isPositive else { return Reconciliation(state: .incomplete(.noAmount)) }
        guard !participantIDs.isEmpty else { return Reconciliation(state: .incomplete(.noParticipants)) }
        switch method {
        case .exact:
            if participantIDs.contains(where: { !(exactText[$0] ?? "").isEmpty && parsedExact($0) == nil }) {
                return Reconciliation(state: .incomplete(.unreadableValue))
            }
            let assigned = participantIDs.compactMap(parsedExact).sum(in: currency)
            let remaining = total - assigned
            if remaining.isZero { return Reconciliation(state: .balanced) }
            return Reconciliation(state: remaining.isPositive ? .remaining(remaining) : .over(remaining.magnitude))
        case .percentage:
            if participantIDs.contains(where: { !(percentText[$0] ?? "").isEmpty && parsedPercent($0) == nil }) {
                return Reconciliation(state: .incomplete(.unreadableValue))
            }
            let assigned = participantIDs.compactMap(parsedPercent).reduce(0, +)
            let remaining = 100 - assigned
            if remaining == 0 { return Reconciliation(state: .balanced) }
            return Reconciliation(state: remaining > 0 ? .percentRemaining(remaining) : .percentOver(-remaining))
        case .shares:
            let totalWeight = participantIDs.map(shareWeight).reduce(0, +)
            return Reconciliation(state: totalWeight > 0 ? .balanced : .incomplete(.zeroShares))
        case .equal, .itemized:
            return Reconciliation(state: .balanced)
        }
    }

    /// Each selected person's computed share, for display beside their row.
    func computedShare(for id: MemberID) -> Money? {
        guard case .success(let result) = splitOutcome else { return nil }
        return result.shares.first { $0.memberID == id }?.amount
    }

    var canContinueFromSplit: Bool {
        payerReconciliation.isBalanced && reconciliation.isBalanced && (try? splitOutcome.get()) != nil
    }

    /// Fills each unassigned exact amount so the split reconciles: splits the remainder
    /// equally among people with no amount entered yet.
    func distributeRemainingExact() {
        let empty = participantIDs.filter { (exactText[$0] ?? "").isEmpty || parsedExact($0) == nil }
        guard case .remaining(let remaining) = reconciliation.state, !empty.isEmpty,
              let split = try? SplitCalculator.equal(remaining, among: empty) else { return }
        for share in split.shares {
            exactText[share.memberID] = share.amount.amount.formatted(
                .number.locale(locale).grouping(.never).precision(.fractionLength(currency.minorUnitDigits))
            )
        }
    }

    func parsedExact(_ id: MemberID) -> Money? {
        guard let text = exactText[id], !text.isEmpty else { return nil }
        return MoneyFormatting.parse(text, currency: currency, locale: locale)
    }

    func parsedPercent(_ id: MemberID) -> Decimal? {
        guard let text = percentText[id]?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        let normalized = text
            .replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: locale.decimalSeparator ?? ".", with: ".")
            .trimmingCharacters(in: .whitespaces)
        guard let value = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")), value >= 0 else { return nil }
        return value
    }

    // MARK: Review step

    var sentence: ExpenseSentence? {
        guard let payments, !payments.isEmpty, let currentUserID, case .success(let result) = splitOutcome else { return nil }
        return ExpenseSentence.make(
            title: trimmedTitle, total: total, payments: payments, shares: result.shares, method: method,
            roundingAdjustments: result.roundingAdjustments, currentUserID: currentUserID,
            members: members, locale: locale
        )
    }

    /// What this edit changes, shown before saving (milestone 2 §8 "Editing").
    var changeSummary: ExpenseChangeSummary? {
        guard let original, let draft = try? buildExpense(now: original.date) else { return nil }
        return ExpenseChangeSummary.make(from: original, to: draft)
    }

    func buildExpense(now: Date) throws -> Expense {
        guard let group, let currentUserID else { throw LedgerError.groupNotFound }
        guard let payments, payerReconciliation.isBalanced else { throw LedgerError.invalidExpense(.noPayer) }
        let result = try splitOutcome.get()
        var expense = Expense(
            id: original?.id ?? ExpenseID(),
            groupID: group.id,
            title: trimmedTitle,
            merchant: original?.merchant,
            date: original?.date ?? now,
            total: total,
            category: category,
            splitMethod: method,
            payments: payments,
            allocations: result.shares.filter { !$0.amount.isZero },
            note: original?.note,
            createdBy: original?.createdBy ?? currentUserID,
            createdAt: original?.createdAt ?? now
        )
        expense.splitInput = splitInput
        return expense
    }

    /// How the split was entered, so a shared group's server can recompute it exactly.
    var splitInput: SplitInput? {
        switch method {
        case .equal: .equal(participantIDs)
        case .shares: .shares(participantIDs.map { MemberWeight($0, shareWeight(for: $0)) })
        case .percentage: .percentage(participantIDs.map { MemberPercent($0, parsedPercent($0) ?? 0) })
        case .exact, .itemized: nil
        }
    }

    /// Saves through the repository, which re-validates every invariant. Edits save a new
    /// revision; the previous one stays in the audit log.
    @discardableResult
    func save(to repository: any ExpenseRepository, now: Date) async -> Bool {
        guard saveState != .saving, saveState != .saved else { return false }
        saveState = .saving
        do {
            let expense = try buildExpense(now: now)
            if isEditing {
                try await repository.update(expense)
            } else {
                try await repository.add(expense)
            }
            saveState = .saved
            return true
        } catch let error as LedgerError {
            saveState = .failed(Self.message(for: error))
        } catch {
            saveState = .failed(String(localized: "The split doesn't add up yet. Check the amounts and try again."))
        }
        return false
    }

    func resetSaveError() {
        if case .failed = saveState { saveState = .idle }
    }

    static func message(for error: LedgerError) -> String {
        LedgerErrorMessages.text(for: error)
    }

    // MARK: Suggestions

    /// Applies a quick-entry suggestion as an editable draft. Every applied field is marked
    /// "suggested" until the person edits or confirms it.
    func apply(_ suggestion: QuickEntrySuggestion) {
        self.suggestion = suggestion
        var marked: Set<SuggestedField> = []
        if let amount = suggestion.amount {
            entry = AmountEntry(money: Money(amount.amount, currency))
            marked.insert(.amount)
        }
        if let suggestedTitle = suggestion.title {
            title = suggestedTitle
            marked.insert(.title)
        }
        let groupMembers = Set(group?.activeMemberIDs ?? [])
        if let payer = suggestion.payerID, groupMembers.contains(payer) {
            payerID = payer
            marked.insert(.payer)
        }
        let participants = suggestion.participantIDs.filter(groupMembers.contains)
        if !participants.isEmpty {
            let order = group?.memberIDs ?? []
            participantIDs = participants.sorted { (order.firstIndex(of: $0) ?? .max) < (order.firstIndex(of: $1) ?? .max) }
            marked.insert(.participants)
        }
        method = .equal
        suggestedFields = marked
    }

    func dismissSuggestion() {
        suggestion = nil
        suggestedFields = []
    }

    // MARK: Navigation

    func advance() {
        switch step {
        case .amount where amountStepIssue == nil: step = .split
        case .split where canContinueFromSplit: step = .review
        default: break
        }
    }

    func goBack() {
        if let previous = Step(rawValue: step.rawValue - 1) { step = previous }
    }
}
