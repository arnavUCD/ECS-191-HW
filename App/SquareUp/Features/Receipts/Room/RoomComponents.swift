import SwiftUI

/// "Previewing as Maya" — the clearly labelled local-prototype identity switcher (§8.4).
/// Switching changes only who is acting; host rights stay with the host.
struct IdentitySwitcher: View {
    let summary: ReceiptRoomSummary
    @Binding var selection: MemberID?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var layout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: SUSpacing.xs))
            : AnyLayout(HStackLayout(spacing: SUSpacing.sm))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SUSpacing.xxs) {
            layout {
                if let member = summary.members[summary.actorID], !dynamicTypeSize.isAccessibilitySize {
                    SUAvatar(member: member, size: .medium, isCurrentUser: member.id == summary.currentUserID)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Previewing as \(summary.name(summary.actorID))"))
                        .font(SUFont.cardTitle)
                        .foregroundStyle(SUColor.textPrimary)
                        .lineLimit(2)
                        .accessibilityIdentifier("room.actingAs")
                    Text(roleText).font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                }
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: SUSpacing.xs) }
                Menu {
                    Picker(String(localized: "Act as"), selection: $selection) {
                        ForEach(summary.identities) { member in
                            Text(member.id == summary.room.hostID ? String(localized: "\(member.displayName) (host)") : member.displayName)
                                .tag(MemberID?.some(member.id))
                        }
                    }
                } label: {
                    Label(String(localized: "Switch"), systemImage: "person.2.arrow.trianglehead.counterclockwise")
                        .font(SUFont.supporting.weight(.semibold))
                        .padding(.horizontal, SUSpacing.sm)
                        .frame(minHeight: SUMetrics.minimumTouchTarget)
                        .suSurface(Capsule(), elevated: true)
                }
                .fixedSize()
                .accessibilityLabel(String(localized: "Switch who's acting"))
                .accessibilityValue(summary.name(summary.actorID))
                .accessibilityIdentifier("room.switchIdentity")
            }
            Label(String(localized: "Local prototype · everyone claims on this iPhone · nothing is sent to other devices"), systemImage: "iphone")
                .font(SUFont.metadata)
                .foregroundStyle(SUColor.textSecondary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
        }
        .padding(.horizontal, SUSpacing.screenMargin)
        .padding(.vertical, SUSpacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .accessibilityElement(children: .contain)
    }

    private var roleText: String {
        var roles: [String] = []
        if summary.isActorHost { roles.append(String(localized: "Host")) }
        if summary.room.payerID == summary.actorID { roles.append(String(localized: "Paid the bill")) }
        if roles.isEmpty { roles.append(String(localized: "Participant")) }
        return roles.joined(separator: " · ")
    }
}

/// The acting person's running total (§8.9).
struct YourTotalCard: View {
    let summary: ReceiptRoomSummary
    let markReviewed: () -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        let you = summary.you
        SUCard {
            VStack(alignment: .leading, spacing: SUSpacing.sm) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary.actorID == summary.currentUserID ? String(localized: "Your share") : String(localized: "\(summary.name(summary.actorID))'s share"))
                            .font(SUFont.supporting).foregroundStyle(SUColor.textSecondary)
                        SUAmountView(money: you.total, style: .large)
                            .accessibilityIdentifier("room.yourTotal")
                    }
                    Spacer()
                    if summary.isActorParticipant, summary.room.state != .readyToFinalize, !summary.room.state.isTerminal {
                        let reviewed = summary.room.reviewedRevision(of: summary.actorID) != nil && !summary.needsYourReview
                        Button(reviewed ? String(localized: "Reviewed") : String(localized: "Mark reviewed"),
                               systemImage: reviewed ? "checkmark.circle.fill" : "checkmark.circle", action: markReviewed)
                            .font(SUFont.supporting.weight(.semibold))
                            .disabled(reviewed)
                            .frame(minHeight: SUMetrics.minimumTouchTarget)
                            .accessibilityIdentifier("room.markReviewed")
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: SUSpacing.md, verticalSpacing: 4) {
                    breakdown(String(localized: "Items"), you.items)
                    breakdown(String(localized: "Tax"), you.tax)
                    breakdown(String(localized: "Tip"), you.tip)
                    breakdown(String(localized: "Fees"), you.fees)
                    breakdown(String(localized: "Discounts"), you.discounts)
                    breakdown(String(localized: "Adjustments"), you.adjustments)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func breakdown(_ title: String, _ money: Money) -> some View {
        if !money.isZero || title == String(localized: "Items") {
            GridRow {
                Text(title).font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                Text(MoneyFormatting.signedString(money, locale: locale).replacingOccurrences(of: "+", with: ""))
                    .font(SUFont.metadata.monospacedDigit())
                    .foregroundStyle(SUColor.textPrimary)
                    .gridColumnAlignment(.trailing)
            }
        }
    }
}

/// Room-wide allocated and remaining amounts (§8.9).
struct RoomProgressCard: View {
    let summary: ReceiptRoomSummary
    @Environment(\.locale) private var locale

    var body: some View {
        let total = summary.total
        let fraction = total.isZero ? 0 : min(max(NSDecimalNumber(decimal: summary.allocated.amount / total.amount).doubleValue, 0), 1)
        SUCard {
            VStack(alignment: .leading, spacing: SUSpacing.xs) {
                SUCapsuleLabel(title: ReceiptLanguage.label(summary.room.state), systemImage: ReceiptLanguage.symbol(summary.room.state),
                               tone: .informational, prominence: .outlined)
                    .fixedSize()
                    .accessibilityIdentifier("room.state")
                HStack {
                    Text(summary.remaining.isZero && summary.allocation.isComplete
                        ? String(localized: "Fully assigned")
                        : String(localized: "\(MoneyFormatting.string(summary.remaining.magnitude, locale: locale)) left to assign"))
                        .font(SUFont.cardTitle)
                        .foregroundStyle(SUColor.textPrimary)
                        .accessibilityIdentifier("room.remaining")
                    Spacer()
                    Text(String(localized: "of \(MoneyFormatting.string(total, locale: locale))")).font(SUFont.supporting).foregroundStyle(SUColor.textSecondary)
                }
                ProgressView(value: fraction)
                    .tint(summary.allocation.isComplete ? SUColor.positive : SUColor.accent)
                    .accessibilityHidden(true)
                HStack(spacing: SUSpacing.xs) {
                    if summary.unclaimedCount > 0 {
                        SUCapsuleLabel(title: Inflect.string("^[\(summary.unclaimedCount) unclaimed](inflect: true)"), systemImage: "circle.dashed", tone: .warning)
                    }
                    if summary.disputedCount > 0 {
                        SUCapsuleLabel(title: Inflect.string("^[\(summary.disputedCount) dispute](inflect: true)"), systemImage: "exclamationmark.bubble",
                                       tone: .negative)
                    }
                    if summary.allocation.isComplete {
                        SUCapsuleLabel(title: String(localized: "Adds up exactly"), systemImage: "checkmark.seal", tone: .positive)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One item with its claim state, claimants, the acting person's part, and actions (§8.6).
struct RoomItemRow: View {
    struct Actions {
        let mine: () -> Void
        let share: () -> Void
        let undo: () -> Void
        let customSplit: () -> Void
        let dispute: () -> Void
        let resolve: (() -> Void)?
        /// "How many did you have?" for a line with a printed quantity of 2 or more.
        var units: (() -> Void)?
    }

    let summary: ReceiptRoomSummary
    let line: ReceiptRoomSummary.ItemLine
    let actions: Actions
    @Environment(\.locale) private var locale
    @Environment(\.pendingRoomItems) private var pendingItems

    private var isMine: Bool { line.allocation.claimants.contains(summary.actorID) }
    private var claims: [ReceiptClaim] { summary.room.claims(for: line.id) }
    /// The line lists a quantity people can claim part of ("2 of 3").
    private var isCountable: Bool { (line.item.quantity ?? 0) >= 2 && actions.units != nil }
    private var isSplitByUnits: Bool { !claims.isEmpty && claims.allSatisfy(\.mode.isUnits) }
    private var unitsText: String? {
        guard isSplitByUnits, let quantity = line.item.quantity else { return nil }
        let claimed = claims.reduce(0) { total, claim in if case .units(let count) = claim.mode { total + count } else { total } }
        return String(localized: "\(claimed) of \(quantity) claimed")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SUSpacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: SUSpacing.sm) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(line.item.name.value)
                        .font(SUFont.body.weight(.semibold))
                        .foregroundStyle(SUColor.textPrimary)
                        .lineLimit(3)
                    HStack(spacing: SUSpacing.xs) {
                        stateChip
                        if pendingItems.contains(line.id) {
                            // Shared rooms: shown until the server confirms (never looks final before then).
                            SUCapsuleLabel(title: String(localized: "Sending…"), systemImage: "arrow.up.circle", tone: .informational, prominence: .outlined)
                                .accessibilityIdentifier("room.item.pending")
                        }
                        if line.isResolved { SUCapsuleLabel(title: String(localized: "Resolved"), systemImage: "checkmark.bubble", tone: .positive, prominence: .outlined) }
                        if let unitsText {
                            SUCapsuleLabel(title: unitsText, systemImage: "number", tone: .neutral, prominence: .outlined)
                                .accessibilityIdentifier("room.item.units")
                        }
                    }
                }
                Spacer(minLength: SUSpacing.xs)
                VStack(alignment: .trailing, spacing: 2) {
                    ReceiptAmountText(money: line.item.amount)
                    if let share = line.yourShare, line.allocation.isShared {
                        Text(String(localized: "you \(MoneyFormatting.string(share, locale: locale))"))
                            .font(SUFont.metadata.monospacedDigit()).foregroundStyle(SUColor.accent)
                    }
                }
            }
            if !line.allocation.claimants.isEmpty {
                SUAvatarStack(members: line.allocation.claimants.compactMap { summary.members[$0] }, currentUserID: summary.currentUserID,
                              size: .small, maximumVisible: 5)
                    .accessibilityHidden(true)
            }
            if line.state != .note, summary.canClaim || summary.isActorParticipant { actionRow }
        }
        .padding(SUSpacing.sm + 2)
        .suSurface(SUShape.compact)
        .overlay {
            if line.state == .disputed || line.state == .unclaimed {
                SUShape.compact.strokeBorder((line.state == .disputed ? SUColor.negative : SUColor.warning).opacity(0.55), lineWidth: 1.5)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(line.item.name.value), \(MoneyFormatting.spokenString(line.item.amount, locale: locale)), \(summary.stateText(line))")
        .accessibilityIdentifier("room.item.\(line.item.name.value)")
    }

    private var stateChip: some View {
        let (symbol, tone): (String, SUTone) = switch line.state {
        case .note: ("note.text", .neutral)
        case .unclaimed: ("circle.dashed", .warning)
        case .claimed: ("person.fill.checkmark", .positive)
        case .shared: ("person.2.fill", .informational)
        case .needsAttention: ("exclamationmark.triangle", .warning)
        case .disputed: ("exclamationmark.bubble.fill", .negative)
        }
        return SUCapsuleLabel(title: summary.stateText(line), systemImage: symbol, tone: tone)
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @ViewBuilder
    private var actionRow: some View {
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: SUSpacing.xs))
            : AnyLayout(HStackLayout(spacing: SUSpacing.xs))
        layout {
            if summary.canClaim, summary.isActorParticipant {
                if isMine {
                    if isCountable, isSplitByUnits, let units = actions.units {
                        actionButton(String(localized: "Change"), "number", identifier: "units", action: units)
                    }
                    actionButton(String(localized: "Undo"), "arrow.uturn.backward", identifier: "undo", action: actions.undo)
                } else {
                    if line.allocation.claimants.isEmpty {
                        actionButton(String(localized: "Mine"), "hand.raised.fill", prominent: true, identifier: "mine", action: actions.mine)
                    }
                    // A countable line can be claimed part by part ("2 of 3") without touching others' claims.
                    if isCountable, claims.isEmpty || isSplitByUnits, let units = actions.units {
                        actionButton(String(localized: "Some"), "number", prominent: isSplitByUnits, identifier: "units", action: units)
                    }
                    if !isSplitByUnits {
                        actionButton(String(localized: "Share"), "person.2", identifier: "share", action: actions.share)
                    }
                }
            }
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
            Menu {
                if summary.canClaim, isMine || summary.isActorHost {
                    Button(summary.isActorHost ? String(localized: "Assign or split…") : String(localized: "Custom split…"),
                           systemImage: "slider.horizontal.3", action: actions.customSplit)
                }
                Button(String(localized: "Not mine / Dispute…"), systemImage: "exclamationmark.bubble", action: actions.dispute)
                if summary.isActorHost, let resolve = actions.resolve {
                    Button(String(localized: "Resolve dispute…"), systemImage: "checkmark.bubble", action: resolve)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .frame(minWidth: SUMetrics.minimumTouchTarget, minHeight: SUMetrics.minimumTouchTarget)
            }
            .accessibilityLabel(String(localized: "More for \(line.item.name.value)"))
            .accessibilityIdentifier("room.item.\(line.item.name.value).more")
        }
    }

    private func actionButton(_ title: String, _ symbol: String, prominent: Bool = false, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(SUFont.supporting.weight(.semibold))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, SUSpacing.sm)
                .frame(minHeight: SUMetrics.minimumTouchTarget)
                .foregroundStyle(prominent ? SUColor.onAccent : SUColor.textPrimary)
                .background(prominent ? SUColor.accent : SUColor.surfaceElevated, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "\(title): \(line.item.name.value)"))
        .accessibilityIdentifier("room.item.\(line.item.name.value).\(identifier)")
    }
}

/// A charge with its strategy and the acting person's portion.
struct ChargeRow: View {
    let summary: ReceiptRoomSummary
    let charge: ReceiptCharge
    let action: () -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        let result = summary.allocation.charge(charge.id)
        let yours = result?.shares.first { $0.memberID == summary.actorID }?.amount
        Button(action: action) {
            HStack(spacing: SUSpacing.sm) {
                Image(systemName: ReceiptLanguage.symbol(charge.kind))
                    .foregroundStyle(SUColor.accent)
                    .frame(width: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(charge.label).font(SUFont.body.weight(.semibold)).foregroundStyle(SUColor.textPrimary)
                    Text(summary.chargeStrategyText(charge)).font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                    if let result, !result.isAllocated {
                        Label(ReceiptLanguage.readiness(.unallocatedCharge(charge.id, result.status), room: summary.room, names: summary.names, locale: locale),
                              systemImage: "exclamationmark.triangle")
                            .font(SUFont.metadata).foregroundStyle(SUColor.warning)
                    }
                    if !summary.room.disputes(on: .charge(charge.id)).filter(\.isOpen).isEmpty {
                        SUCapsuleLabel(title: String(localized: "Disputed"), systemImage: "exclamationmark.bubble.fill", tone: .negative)
                    }
                }
                Spacer(minLength: SUSpacing.xs)
                VStack(alignment: .trailing, spacing: 2) {
                    ReceiptAmountText(money: charge.value)
                    if let yours {
                        Text(String(localized: "you \(MoneyFormatting.signedString(yours, locale: locale).replacingOccurrences(of: "+", with: ""))"))
                            .font(SUFont.metadata.monospacedDigit()).foregroundStyle(SUColor.accent)
                    }
                }
            }
            .padding(SUSpacing.sm + 2)
            .suSurface(SUShape.compact)
            .contentShape(SUShape.compact)
        }
        .buttonStyle(.suPressable)
        .accessibilityElement(children: .combine)
        .accessibilityHint(summary.isActorHost ? String(localized: "Choose how this is divided") : String(localized: "Dispute this charge"))
        .accessibilityIdentifier("room.charge.\(charge.kind.rawValue)")
    }
}

struct DisputeRow: View {
    let summary: ReceiptRoomSummary
    let dispute: ReceiptDispute
    let canResolve: Bool
    let resolve: () -> Void

    var body: some View {
        if canResolve {
            // The whole row is the host's Resolve button: one target for touch, VoiceOver, and Voice Control.
            Button(action: resolve) { content(showsAction: true) }
                .buttonStyle(.suPressable)
                .accessibilityHint(String(localized: "Opens resolution options"))
                .accessibilityIdentifier("room.resolveDispute")
        } else {
            content(showsAction: false)
                .accessibilityElement(children: .combine)
        }
    }

    private func content(showsAction: Bool) -> some View {
        HStack(alignment: .top, spacing: SUSpacing.sm) {
            Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(SUColor.negative).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(ReceiptLanguage.readiness(.openDispute(dispute.id), room: summary.room, names: summary.names))
                    .font(SUFont.body.weight(.semibold)).foregroundStyle(SUColor.textPrimary)
                    .multilineTextAlignment(.leading)
                if let note = dispute.note {
                    Text("\u{201C}\(note)\u{201D}").font(SUFont.supporting).foregroundStyle(SUColor.textSecondary)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 0)
            if showsAction {
                Text(String(localized: "Resolve"))
                    .font(SUFont.supporting.weight(.semibold))
                    .foregroundStyle(SUColor.accent)
                    .frame(minHeight: SUMetrics.minimumTouchTarget)
            }
        }
        .padding(SUSpacing.sm + 2)
        .background(SUColor.negative.opacity(0.1), in: SUShape.compact)
        .contentShape(SUShape.compact)
    }
}

extension EnvironmentValues {
    /// Items with a change waiting for the server in a shared room (milestone 4 §7.4).
    @Entry var pendingRoomItems: Set<ReceiptItemID> = []
}
