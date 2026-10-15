import SwiftUI

/// A compact capsule combining icon, text, and tone. Shared by identity badges and status chips so
/// every state has a distinct label *and* symbol, never colour alone.
struct SUCapsuleLabel: View {
    let title: String
    let systemImage: String
    var tone: SUTone = .neutral
    var prominence: Prominence = .tinted

    enum Prominence {
        /// Tinted background, toned foreground.
        case tinted
        /// Outline only; for dense lists.
        case outlined
    }

    var body: some View {
        Label {
            Text(title)
                .lineLimit(1)
        } icon: {
            Image(systemName: systemImage)
                .symbolRenderingMode(.hierarchical)
        }
        .font(SUFont.chip)
        .labelStyle(.titleAndIcon)
        .foregroundStyle(tone.color)
        .padding(.horizontal, SUSpacing.xs + 2)
        .padding(.vertical, SUSpacing.xxs + 1)
        .background {
            switch prominence {
            case .tinted:
                Capsule().fill(tone.color.opacity(0.14))
            case .outlined:
                Capsule().strokeBorder(tone.color.opacity(0.45), lineWidth: 1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Identity badges in shared money actions: who paid, which row is you, and — in a shared group —
/// who owns it (group settings and invitations only, never anyone's money) and who hasn't joined yet.
struct SURoleBadge: View {
    enum Kind: Hashable {
        case payer
        case you
        /// Milestone 7: manages the group's details, invitations, and membership.
        case owner
        /// Milestone 7: a named place in a shared group waiting for its person to join.
        case waitingToJoin
    }

    let kind: Kind

    var body: some View {
        SUCapsuleLabel(title: title, systemImage: symbol, tone: tone)
    }

    private var title: String {
        switch kind {
        case .payer: String(localized: "Payer")
        case .you: String(localized: "You")
        case .owner: String(localized: "Owner")
        case .waitingToJoin: String(localized: "Waiting to join")
        }
    }

    private var symbol: String {
        switch kind {
        case .payer: "creditcard"
        case .you: "person.crop.circle"
        case .owner: "key"
        case .waitingToJoin: "hourglass"
        }
    }

    private var tone: SUTone {
        switch kind {
        case .payer, .you: .accent
        case .owner: .neutral
        case .waitingToJoin: .warning
        }
    }
}

/// A state chip: sync state, settlement state, or any explicit state.
struct SUStatusChip: View {
    let title: String
    let systemImage: String
    var tone: SUTone

    static let offline = SUStatusChip(
        title: String(localized: "Offline"), systemImage: "icloud.slash", tone: .warning
    )
    static let savedOnDevice = SUStatusChip(
        title: String(localized: "Saved on this iPhone"), systemImage: "iphone", tone: .neutral
    )
    static let settled = SUStatusChip(
        title: String(localized: "All square"), systemImage: "checkmark.seal", tone: .positive
    )

    var body: some View {
        SUCapsuleLabel(title: title, systemImage: systemImage, tone: tone)
    }
}

#Preview("Badges & chips", traits: .sizeThatFitsLayout) {
    VStack(alignment: .leading, spacing: SUSpacing.sm) {
        HStack {
            SURoleBadge(kind: .payer)
            SURoleBadge(kind: .you)
        }
        HStack { SUStatusChip.savedOnDevice }
        HStack { SUStatusChip.offline; SUStatusChip.settled }
    }
    .padding()
    .background(SUColor.backgroundPrimary)
}
