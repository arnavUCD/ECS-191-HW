import SwiftUI

/// Square Up's logo: the tilted square and "up". Light artwork, for the dusk backdrop.
struct SUBrandMark: View {
    var width: CGFloat = 120

    var body: some View {
        Image(.brandLogo)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: width)
            .accessibilityLabel(Text(verbatim: "Square Up"))
            .accessibilityAddTraits(.isHeader)
            .accessibilityRemoveTraits(.isImage)
    }
}

/// The account screens' layout over the dusk backdrop: content from the top (a large title, then
/// the form), and an optional footer resting at the bottom. Scrolls when the keyboard or a large
/// text size needs room. Always dark, whatever the system appearance, so the gradient and its
/// text keep their contrast. Content rises in once on appear unless motion is off.
struct SUAuthScaffold<Content: View, Footer: View>: View {
    var backdrop: SUDuskBackdrop.Style
    var isAnimated: Bool
    var content: Content
    var footer: Footer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false

    init(backdrop: SUDuskBackdrop.Style = .calm, isAnimated: Bool = true,
         @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer = { EmptyView() }) {
        self.backdrop = backdrop
        self.isAnimated = isAnimated
        self.content = content()
        self.footer = footer()
    }

    private var isRisen: Bool { hasAppeared || !isAnimated || reduceMotion }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: SUSpacing.lg) { content }
                        .opacity(isRisen ? 1 : 0)
                        .offset(y: isRisen ? 0 : 18)
                    Spacer(minLength: SUSpacing.xl)
                    footer
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, SUSpacing.xl)
                .padding(.top, SUSpacing.sm)
                .padding(.bottom, SUSpacing.xs)
                .frame(maxWidth: SUMetrics.readableWidth)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .top)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.basedOnSize)
        }
        .background { SUDuskBackdrop(style: backdrop, isAnimated: isAnimated).ignoresSafeArea() }
        .suDuskAppearance()
        .onAppear {
            guard !hasAppeared else { return }
            withAnimation(SUMotion.reveal.animation.delay(0.05)) { hasAppeared = true }
        }
    }
}

extension View {
    /// Dusk screens are always dark: tokens resolve dark and the status bar and keyboard follow.
    func suDuskAppearance() -> some View {
        environment(\.colorScheme, .dark).preferredColorScheme(.dark)
    }
}

/// The large title and one-line explanation at the top of an account screen. Titles may break
/// across lines ("Hey,\nwelcome back"); the size follows Dynamic Type.
struct SUAuthHeader: View {
    var symbol: String?
    let title: String
    var subtitle: String?
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 40

    var body: some View {
        VStack(alignment: .leading, spacing: SUSpacing.sm) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(SUColor.textPrimary)
                    .frame(width: 48, height: 48)
                    .glassEffect(.regular, in: Circle())
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.system(size: titleSize, weight: .bold))
                .kerning(-0.6)
                .foregroundStyle(SUColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .font(SUFont.body)
                    .foregroundStyle(SUColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, SUSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The shared look of an account field: a leading symbol, the label as the placeholder (it moves
/// up, small, once there's text), a hairline that brightens on focus, and the problem beneath.
private struct SUAuthFieldChrome<Input: View, Trailing: View>: View {
    let symbol: String
    let label: String
    let hasText: Bool
    let isFocused: Bool
    let issue: String?
    @ViewBuilder var input: Input
    @ViewBuilder var trailing: Trailing
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var border: Color {
        if issue != nil { return SUColor.negative }
        return .white.opacity(isFocused ? 0.42 : 0.1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SUSpacing.xxs) {
            HStack(spacing: SUSpacing.sm) {
                Image(systemName: symbol)
                    .font(.body)
                    .foregroundStyle(isFocused ? SUColor.textPrimary : SUColor.textSecondary)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    if hasText {
                        Text(label)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(SUColor.textSecondary)
                            .transition(.opacity.combined(with: .offset(y: 4)))
                            .accessibilityHidden(true)
                    }
                    input
                }
                trailing
            }
            .padding(.leading, SUSpacing.md)
            .padding(.trailing, SUSpacing.xxs)
            .frame(minHeight: 58)
            .background(.white.opacity(isFocused ? 0.1 : 0.07), in: SUShape.compact)
            .overlay { SUShape.compact.strokeBorder(border, lineWidth: 1) }
            .animation(SUMotion.press.resolved(reduceMotion: reduceMotion), value: isFocused)
            .animation(SUMotion.reveal.resolved(reduceMotion: reduceMotion), value: hasText)
            if let issue { SUFieldIssue(text: issue) }
        }
    }
}

/// An account text field: symbol, label-as-placeholder, and its validation message.
struct SUFormField<Field: Hashable>: View {
    let label: String
    @Binding var text: String
    var symbol = "character.cursor.ibeam"
    var contentType: UITextContentType?
    var keyboard: UIKeyboardType = .default
    var capitalization: TextInputAutocapitalization = .never
    var submitLabel: SubmitLabel = .next
    var issue: String?
    var identifier: String
    var focus: FocusState<Field?>.Binding
    var field: Field
    var onSubmit: () -> Void = {}

    var body: some View {
        SUAuthFieldChrome(symbol: symbol, label: label, hasText: !text.isEmpty, isFocused: focus.wrappedValue == field, issue: issue) {
            TextField(label, text: $text, prompt: Text(label).foregroundStyle(SUColor.textTertiary))
                .textContentType(contentType)
                .keyboardType(keyboard)
                .textInputAutocapitalization(capitalization)
                .autocorrectionDisabled()
                .submitLabel(submitLabel)
                .focused(focus, equals: field)
                .onSubmit(onSubmit)
                .font(SUFont.body)
                .foregroundStyle(SUColor.textPrimary)
                .padding(.trailing, SUSpacing.sm)
                .accessibilityLabel(label)
                .accessibilityHint(issue ?? "")
                .accessibilityIdentifier(identifier)
        } trailing: {
            EmptyView()
        }
    }
}

/// A password field with a Show/Hide control. VoiceOver hears "Show password", never the password.
struct SUPasswordField<Field: Hashable>: View {
    let label: String
    @Binding var text: String
    var symbol = "lock"
    var contentType: UITextContentType = .password
    var submitLabel: SubmitLabel = .go
    var issue: String?
    var identifier: String
    var focus: FocusState<Field?>.Binding
    var field: Field
    var onSubmit: () -> Void = {}
    @State private var isRevealed = false

    var body: some View {
        SUAuthFieldChrome(symbol: symbol, label: label, hasText: !text.isEmpty, isFocused: focus.wrappedValue == field, issue: issue) {
            Group {
                if isRevealed {
                    TextField(label, text: $text, prompt: Text(label).foregroundStyle(SUColor.textTertiary))
                } else {
                    SecureField(label, text: $text, prompt: Text(label).foregroundStyle(SUColor.textTertiary))
                }
            }
            .textContentType(contentType)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(submitLabel)
            .focused(focus, equals: field)
            .onSubmit(onSubmit)
            .font(SUFont.body)
            .foregroundStyle(SUColor.textPrimary)
            .accessibilityLabel(label)
            .accessibilityHint(issue ?? "")
            .accessibilityIdentifier(identifier)
        } trailing: {
            Button {
                isRevealed.toggle()
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
                    .font(.body)
                    .foregroundStyle(SUColor.textSecondary)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: SUMetrics.minimumTouchTarget, height: SUMetrics.minimumTouchTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isRevealed ? String(localized: "Hide password") : String(localized: "Show password"))
            .accessibilityIdentifier("\(identifier).reveal")
        }
    }
}

/// "New to Square Up? Create account": a quiet question with the action in bold, 44 pt tall.
struct SUAuthSwitchLink: View {
    let prompt: String
    let action: String
    let perform: () -> Void

    var body: some View {
        Button(action: perform) {
            Text("\(Text(prompt).foregroundStyle(SUColor.textSecondary)) \(Text(action).fontWeight(.semibold).foregroundStyle(SUColor.textPrimary))")
                .font(SUFont.supporting)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: SUMetrics.minimumTouchTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(action)
        .accessibilityHint(prompt)
    }
}

/// A small centered text action on an account screen ("Forgot password?"), 44 pt tall.
struct SUAuthQuietLink: View {
    let title: String
    let perform: () -> Void

    var body: some View {
        Button(title, action: perform)
            .font(SUFont.supporting.weight(.medium))
            .foregroundStyle(SUColor.textSecondary)
            .frame(maxWidth: .infinity, minHeight: SUMetrics.minimumTouchTarget)
            .contentShape(Rectangle())
            .buttonStyle(.plain)
    }
}

/// A validation message beneath a field.
struct SUFieldIssue: View {
    let text: String

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "exclamationmark.circle.fill")
        }
        .font(SUFont.metadata)
        .foregroundStyle(SUColor.negative)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A result or problem on an account screen: symbol, words, and tone together.
struct SUInlineStatus: View {
    let text: String
    var isProblem = true
    var identifier = "auth.notice"

    var body: some View {
        Label {
            Text(text).foregroundStyle(SUColor.textPrimary)
        } icon: {
            Image(systemName: isProblem ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isProblem ? SUColor.warning : SUColor.positive)
        }
        .font(SUFont.supporting)
        .padding(SUSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((isProblem ? SUColor.warning : SUColor.positive).opacity(0.12), in: SUShape.control)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(isProblem ? String(localized: "Problem: \(text)") : text))
        .accessibilityIdentifier(identifier)
    }
}

/// A primary button's label that shows progress in words while a request runs.
struct SUProgressLabel: View {
    let title: String
    let workingTitle: String
    let isWorking: Bool

    var body: some View {
        HStack(spacing: SUSpacing.xs) {
            if isWorking { ProgressView().tint(Color.secondary) }
            Text(isWorking ? workingTitle : title)
        }
    }
}

/// A quiet text action inside an account panel (44 pt tall).
struct SUTextActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(SUFont.button)
            .foregroundStyle(isEnabled ? SUColor.textPrimary : SUColor.textTertiary)
            .frame(maxWidth: .infinity, minHeight: SUMetrics.minimumTouchTarget)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

extension ButtonStyle where Self == SUTextActionStyle {
    static var suText: SUTextActionStyle { SUTextActionStyle() }
}

#Preview("Account components") {
    @Previewable @FocusState var focus: Int?
    @Previewable @State var email = "maya@example.com"
    @Previewable @State var password = "secret"
    SUAuthScaffold {
        SUAuthHeader(title: "Let's get\nstarted")
        SUFormField(label: "Email", text: $email, symbol: "envelope", identifier: "preview.email", focus: $focus, field: 0)
        SUPasswordField(label: "Password", text: $password, issue: "At least 8 characters", identifier: "preview.password", focus: $focus, field: 1)
        SUInlineStatus(text: "You're offline. Connect and try again.")
        Button("Create account") {}.buttonStyle(.suGlassPrimary)
    } footer: {
        SUAuthSwitchLink(prompt: "Already have an account?", action: "Sign in") {}
    }
}
