import SwiftUI

/// The Home hero as a wallet: cards (the groups that need you) tucked into a stitched pocket that
/// holds your overall position. The cards rise out of the pocket when the screen first appears and
/// sink back as it scrolls away. Under Reduce Motion they simply sit in place.
///
/// Layout: the pocket's own content sets the height; the cards and the wallet's back panel are
/// drawn behind it, so the visible strip of each card stays tappable.
/// What the wallet is made of. Two versions are kept while choosing between them on a device:
/// change `current` to switch everywhere (the cards and their contents are the same in both).
enum SUWalletMaterial {
    /// Brown matte leather, like the Home reference (on trial).
    case leather
    /// The original: dark navy hide.
    case navy

    static let current: SUWalletMaterial = .leather // .navy for the original
}

struct SUWallet<Card: View, Pocket: View>: View {
    let cardCount: Int
    var isAnimated = true
    @ViewBuilder var card: (Int) -> Card
    @ViewBuilder var pocket: Pocket

    @ScaledMetric(relativeTo: .subheadline) private var peek: CGFloat = 62
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasRisen = false

    private var isRisen: Bool { hasRisen || !isAnimated || reduceMotion }

    private func restingOffset(_ index: Int) -> CGFloat { CGFloat(index) * peek }

    /// How far below its resting place a card starts, tucked in the pocket, before it rises.
    private func tuckedDepth(_ index: Int) -> CGFloat { peek * 0.85 + CGFloat(cardCount - index) * 8 }
    private var pocketTop: CGFloat { cardCount == 0 ? 0 : CGFloat(cardCount) * peek + 4 }

    var body: some View {
        // Plain values for the scroll transition, which runs outside the main actor.
        let sinkDepth = reduceMotion ? 0 : peek * 0.7
        return pocket
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                switch SUWalletMaterial.current {
                case .leather: SUWalletLeatherPocket()
                case .navy: SUWalletPocket()
                }
            }
            .padding(.top, pocketTop)
            .background(alignment: .top) {
                if cardCount > 0 {
                    ZStack(alignment: .top) {
                        Group {
                            switch SUWalletMaterial.current {
                            case .leather: SUWalletLeatherBack()
                            case .navy: SUWalletBack()
                            }
                        }
                        .padding(.top, peek * 0.42)
                        ForEach(0..<cardCount, id: \.self) { index in
                            card(index)
                                .frame(height: peek + 46)
                                .padding(.horizontal, 12)
                                .offset(y: restingOffset(index) + (isRisen ? 0 : tuckedDepth(index)))
                                .animation(reduceMotion ? nil : SUMotion.reveal.animation.delay(0.12 + Double(index) * 0.07), value: isRisen)
                                .scrollTransition(.interactive, axis: .vertical) { view, phase in
                                    // Leaving the top of the screen: the cards slip back into the pocket.
                                    view.offset(y: phase.value < 0 ? -phase.value * sinkDepth : 0)
                                }
                        }
                        // The shade where the cards slip into the pocket.
                        LinearGradient(colors: [.clear, .black.opacity(0.42)], startPoint: .top, endPoint: .bottom)
                            .frame(height: 16)
                            .padding(.horizontal, 12)
                            .offset(y: pocketTop - 16)
                            .allowsHitTesting(false)
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .onAppear { hasRisen = true }
            .environment(\.colorScheme, .dark)
    }
}

/// The pocket's shape: soft shoulders at the top, deep corners at the bottom.
private var walletShape: UnevenRoundedRectangle {
    UnevenRoundedRectangle(topLeadingRadius: 22, bottomLeadingRadius: SURadius.panel, bottomTrailingRadius: SURadius.panel,
                           topTrailingRadius: 22, style: .continuous)
}

/// The pocket front: dark navy hide with a fine grain, a stitched seam, a lit lip, and a soft
/// shadow beneath.
private struct SUWalletPocket: View {
    var body: some View {
        ZStack {
            walletShape.fill(LinearGradient(colors: [SUDusk.navy.mix(with: SUDusk.slate, by: 0.32), SUDusk.navy.mix(with: SUDusk.ink, by: 0.58)],
                                            startPoint: .top, endPoint: .bottom))
            SUGrain().clipShape(walletShape)
            walletShape.inset(by: 8).stroke(.white.opacity(0.13), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        }
        .overlay {
            walletShape.strokeBorder(LinearGradient(colors: [.white.opacity(0.3), .white.opacity(0.05), .black.opacity(0.25)],
                                                    startPoint: .top, endPoint: .bottom), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.45), radius: 18, y: 10)
        .accessibilityHidden(true)
    }
}

/// The wallet's back panel, visible beside and behind the cards.
private struct SUWalletBack: View {
    var body: some View {
        ZStack {
            walletShape.fill(LinearGradient(colors: [SUDusk.ink.mix(with: SUDusk.navy, by: 0.62), SUDusk.ink.mix(with: SUDusk.navy, by: 0.3)],
                                            startPoint: .top, endPoint: .bottom))
            SUGrain(density: 0.7).clipShape(walletShape)
        }
        .overlay { walletShape.strokeBorder(.white.opacity(0.12), lineWidth: 1) }
        .accessibilityHidden(true)
    }
}

// MARK: - Leather (on trial)

/// Brown matte leather: the hide's tones, the thread for its stitching.
private enum SULeather {
    static let lit = Color(red: 0.36, green: 0.25, blue: 0.20)
    static let body = Color(red: 0.27, green: 0.18, blue: 0.14)
    static let shade = Color(red: 0.17, green: 0.11, blue: 0.09)
    static let back = Color(red: 0.14, green: 0.09, blue: 0.07)
    static let thread = Color(red: 0.80, green: 0.64, blue: 0.48)
}

/// The pocket front in brown matte leather: a soft top-lit hide with a fine grain (no gloss), a
/// rolled lip along the top, a stitched seam, a debossed mark, and a soft shadow beneath.
private struct SUWalletLeatherPocket: View {
    var body: some View {
        ZStack {
            walletShape.fill(LinearGradient(colors: [SULeather.lit, SULeather.body, SULeather.shade], startPoint: .top, endPoint: .bottom))
            // Matte grain: denser and finer than the navy hide's, so the surface reads as leather.
            SUGrain(density: 2.2).clipShape(walletShape)
            // The rolled lip where the cards go in.
            walletShape.fill(LinearGradient(colors: [.white.opacity(0.1), .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.08)))
            walletShape.inset(by: 9).stroke(SULeather.thread.opacity(0.32), style: StrokeStyle(lineWidth: 1.1, lineCap: .round, dash: [4.5, 3.5]))
            // A small debossed mark in the lower corner: a pressed ring, shadowed above, lit below.
            Capsule()
                .strokeBorder(.black.opacity(0.35), lineWidth: 2)
                .overlay { Capsule().strokeBorder(.white.opacity(0.07), lineWidth: 1).offset(y: 1) }
                .frame(width: 34, height: 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, 26)
                .padding(.bottom, 20)
        }
        .overlay {
            walletShape.strokeBorder(LinearGradient(colors: [.white.opacity(0.16), .black.opacity(0.1), .black.opacity(0.3)],
                                                    startPoint: .top, endPoint: .bottom), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.5), radius: 18, y: 10)
        .accessibilityHidden(true)
    }
}

/// The leather wallet's back panel, darker, behind the cards.
private struct SUWalletLeatherBack: View {
    var body: some View {
        ZStack {
            walletShape.fill(LinearGradient(colors: [SULeather.back, SULeather.shade], startPoint: .top, endPoint: .bottom))
            SUGrain(density: 1.6).clipShape(walletShape)
        }
        .overlay { walletShape.strokeBorder(.white.opacity(0.08), lineWidth: 1) }
        .accessibilityHidden(true)
    }
}

/// A card's lacquer, chosen per group so a group always wears the same finish.
enum SUWalletFinish: CaseIterable {
    case rose, lilac, slate
    /// All square: a quiet navy.
    case calm

    private static let lacquers: [SUWalletFinish] = [.rose, .lilac, .slate]

    static func `for`(_ id: GroupID) -> SUWalletFinish {
        lacquers[id.stableBucket(count: lacquers.count)]
    }

    /// Finishes for a stack of cards: each group keeps its own finish unless the card behind it
    /// wears the same one, in which case it takes the next, so neighbours always differ.
    static func stack(_ ids: [GroupID]) -> [SUWalletFinish] {
        var result: [SUWalletFinish] = []
        for id in ids {
            var finish = Self.for(id)
            if let previous = result.last, previous == finish, let index = lacquers.firstIndex(of: finish) {
                finish = lacquers[(index + 1) % lacquers.count]
            }
            result.append(finish)
        }
        return result
    }

    var colors: [Color] {
        switch self {
        case .rose: [SUDusk.rose.mix(with: SUDusk.ink, by: 0.34), SUDusk.rose.mix(with: SUDusk.mauve, by: 0.2), SUDusk.blush.mix(with: SUDusk.rose, by: 0.45)]
        case .lilac: [SUDusk.mauve.mix(with: SUDusk.ink, by: 0.3), SUDusk.lilac.mix(with: SUDusk.rose, by: 0.3), SUDusk.lilac.mix(with: SUDusk.blush, by: 0.25)]
        case .slate: [SUDusk.slate.mix(with: SUDusk.ink, by: 0.42), SUDusk.slate.mix(with: SUDusk.navy, by: 0.05), SUDusk.slate.mix(with: SUDusk.lilac, by: 0.28)]
        case .calm: [SUDusk.navy, SUDusk.slate.mix(with: SUDusk.navy, by: 0.4), SUDusk.slate.mix(with: SUDusk.lilac, by: 0.2)]
        }
    }
}

/// A card in the wallet: lacquered, brushed, with a moving sheen and a lit rim. White content.
struct SUWalletCard<Content: View>: View {
    var finish: SUWalletFinish
    @ViewBuilder var content: Content

    private let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)

    var body: some View {
        content
            .padding(.horizontal, 14)
            .padding(.top, 11)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background { face }
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.12), .white.opacity(0.04)],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.38), radius: 9, y: -3)
            .environment(\.colorScheme, .dark)
    }

    private var face: some View {
        ZStack {
            LinearGradient(colors: finish.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            SUBrushedMetal()
            LinearGradient(stops: [
                .init(color: .clear, location: 0.22), .init(color: .white.opacity(0.24), location: 0.42),
                .init(color: .white.opacity(0.05), location: 0.52), .init(color: .clear, location: 0.7),
            ], startPoint: .topLeading, endPoint: .bottomTrailing)
            // Keeps the label along the top legible on the light end of the lacquer.
            LinearGradient(colors: [.black.opacity(0.22), .clear], startPoint: .top, endPoint: .center)
        }
        .accessibilityHidden(true)
    }
}

/// An empty slot in the wallet: a dashed outline where a group's card will go.
struct SUWalletPlaceholderCard<Content: View>: View {
    @ViewBuilder var content: Content
    private let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)

    var body: some View {
        content
            .padding(.horizontal, 14)
            .padding(.top, 11)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.white.opacity(0.05), in: shape)
            .overlay { shape.strokeBorder(.white.opacity(0.28), style: StrokeStyle(lineWidth: 1.2, dash: [6, 5])) }
    }
}

/// Fine vertical brushing for metal and lacquer. Static and decorative.
private struct SUBrushedMetal: View {
    var body: some View {
        Canvas { context, size in
            var x: CGFloat = 0
            var index = 0
            while x < size.width {
                let color: Color = index.isMultiple(of: 2) ? .white.opacity(0.018) : .black.opacity(0.024)
                context.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(color))
                x += [1.5, 2.5, 1, 3, 2][index % 5]
                index += 1
            }
        }
        .drawingGroup()
        .allowsHitTesting(false)
    }
}

#Preview("Wallet") {
    ScrollView {
        SUWallet(cardCount: 3, isAnimated: true) { index in
            SUWalletCard(finish: [SUWalletFinish.rose, .lilac, .slate][index]) {
                HStack {
                    Text(["Tahoe Ski Weekend", "Coastal Weekend Trip", "Apartment 4B"][index]).font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(["+$537.30", "+$377.00", "−$29.69"][index]).font(.subheadline.weight(.semibold).monospacedDigit())
                }
                .foregroundStyle(.white)
            }
        } pocket: {
            SUBalanceCard(position: NetPosition(owedToYou: Money(914.30), youOwe: Money(29.69)), groupCount: 4)
        }
        .padding()
    }
    .suScreenBackground()
    .squareUpTheme()
}
