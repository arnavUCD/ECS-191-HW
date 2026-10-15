import SwiftUI

/// A six-digit verification code as six boxes. One real text field sits underneath, so iOS offers
/// the code from Messages (`.oneTimeCode`), pasting works (only digits are kept, the first six),
/// and "focus" moves box to box as digits arrive. VoiceOver reads it as one field: "Verification
/// code, 3 of 6 digits entered" — never the digits themselves.
struct SUCodeField: View {
    @Binding var code: String
    var length = 6
    var isInvalid = false
    var identifier = "code.field"
    var isFocused: FocusState<Bool>.Binding
    var onComplete: (String) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title) private var boxHeight: CGFloat = 58

    var body: some View {
        ZStack {
            TextField("", text: Binding(get: { code }, set: { accept($0) }))
                .textContentType(.oneTimeCode)
                .keyboardType(.numberPad)
                .focused(isFocused)
                .foregroundStyle(.clear)
                .tint(.clear)
                .frame(maxWidth: .infinity, minHeight: boxHeight)
                .accessibilityLabel(String(localized: "Verification code"))
                .accessibilityValue(String(localized: "\(code.count) of \(length) digits entered"))
                .accessibilityIdentifier(identifier)
            HStack(spacing: SUSpacing.xs) {
                ForEach(0..<length, id: \.self) { index in box(index) }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .onTapGesture { isFocused.wrappedValue = true }
        .modifier(SUShake(trigger: isInvalid, isEnabled: !reduceMotion))
    }

    private func box(_ index: Int) -> some View {
        let digits = Array(code)
        let isCurrent = isFocused.wrappedValue && index == min(code.count, length - 1)
        let border: Color = isInvalid ? SUColor.negative : .white.opacity(isCurrent ? 0.55 : 0.12)
        return Text(index < digits.count ? String(digits[index]) : "")
            .font(.system(.title, design: .rounded, weight: .semibold).monospacedDigit())
            .foregroundStyle(SUColor.textPrimary)
            .frame(maxWidth: .infinity, minHeight: boxHeight)
            .background(.white.opacity(isCurrent ? 0.11 : 0.07), in: SUShape.compact)
            .overlay { SUShape.compact.strokeBorder(border, lineWidth: isCurrent ? 1.5 : 1) }
            .animation(SUMotion.press.resolved(reduceMotion: reduceMotion), value: isCurrent)
    }

    /// Digits only, at most `length`; the last digit completes the code.
    private func accept(_ text: String) {
        let digits = String(text.filter { $0.isASCII && $0.isNumber }.prefix(length))
        guard digits != code else { return }
        code = digits
        if digits.count == length { onComplete(digits) }
    }
}

/// A short horizontal shake for a wrong code (skipped with Reduce Motion; the message says it too).
private struct SUShake: ViewModifier {
    let trigger: Bool
    let isEnabled: Bool

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: 0.0, trigger: trigger) { view, offset in
            view.offset(x: offset)
        } keyframes: { _ in
            KeyframeTrack {
                if isEnabled && trigger {
                    LinearKeyframe(-8, duration: 0.06)
                    LinearKeyframe(8, duration: 0.08)
                    LinearKeyframe(-5, duration: 0.08)
                    LinearKeyframe(0, duration: 0.06)
                } else {
                    LinearKeyframe(0, duration: 0.01)
                }
            }
        }
    }
}

#Preview("Code field") {
    @Previewable @State var code = "123"
    @Previewable @FocusState var focused: Bool
    SUAuthScaffold {
        SUCodeField(code: $code, isFocused: $focused)
    }
}
