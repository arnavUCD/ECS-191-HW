import SwiftUI

// MARK: - Headline

/// A two-tone headline: the statement bright, the context beneath it receding ("Good morning,
/// Riley" / "Here's where everyone stands."). One header element for VoiceOver.
struct SUHeadline: View {
    let primary: String
    let secondary: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(primary).foregroundStyle(SUColor.textPrimary)
            Text(secondary).foregroundStyle(SUColor.textSecondary)
        }
        .font(.system(.title, weight: .semibold))
        .kerning(-0.5)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Panel section

/// A large panel holding one section: its header (with an optional pill action) and rows. The
/// panels stack down a screen like sheets, each lit along its top edge.
struct SUPanelSection<Content: View>: View {
    let title: String
    var subtitle: String?
    var actionTitle: String?
    var action: (() -> Void)?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: SUSpacing.sm) {
            SUSectionHeader(title: title, subtitle: subtitle, actionTitle: actionTitle, action: action)
            content
        }
        .padding(.horizontal, SUSpacing.md + 2)
        .padding(.vertical, SUSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { SUBevel(shape: RoundedRectangle(cornerRadius: SURadius.panel - 6, style: .continuous)) }
    }
}

// MARK: - Folder tab

/// A rounded panel with a raised tab on its top edge, like a folder or a pocket's pull tab. The
/// tab's foot is filleted into the panel so the edge stays continuous.
nonisolated struct SUTabShape: InsettableShape {
    var cornerRadius: CGFloat = SURadius.card
    var tabWidth: CGFloat = 140
    var tabHeight: CGFloat = 34
    var tabRadius: CGFloat = 14
    var fillet: CGFloat = 14
    /// The tab's distance from the leading edge; `nil` centres it.
    var tabLeading: CGFloat?
    var insetAmount: CGFloat = 0

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(tabWidth, tabHeight) }
        set { tabWidth = newValue.first; tabHeight = newValue.second }
    }

    func inset(by distance: CGFloat) -> SUTabShape {
        var shape = self
        shape.insetAmount += distance
        return shape
    }

    func path(in rect: CGRect) -> Path {
        let frame = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let bodyTop = frame.minY + min(tabHeight, frame.height / 2)
        let radius = max(0, min(cornerRadius - insetAmount, (frame.maxY - bodyTop) / 2, frame.width / 2))
        let fillet = max(0, min(fillet + insetAmount, bodyTop - frame.minY))
        let width = max(0, min(tabWidth - insetAmount * 2, frame.width - (radius + fillet) * 2))
        let left = tabLeading.map { max(frame.minX + radius + fillet, frame.minX + $0 + insetAmount) } ?? (frame.midX - width / 2)
        let right = left + width
        let tabCorner = max(0, min(tabRadius - insetAmount, (bodyTop - frame.minY) / 2, width / 2))

        var path = Path()
        path.move(to: CGPoint(x: frame.minX, y: bodyTop + radius))
        path.addArc(tangent1End: CGPoint(x: frame.minX, y: bodyTop), tangent2End: CGPoint(x: frame.minX + radius, y: bodyTop), radius: radius)
        if width > 0 {
            path.addLine(to: CGPoint(x: left - fillet, y: bodyTop))
            path.addQuadCurve(to: CGPoint(x: left, y: bodyTop - fillet), control: CGPoint(x: left, y: bodyTop))
            path.addLine(to: CGPoint(x: left, y: frame.minY + tabCorner))
            path.addArc(tangent1End: CGPoint(x: left, y: frame.minY), tangent2End: CGPoint(x: left + tabCorner, y: frame.minY), radius: tabCorner)
            path.addLine(to: CGPoint(x: right - tabCorner, y: frame.minY))
            path.addArc(tangent1End: CGPoint(x: right, y: frame.minY), tangent2End: CGPoint(x: right, y: frame.minY + tabCorner), radius: tabCorner)
            path.addLine(to: CGPoint(x: right, y: bodyTop - fillet))
            path.addQuadCurve(to: CGPoint(x: right + fillet, y: bodyTop), control: CGPoint(x: right, y: bodyTop))
        }
        path.addLine(to: CGPoint(x: frame.maxX - radius, y: bodyTop))
        path.addArc(tangent1End: CGPoint(x: frame.maxX, y: bodyTop), tangent2End: CGPoint(x: frame.maxX, y: bodyTop + radius), radius: radius)
        path.addLine(to: CGPoint(x: frame.maxX, y: frame.maxY - radius))
        path.addArc(tangent1End: CGPoint(x: frame.maxX, y: frame.maxY), tangent2End: CGPoint(x: frame.maxX - radius, y: frame.maxY), radius: radius)
        path.addLine(to: CGPoint(x: frame.minX + radius, y: frame.maxY))
        path.addArc(tangent1End: CGPoint(x: frame.minX, y: frame.maxY), tangent2End: CGPoint(x: frame.minX, y: frame.maxY - radius), radius: radius)
        path.closeSubpath()
        return path
    }
}

/// A panel with a raised tab carrying a short label ("You pay Maya", "Waiting for you"). The tab is
/// sized to its label, so it fits any text size.
///
/// - `frosted`: dark frosted glass that blurs a cover behind it (a pocket rising out of a cover).
/// - `surface`: the standard bevelled panel, for use directly on the backdrop.
struct SUTabbedPanel<Tab: View, Content: View>: View {
    enum Material { case frosted, surface }

    var material: Material = .frosted
    var cornerRadius: CGFloat = SURadius.card
    var leadingTab = false
    @ViewBuilder var tab: Tab
    @ViewBuilder var content: Content

    @State private var tabSize = CGSize(width: 120, height: 18)
    private let tabPadding = CGSize(width: 18, height: 9)
    private let tabInset: CGFloat = 16

    private var shape: SUTabShape {
        SUTabShape(cornerRadius: cornerRadius, tabWidth: tabSize.width + tabPadding.width * 2, tabHeight: tabSize.height + tabPadding.height * 2,
                   tabRadius: 14, fillet: 14, tabLeading: leadingTab ? tabInset : nil)
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, tabSize.height + tabPadding.height * 2)
            .background { surface }
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.24), .white.opacity(0.06), .white.opacity(0.03)],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
            .overlay(alignment: leadingTab ? .topLeading : .top) {
                tab
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { tabSize = $0 }
                    .padding(.top, tabPadding.height)
                    .padding(.leading, leadingTab ? tabInset + tabPadding.width : 0)
            }
    }

    @ViewBuilder
    private var surface: some View {
        switch material {
        case .frosted:
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(Color.black.opacity(0.52))
            }
        case .surface:
            SUBevel(shape: shape, elevated: true)
        }
    }
}

// MARK: - Covers

/// The printed art behind a cover: the dusk aurora in a palette, a halftone swelling toward a
/// focal point, the subject's symbol pressed faintly into the corner, and a scrim at the foot.
struct SUCoverArt: View {
    var palette: SUMeshBackground.Palette = .calm
    var symbol: String?
    var isAnimated = false
    var focus = UnitPoint(x: 0.7, y: 0.36)
    /// The halftone's pitch; smaller covers use a finer screen.
    var halftoneSpacing: CGFloat = 11

    var body: some View {
        ZStack {
            SUMeshBackground(palette: palette, isAnimated: isAnimated)
            GeometryReader { proxy in
                RadialGradient(colors: [palette.primaryGlow.opacity(0.85), palette.warmth.opacity(0.35), .clear], center: focus,
                               startRadius: 0, endRadius: max(proxy.size.width, proxy.size.height) * 0.62)
            }
            SUHalftone(focus: focus, spacing: halftoneSpacing)
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 170, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.08))
                    .rotationEffect(.degrees(-12))
                    .offset(x: 34, y: 34)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
            LinearGradient(colors: [.black.opacity(0.18), .clear, .black.opacity(0.38)], startPoint: .top, endPoint: .bottom)
        }
        // The corner symbol is pressed past the edge on purpose; nothing of it extends the layout.
        .clipped()
        .accessibilityHidden(true)
    }
}

/// A cover inset in a panel, with what's below it centred beneath — the hero for a group, an
/// expense, or a plan. The cover's own content (chips, avatars, pills) lays out over the art with
/// frames; the inner radius is concentric with the panel's.
struct SUCoverPanel<Cover: View, Content: View>: View {
    var palette: SUMeshBackground.Palette = .calm
    var symbol: String?
    var isAnimated = false
    var coverHeight: CGFloat = 230
    /// Space between the cover's edge and its content (smaller when the content is a pocket that
    /// should sit concentric with the cover).
    var coverPadding: CGFloat = SUSpacing.md
    @ViewBuilder var cover: Cover
    @ViewBuilder var content: Content

    private let inset: CGFloat = 6
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    private var hasContent: Bool { Content.self != EmptyView.self }
    private var innerShape: RoundedRectangle { RoundedRectangle(cornerRadius: SURadius.panel - inset, style: .continuous) }

    var body: some View {
        VStack(spacing: 0) {
            ZStack { cover }
                .padding(coverPadding)
                .frame(maxWidth: .infinity, minHeight: coverHeight * min(max(scale, 1), 1.6), alignment: .topLeading)
                .background { SUCoverArt(palette: palette, symbol: symbol, isAnimated: isAnimated) }
                .clipShape(innerShape)
                .overlay { innerShape.strokeBorder(.white.opacity(0.12), lineWidth: 1) }
                .environment(\.colorScheme, .dark)
                .padding(inset)
            if hasContent {
                content
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, SUSpacing.lg)
                    .padding(.top, SUSpacing.sm)
                    .padding(.bottom, SUSpacing.lg)
            }
        }
        .background { SUBevel(shape: RoundedRectangle(cornerRadius: SURadius.panel, style: .continuous), elevated: true) }
    }
}

extension SUCoverPanel where Content == EmptyView {
    init(palette: SUMeshBackground.Palette = .calm, symbol: String? = nil, isAnimated: Bool = false, coverHeight: CGFloat = 230,
         coverPadding: CGFloat = SUSpacing.md, @ViewBuilder cover: () -> Cover) {
        self.init(palette: palette, symbol: symbol, isAnimated: isAnimated, coverHeight: coverHeight, coverPadding: coverPadding,
                  cover: cover, content: { EmptyView() })
    }
}

/// The dark readout chip at the top of a cover: a dot-matrix figure (or a symbol) with two lines
/// of context, read by VoiceOver as one phrase.
struct SUCoverChip: View {
    enum Lead {
        case readout(String)
        case symbol(String, Color)
    }

    let lead: Lead
    let title: String
    var subtitle: String?

    var body: some View {
        HStack(spacing: SUSpacing.sm) {
            switch lead {
            case .readout(let value):
                SUDotMatrix(text: value)
            case .symbol(let name, let tint):
                Image(systemName: name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.white)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.62))
                }
            }
            .lineLimit(1)
        }
        .padding(.horizontal, SUSpacing.sm + 2)
        .padding(.vertical, SUSpacing.xs + 2)
        .background(.black.opacity(0.64), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 1) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts: [String] = []
        if case .readout(let value) = lead { parts.append(value) }
        parts.append(title)
        if let subtitle { parts.append(subtitle) }
        return parts.joined(separator: " ")
    }
}

/// People as bubbles of a few sizes, loosely clustered at the foot of a cover. Decorative
/// placement, so it keeps its composition at large text sizes; VoiceOver reads the names.
struct SUAvatarCluster: View {
    let members: [Member]
    var currentUserID: MemberID?

    private struct Slot {
        let x: CGFloat
        let y: CGFloat
        let size: SUAvatar.Size
    }

    private let slots = [
        Slot(x: 34, y: 0, size: .large), Slot(x: 0, y: 40, size: .medium),
        Slot(x: 78, y: 46, size: .medium), Slot(x: 96, y: 8, size: .small),
    ]

    var body: some View {
        let shown = Array(members.prefix(members.count > slots.count ? slots.count - 1 : slots.count))
        let overflow = members.count - shown.count
        ZStack(alignment: .topLeading) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, member in
                SUAvatar(member: member, size: slots[index].size, isCurrentUser: member.id == currentUserID)
                    .overlay { Circle().strokeBorder(.white.opacity(member.id == currentUserID ? 0 : 0.45), lineWidth: 1.5) }
                    .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                    .offset(x: slots[index].x, y: slots[index].y)
            }
            if overflow > 0 {
                Text("+\(overflow)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .glassEffect(.regular, in: Circle())
                    .offset(x: slots[slots.count - 1].x, y: slots[slots.count - 1].y)
            }
        }
        .frame(width: 136, height: 88, alignment: .topLeading)
        .dynamicTypeSize(...DynamicTypeSize.large)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PersonIdentity.list(members, currentUserID: currentUserID, maximumNames: 4))
    }
}

// MARK: - Pills and small buttons

/// A small glass pill for a cover's or panel's label: symbol and words.
struct SUTagPill: View {
    let title: String
    var systemImage: String?
    var isProminent = false

    var body: some View {
        Group {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
        .font(SUFont.chip)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .foregroundStyle(isProminent ? Color.black : SUColor.textPrimary)
        .padding(.horizontal, SUSpacing.sm)
        .frame(minHeight: 32)
        .glassEffect(isProminent ? .regular.tint(.white) : .regular, in: Capsule())
    }
}

/// A small glass capsule for an inline action beside a heading ("See all").
struct SUPillButtonStyle: ButtonStyle {
    var isProminent = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(SUFont.chip)
            .lineLimit(1)
            .foregroundStyle(isProminent ? Color.black : SUColor.textPrimary)
            .padding(.horizontal, SUSpacing.sm + 2)
            .frame(minHeight: 34)
            .contentShape(Capsule())
            .glassEffect(isProminent ? .regular.tint(.white).interactive() : .regular.interactive(), in: Capsule())
            .frame(minHeight: SUMetrics.minimumTouchTarget)
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(SUMotion.press.resolved(reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

/// A round glass button for a single symbol (an arrow to more detail). 44 pt to touch.
struct SUCircleButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.footnote.weight(.bold))
            .foregroundStyle(SUColor.textPrimary)
            .frame(width: 36, height: 36)
            .glassEffect(.regular.interactive(), in: Circle())
            .frame(width: SUMetrics.minimumTouchTarget, height: SUMetrics.minimumTouchTarget)
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.92 : 1)
            .animation(SUMotion.press.resolved(reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == SUPillButtonStyle {
    static var suPill: SUPillButtonStyle { SUPillButtonStyle() }
    static var suPillProminent: SUPillButtonStyle { SUPillButtonStyle(isProminent: true) }
}

extension ButtonStyle where Self == SUCircleButtonStyle {
    static var suCircle: SUCircleButtonStyle { SUCircleButtonStyle() }
}

// MARK: - Action tiles

/// A square-shouldered glass tile for a primary action: the symbol in a small disc, the label
/// beneath. The prominent tile is bright glass with an inverted disc.
struct SUActionTile: View {
    let title: String
    let systemImage: String
    var isProminent = false
    let action: () -> Void

    @ScaledMetric(relativeTo: .footnote) private var height: CGFloat = 96

    var body: some View {
        Button(action: action) {
            VStack(spacing: SUSpacing.sm) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(isProminent ? Color.white : Color.black)
                    .frame(width: 30, height: 30)
                    .background(isProminent ? Color.black : Color.white, in: Circle())
                    .accessibilityHidden(true)
                Text(title)
                    .font(SUFont.metadata.weight(.semibold))
                    .foregroundStyle(isProminent ? Color.black : SUColor.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
            .padding(.horizontal, SUSpacing.xs)
            .frame(maxWidth: .infinity, minHeight: height)
            .contentShape(RoundedRectangle(cornerRadius: SURadius.tile, style: .continuous))
        }
        .buttonStyle(SUTileButtonStyle(isProminent: isProminent))
    }
}

private struct SUTileButtonStyle: ButtonStyle {
    let isProminent: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .glassEffect(isProminent ? .regular.tint(.white).interactive() : .regular.interactive(),
                         in: RoundedRectangle(cornerRadius: SURadius.tile, style: .continuous))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(SUMotion.press.resolved(reduceMotion: reduceMotion), value: configuration.isPressed)
            .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.5), trigger: configuration.isPressed) { _, isPressed in isPressed }
    }
}
