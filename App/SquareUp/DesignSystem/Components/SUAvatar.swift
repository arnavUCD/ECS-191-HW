import SwiftUI

/// A person's avatar: photo when available, otherwise initials on a deterministic colour.
///
/// The avatar never stands alone as identity — callers show the person's name nearby, and the
/// accessibility label always carries the full name.
struct SUAvatar: View {
    enum Size {
        case small
        case medium
        case large
        case hero

        var diameter: CGFloat {
            switch self {
            case .small: 28
            case .medium: 40
            case .large: 56
            case .hero: 84
            }
        }

        var font: Font {
            switch self {
            case .small: .system(size: 10, weight: .bold)
            case .medium: .footnote.weight(.bold)
            case .large: .title3.weight(.bold)
            case .hero: .title.weight(.bold)
            }
        }
    }

    let member: Member
    var size: Size = .medium
    var isCurrentUser = false
    var isSelected = false
    var image: Image?

    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    var body: some View {
        let diameter = size.diameter * min(scale, 1.6)
        let palette = AvatarPalette.colors(for: member.id)
        ZStack {
            if let image {
                image.resizable().scaledToFill()
            } else {
                palette.fill
                Text(member.initials)
                    .font(size.font)
                    .foregroundStyle(palette.ink)
                    .minimumScaleFactor(0.6)
                    .padding(diameter * 0.12)
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .overlay {
            if isCurrentUser || isSelected {
                Circle().strokeBorder(SUColor.accent, lineWidth: max(2, diameter * 0.05))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(SUColor.onAccent, SUColor.accent)
                    .font(.system(size: diameter * 0.36, weight: .bold))
                    .background(Circle().fill(SUColor.backgroundPrimary).padding(-1))
                    .offset(x: diameter * 0.06, y: diameter * 0.06)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var accessibilityName: String {
        isCurrentUser ? String(localized: "\(member.displayName) (you)") : member.displayName
    }
}

/// Deterministic avatar colours from the asset catalog (contrast ≥ 6:1 in both appearances).
enum AvatarPalette {
    private static let pairs: [(fill: ColorResource, ink: ColorResource)] = [
        (.Avatar.fill1, .Avatar.ink1), (.Avatar.fill2, .Avatar.ink2),
        (.Avatar.fill3, .Avatar.ink3), (.Avatar.fill4, .Avatar.ink4),
        (.Avatar.fill5, .Avatar.ink5), (.Avatar.fill6, .Avatar.ink6),
        (.Avatar.fill7, .Avatar.ink7), (.Avatar.fill8, .Avatar.ink8),
    ]

    static var count: Int { pairs.count }

    static func colors(for id: MemberID) -> (fill: Color, ink: Color) {
        let pair = pairs[id.stableBucket(count: pairs.count)]
        return (Color(pair.fill), Color(pair.ink))
    }
}

/// Overlapping avatars with a "+N" overflow chip, read by VoiceOver as one list of names.
struct SUAvatarStack: View {
    let members: [Member]
    var currentUserID: MemberID?
    var size: SUAvatar.Size = .small
    var maximumVisible = 4

    var body: some View {
        let visible = Array(members.prefix(maximumVisible))
        let overflow = members.count - visible.count
        HStack(spacing: -size.diameter * 0.18) {
            ForEach(visible) { member in
                SUAvatar(member: member, size: size, isCurrentUser: member.id == currentUserID)
                    .background(Circle().fill(SUColor.surfacePrimary).padding(-2))
            }
            if overflow > 0 {
                Text("+\(overflow)")
                    .font(size.font.monospacedDigit())
                    .foregroundStyle(SUColor.textSecondary)
                    .frame(minWidth: size.diameter, minHeight: size.diameter)
                    .padding(.horizontal, 4)
                    .background(SUColor.surfaceElevated, in: Capsule())
                    .background(Capsule().fill(SUColor.surfacePrimary).padding(-2))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PersonIdentity.list(members, currentUserID: currentUserID, maximumNames: 4))
    }
}

#Preview("Avatars", traits: .sizeThatFitsLayout) {
    let members = SampleLedger.make(referenceDate: .now).members.values.sorted { $0.displayName < $1.displayName }
    VStack(alignment: .leading, spacing: SUSpacing.md) {
        HStack {
            SUAvatar(member: members[0], size: .small)
            SUAvatar(member: members[1], size: .medium, isCurrentUser: true)
            SUAvatar(member: members[2], size: .large, isSelected: true)
            SUAvatar(member: members[3], size: .hero)
        }
        SUAvatarStack(members: members, currentUserID: members[0].id)
        SUAvatarStack(members: Array(members.prefix(3)), size: .medium)
    }
    .padding()
    .background(SUColor.backgroundPrimary)
}
