import SwiftUI

// MARK: - Stats

/// A capsule of facts, each a symbol and a value ("4 members · 5 expenses · $998.40").
struct SUStatsStrip: View {
    struct Item: Hashable {
        let systemImage: String
        let text: String
    }

    let items: [Item]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: SUSpacing.sm + 2) { labels }
                .padding(.horizontal, SUSpacing.md)
                .frame(minHeight: 40)
                .suSurface(Capsule())
            // Narrow: the same facts without their symbols, separated by dots.
            Text(items.map(\.text).joined(separator: "  ·  "))
                .font(SUFont.metadata.weight(.semibold))
                .foregroundStyle(SUColor.textPrimary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, SUSpacing.md)
                .frame(minHeight: 40)
                .suSurface(Capsule())
            VStack(alignment: .leading, spacing: SUSpacing.xs) { labels }
                .padding(.horizontal, SUSpacing.md)
                .padding(.vertical, SUSpacing.sm)
                .suSurface(SUShape.compact)
        }
        .accessibilityElement(children: .combine)
    }

    private var labels: some View {
        ForEach(items, id: \.self) { item in
            Label(item.text, systemImage: item.systemImage)
                .font(SUFont.metadata.weight(.semibold))
                .labelStyle(SUStatLabelStyle())
                .lineLimit(1)
                .fixedSize()
        }
    }
}

private struct SUStatLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.foregroundStyle(SUColor.textSecondary)
            configuration.title.foregroundStyle(SUColor.textPrimary)
        }
    }
}

/// How what's open divides between money coming to you and money you owe: a lit bar for the
/// first, a run of ticks for the second, and a knob where they meet. Always paired with the two
/// figures and a sentence, so it never carries meaning alone.
struct SUSplitMeter: View {
    /// The share owed to you, 0…1.
    let fraction: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        GeometryReader { proxy in
            let knob: CGFloat = 16
            let width = proxy.size.width
            let target = shown || reduceMotion ? fraction : 0.5
            let split = min(max(width * target, knob / 2), width - knob / 2)
            ZStack(alignment: .leading) {
                Canvas { context, size in
                    var x = split + knob / 2 + 4
                    while x < size.width - 1 {
                        context.fill(Path(roundedRect: CGRect(x: x, y: 3, width: 1.6, height: size.height - 6), cornerRadius: 0.8),
                                     with: .color(SUDusk.blush.opacity(0.8)))
                        x += 5
                    }
                }
                Capsule()
                    .fill(LinearGradient(colors: [.white.opacity(0.7), .white], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(0, split - 2), height: 8)
                Circle()
                    .fill(.white)
                    .frame(width: knob, height: knob)
                    .overlay { Circle().fill(SUDusk.rose).frame(width: 6, height: 6) }
                    .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                    .offset(x: split - knob / 2)
            }
        }
        .frame(height: 20)
        .onAppear {
            guard !shown else { return }
            withAnimation(SUMotion.reveal.animation.delay(0.25)) { shown = true }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Payer → recipient

/// A circle that flows into a tail, like a drop pulling away: the payer's avatar sits in the head
/// and the tail carries the direction of the money. Drawn as one union so translucent fills
/// never double up.
nonisolated struct SUBlobShape: Shape {
    /// The tail's height as a share of the head's diameter.
    var tailRatio: CGFloat = 0.6

    func path(in rect: CGRect) -> Path {
        let diameter = min(rect.height, rect.width)
        let radius = diameter / 2
        let center = CGPoint(x: rect.minX + radius, y: rect.midY)
        let tail = diameter * tailRatio
        let top = rect.midY - tail / 2
        let bottom = rect.midY + tail / 2
        let head = Path(ellipseIn: CGRect(x: rect.minX, y: rect.midY - radius, width: diameter, height: diameter))
        guard rect.maxX > center.x + radius else { return head }
        let tailPath = Path(roundedRect: CGRect(x: center.x, y: top, width: rect.maxX - center.x, height: tail), cornerRadius: tail / 2)

        // A fillet of this radius rolls between the head and the tail's top edge.
        let fillet = radius * 0.55
        let neckX = center.x + sqrt(pow(radius + fillet, 2) - pow(tail / 2 + fillet, 2))
        let filletCenter = CGPoint(x: neckX, y: top - fillet)
        let scale = radius / (radius + fillet)
        let tangent = CGPoint(x: center.x + (filletCenter.x - center.x) * scale, y: center.y + (filletCenter.y - center.y) * scale)
        // The head's tangent at that point, extended to the tail's edge, is the curve's control point.
        var direction = CGVector(dx: center.y - tangent.y, dy: tangent.x - center.x)
        if direction.dx < 0 { direction = CGVector(dx: -direction.dx, dy: -direction.dy) }
        let reach = direction.dy == 0 ? 0 : (top - tangent.y) / direction.dy
        let control = CGPoint(x: tangent.x + direction.dx * reach, y: top)

        var neck = Path()
        neck.move(to: tangent)
        neck.addQuadCurve(to: CGPoint(x: neckX, y: top), control: control)
        neck.addLine(to: CGPoint(x: neckX, y: bottom))
        neck.addQuadCurve(to: CGPoint(x: tangent.x, y: 2 * center.y - tangent.y), control: CGPoint(x: control.x, y: bottom))
        neck.closeSubpath()
        return head.union(tailPath).union(neck)
    }
}

/// Who pays whom: the payer in the head of a drop whose tail points at the recipient, with their
/// names beneath when the context needs them. Names are always nearby; the mark alone is never
/// the only identity.
struct SUTransferMark: View {
    let payer: Member
    let recipient: Member
    var currentUserID: MemberID?
    var showsNames = false

    private let avatar: SUAvatar.Size = .medium
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1
    private var head: CGFloat { avatar.diameter * min(scale, 1.6) + 8 }

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            VStack(spacing: SUSpacing.xs) {
                ZStack(alignment: .leading) {
                    SUBlobShape()
                        .fill(SUDusk.ink.opacity(0.78))
                        .overlay { SUBlobShape().stroke(.white.opacity(0.12), lineWidth: 1) }
                        .frame(width: head + 40, height: head)
                    SUAvatar(member: payer, size: avatar, isCurrentUser: payer.id == currentUserID)
                        .padding(4)
                    HStack(spacing: 5) {
                        Circle().fill(SUColor.textPrimary).frame(width: 5, height: 5)
                        Image(systemName: "arrow.right").font(.caption.weight(.bold)).foregroundStyle(SUColor.textPrimary)
                    }
                    .padding(.leading, head + 6)
                }
                if showsNames { name(payer) }
            }
            VStack(spacing: SUSpacing.xs) {
                SUAvatar(member: recipient, size: avatar, isCurrentUser: recipient.id == currentUserID)
                    .padding(4)
                    .background(Circle().fill(SUDusk.ink.opacity(0.78)))
                    .overlay { Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1) }
                if showsNames { name(recipient) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(payer.displayName) pays \(recipient.displayName)"))
    }

    private func name(_ member: Member) -> some View {
        Text(member.id == currentUserID ? String(localized: "You") : member.firstName)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(SUColor.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, SUSpacing.xs)
            .frame(minHeight: 20)
            .background(SUDusk.ink.opacity(0.78), in: Capsule())
            .fixedSize()
    }
}

#Preview("Panels") {
    let members = SampleLedger.make(referenceDate: .now).members.values.sorted { $0.displayName < $1.displayName }
    ScrollView {
        VStack(spacing: SUSpacing.lg) {
            SUHeadline(primary: "Good morning, Riley", secondary: "Here's where everyone stands.")
            SUCoverPanel(palette: .positive, symbol: "beach.umbrella") {
                SUCoverChip(lead: .readout("3"), title: "Payments", subtitle: "to settle")
                    .frame(maxWidth: .infinity, alignment: .center)
                SUAvatarCluster(members: Array(members.prefix(5)), currentUserID: members[0].id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                SUTagPill(title: "Shared", systemImage: "person.2")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            } content: {
                VStack(spacing: SUSpacing.sm) {
                    Text("Coastal Weekend Trip").font(.title2.weight(.semibold)).foregroundStyle(SUColor.textPrimary)
                    SUStatsStrip(items: [.init(systemImage: "person.2", text: "4"), .init(systemImage: "receipt", text: "5"), .init(systemImage: "sum", text: "$998.40")])
                }
            }
            SUTabbedPanel(material: .surface) {
                Text("Waiting for you").font(SUFont.chip).foregroundStyle(SUColor.textPrimary)
            } content: {
                Text("Alex reported paying you $417.10 through Venmo.").padding(SUSpacing.md)
            }
            HStack(spacing: SUSpacing.sm) {
                SUActionTile(title: "Add expense", systemImage: "plus", isProminent: true) {}
                SUActionTile(title: "Scan receipt", systemImage: "doc.viewfinder") {}
                SUActionTile(title: "Settle up", systemImage: "checkmark") {}
            }
            SUSplitMeter(fraction: 0.82)
            SUTransferMark(payer: members[0], recipient: members[1], currentUserID: members[0].id, showsNames: true)
        }
        .padding()
    }
    .suScreenBackground()
    .squareUpTheme()
}
