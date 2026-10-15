import SwiftUI

/// A shared group's pending receipts ("Add to a group"): not expenses yet, and never part of
/// balances until the host finishes them. The people on a receipt see whether it's waiting for
/// their review and their estimated share; anyone else in the group sees only that it's happening.
struct GroupReceiptsSection: View {
    let ledger: SharedGroupLedger
    @Environment(AppRouter.self) private var router
    @Environment(\.locale) private var locale

    private var receipts: [GroupReceiptDTO] { ledger.pendingReceipts.sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") } }
    private var viewer: String? { ledger.base?.viewer.memberId }

    var body: some View {
        if !receipts.isEmpty {
            SUPanelSection(title: needsYou > 0 ? Inflect.string("^[\(needsYou) receipt](inflect: true) needs you") : String(localized: "Receipts being split"),
                           subtitle: String(localized: "Not expenses yet. Balances change only when the host finishes one.")) {
                VStack(spacing: SUSpacing.sm) {
                    ForEach(receipts) { receipt in
                        if receipt.viewerIsParticipant {
                            Button { router.openGroupReceipt(ReceiptRoomID(string: receipt.id) ?? ReceiptRoomID(), in: ledger.groupID) } label: {
                                ReceiptCard(receipt: receipt, viewer: viewer, names: names)
                            }
                            .buttonStyle(.suPressable)
                            .accessibilityHint(String(localized: "Opens the receipt to claim and review your items"))
                            .accessibilityIdentifier("group.receipt.\(receipt.merchant)")
                        } else {
                            ReceiptCard(receipt: receipt, viewer: viewer, names: names)
                                .accessibilityIdentifier("group.receipt.readOnly")
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("group.receipts")
        }
    }

    private var needsYou: Int { ledger.receiptsNeedingYou.count }

    private var names: [String: String] {
        Dictionary((ledger.base?.members ?? []).map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
    }
}

/// One pending group receipt as a card: what it is, where it stands, and what's waiting for you.
private struct ReceiptCard: View {
    let receipt: GroupReceiptDTO
    let viewer: String?
    let names: [String: String]
    @Environment(\.locale) private var locale

    private var isHost: Bool { receipt.hostMemberId == viewer }
    private var host: String { names[receipt.hostMemberId] ?? String(localized: "Someone") }
    private var currency: CurrencyCode { CurrencyCode(receipt.currency) }

    var body: some View {
        HStack(alignment: .top, spacing: SUSpacing.sm) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tone.color)
                .frame(width: 40, height: 40)
                .background(tone.color.opacity(0.16), in: SUShape.control)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(headline).font(SUFont.body.weight(.semibold)).foregroundStyle(SUColor.textPrimary)
                Text(detail).font(SUFont.metadata).foregroundStyle(SUColor.textSecondary).fixedSize(horizontal: false, vertical: true)
                if receipt.viewerIsParticipant { SUCapsuleLabel(title: stateText, systemImage: "clock", tone: tone, prominence: .outlined) }
            }
            Spacer(minLength: SUSpacing.xs)
            VStack(alignment: .trailing, spacing: 2) {
                if let total = receipt.total { SUAmountView(money: Money(minorUnits: Int64(total), currency: currency), direction: .muted, style: .small) }
                if let share = yourShare {
                    Text(String(localized: "you ~\(MoneyFormatting.string(share, locale: locale))"))
                        .font(SUFont.metadata.monospacedDigit()).foregroundStyle(SUColor.accent)
                }
            }
            if receipt.viewerIsParticipant {
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(SUColor.textTertiary).accessibilityHidden(true)
            }
        }
        .padding(SUSpacing.sm + 2)
        .suSurface(SUShape.compact)
        .contentShape(SUShape.compact)
        .accessibilityElement(children: .combine)
    }

    private var needsReview: Bool { viewer.map { receipt.room?.unreviewed?.contains($0) ?? false } ?? false }

    private var headline: String {
        if !receipt.viewerIsParticipant { return String(localized: "\(host) is splitting \(receipt.merchant)") }
        if isHost { return String(localized: "Finish splitting \(receipt.merchant)") }
        return needsReview ? String(localized: "Receipt needs your review") : String(localized: "\(receipt.merchant) · reviewed")
    }

    private var detail: String {
        let people = Inflect.string("^[\(receipt.participantIds.count) person](inflect: true)")
        if !receipt.viewerIsParticipant { return String(localized: "With \(people). You're not on this receipt.") }
        if isHost {
            return receipt.unreviewedCount == 0 ? String(localized: "Everyone has reviewed. Finish it when it's all claimed.")
                : Inflect.string("^[\(receipt.unreviewedCount) person](inflect: true) still to review")
        }
        return String(localized: "\(receipt.merchant) · \(host) paid · \(people)")
    }

    private var stateText: String {
        switch receipt.state {
        case "resolving": String(localized: "Host is resolving the rest")
        case "readyToFinalize": String(localized: "Final review")
        default: String(localized: "Claiming open")
        }
    }

    private var symbol: String { needsReview || isHost ? "doc.text.magnifyingglass" : "receipt" }
    private var tone: SUTone { needsReview || isHost ? .warning : .informational }

    /// The viewer's estimated share, from the receipt as the server allocated it.
    private var yourShare: Money? {
        guard let viewer, let total = receipt.room?.allocation.participants.first(where: { $0.participantId == viewer })?.total, total != 0 else { return nil }
        return Money(minorUnits: Int64(total), currency: currency)
    }
}
