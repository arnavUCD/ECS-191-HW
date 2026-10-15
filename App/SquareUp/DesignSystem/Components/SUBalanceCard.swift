import SwiftUI

/// What the wallet's pocket says: the person's net personal position in plain language — a
/// statement pill, the figure with its whole units leading, and how many groups it spans. An
/// optional accessory (a "see all" button) sits beside the statement.
///
/// Square Up tracks obligations, not stored money, so this never presents a "balance" like a bank
/// account — it states who owes whom. Always rendered dark, on the pocket.
struct SUBalanceCard<Accessory: View>: View {
    let position: NetPosition
    let groupCount: Int
    var footnote: String?
    @ViewBuilder var accessory: Accessory

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: SUSpacing.xs) {
            HStack(alignment: .center, spacing: SUSpacing.xs) {
                SUTagPill(title: statement, systemImage: statementSymbol)
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityHidden(true)
                Spacer(minLength: SUSpacing.xs)
                accessory
            }
            SUAmountView(money: position.net.magnitude, style: .hero, minimumScaleFactor: 0.4, emphasizesWholeUnits: true)
                .accessibilityLabel(heroAccessibilityLabel)
                .padding(.top, SUSpacing.xs)
            Text(groupCountText)
                .font(SUFont.supporting)
                .foregroundStyle(SUColor.textSecondary)
            if let footnote {
                Text(footnote)
                    .font(SUFont.metadata)
                    .foregroundStyle(SUColor.textSecondary)
                    .padding(.top, SUSpacing.xxs)
            }
        }
        .padding(.horizontal, SUSpacing.lg)
        .padding(.top, SUSpacing.lg)
        .padding(.bottom, SUSpacing.lg + SUSpacing.xxs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
    }

    private var statement: String {
        switch position.direction {
        case .owed: String(localized: "You are owed")
        case .owe: String(localized: "You owe")
        case .square: String(localized: "You're all square")
        }
    }

    private var statementSymbol: String {
        switch position.direction {
        case .owed: "arrow.down.left.circle.fill"
        case .owe: "arrow.up.right.circle.fill"
        case .square: "checkmark.seal.fill"
        }
    }

    private var groupCountText: String {
        Inflect.string("Across ^[\(groupCount) group](inflect: true)")
    }

    private var heroAccessibilityLabel: String {
        let spoken = MoneyFormatting.spokenString(position.net.magnitude)
        switch position.direction {
        case .owed: return String(localized: "Overall, you are owed \(spoken)")
        case .owe: return String(localized: "Overall, you owe \(spoken)")
        case .square: return String(localized: "You're all square. Nobody owes anything.")
        }
    }
}

extension SUBalanceCard where Accessory == EmptyView {
    init(position: NetPosition, groupCount: Int, footnote: String? = nil) {
        self.init(position: position, groupCount: groupCount, footnote: footnote) { EmptyView() }
    }
}

/// The two sides of what's open — owed to you and what you owe — with a split meter and a sentence
/// saying how it divides.
struct SUOpenBalancesCard<Accessory: View>: View {
    let position: NetPosition
    @ViewBuilder var accessory: Accessory
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: SUSpacing.md) {
            HStack {
                Text(String(localized: "Open balances"))
                    .font(SUFont.cardTitle)
                    .foregroundStyle(SUColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: SUSpacing.xs)
                accessory
            }
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: SUSpacing.md))
                : AnyLayout(HStackLayout(alignment: .top, spacing: SUSpacing.lg))
            layout {
                figure(title: String(localized: "Owed to you"), money: position.owedToYou) {
                    Capsule().fill(.white).frame(width: 14, height: 4)
                }
                figure(title: String(localized: "You owe"), money: position.youOwe) {
                    HStack(spacing: 2.5) {
                        ForEach(0..<3, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 0.8).fill(SUDusk.blush).frame(width: 1.6, height: 9)
                        }
                    }
                }
            }
            if let share = position.owedShare {
                SUSplitMeter(fraction: share)
                Text(shareSentence(share))
                    .font(SUFont.metadata)
                    .foregroundStyle(SUColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(SUSpacing.md + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { SUBevel(shape: RoundedRectangle(cornerRadius: SURadius.panel - 8, style: .continuous)) }
    }

    private func figure(title: String, money: Money, @ViewBuilder marker: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: SUSpacing.xxs) {
            HStack(spacing: 6) {
                marker().accessibilityHidden(true)
                Text(title).font(SUFont.metadata.weight(.medium)).foregroundStyle(SUColor.textSecondary)
            }
            SUAmountView(money: money, style: .large, emphasizesWholeUnits: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func shareSentence(_ share: Double) -> String {
        let percent = Int((share * 100).rounded())
        return percent >= 50
            ? String(localized: "\(percent)% of what's open is coming to you.")
            : String(localized: "\(100 - percent)% of what's open is what you owe.")
    }
}

extension SUOpenBalancesCard where Accessory == EmptyView {
    init(position: NetPosition) {
        self.init(position: position) { EmptyView() }
    }
}

#Preview("Pocket and open balances", traits: .sizeThatFitsLayout) {
    VStack(spacing: SUSpacing.md) {
        SUWallet(cardCount: 0) { _ in EmptyView() } pocket: {
            SUBalanceCard(position: NetPosition(owedToYou: Money(552.30), youOwe: Money(29.69)), groupCount: 4)
        }
        SUOpenBalancesCard(position: NetPosition(owedToYou: Money(552.30), youOwe: Money(29.69)))
    }
    .padding()
    .suScreenBackground()
    .squareUpTheme()
}
