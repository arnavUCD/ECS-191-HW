import SwiftUI

/// Natural-language quick entry. Produces a *draft*: every field is marked as suggested and
/// the person reviews payer, participants, amount, and split before anything is saved.
struct QuickEntrySheet: View {
    let model: ComposeExpenseModel

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var provider: AIProviderDescriptor?
    @State private var isWorking = false
    @State private var task: Task<Void, Never>?
    @FocusState private var isFocused: Bool

    private var examples: [String] {
        let names = model.members.filter { $0.id != model.currentUserID }.prefix(2).map(\.firstName)
        let others = names.isEmpty ? "Maya" : names.formatted(.list(type: .and))
        return [
            String(localized: "I paid $80 for dinner split with \(others)"),
            String(localized: "\(names.first ?? "Maya") paid 42.50 for groceries with me"),
        ]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SUSpacing.lg) {
                    Text(String(localized: "Describe the expense the way you'd text it. You'll check every detail before saving."))
                        .font(SUFont.supporting)
                        .foregroundStyle(SUColor.textSecondary)

                    TextField(String(localized: "I paid $84 for dinner with…"), text: $text, axis: .vertical)
                        .lineLimit(3...6)
                        .font(SUFont.body)
                        .focused($isFocused)
                        .padding(SUSpacing.md)
                        .suSurface(SUShape.compact)
                        .accessibilityIdentifier("quickEntry.text")

                    VStack(alignment: .leading, spacing: SUSpacing.xs) {
                        Text(String(localized: "Try"))
                            .font(SUFont.metadata.weight(.semibold))
                            .foregroundStyle(SUColor.textSecondary)
                        ForEach(examples, id: \.self) { example in
                            Button { text = example } label: {
                                Text(example)
                                    .font(SUFont.supporting)
                                    .multilineTextAlignment(.leading)
                                    .padding(.horizontal, SUSpacing.sm)
                                    .padding(.vertical, SUSpacing.xs)
                                    .frame(minHeight: SUMetrics.minimumTouchTarget)
                                    .suSurface(SUShape.control, elevated: true)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if let provider {
                        Label(provider.location.disclosure, systemImage: provider.location == .onDevice ? "apple.intelligence" : "iphone")
                            .font(SUFont.metadata)
                            .foregroundStyle(SUColor.textSecondary)
                            .accessibilityIdentifier("quickEntry.provider")
                    }
                }
                .padding(SUSpacing.screenMargin)
            }
            .suScreenBackground()
            .navigationTitle(String(localized: "Describe it"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel"), role: .cancel) { task?.cancel(); dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button(action: submit) {
                    HStack(spacing: SUSpacing.xs) {
                        if isWorking { ProgressView().tint(SUColor.onAccent) }
                        Text(isWorking ? String(localized: "Reading…") : String(localized: "Fill in expense"))
                    }
                }
                .buttonStyle(.suPrimary)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
                .padding(.horizontal, SUSpacing.screenMargin)
                .padding(.bottom, SUSpacing.xs)
                .accessibilityIdentifier("quickEntry.submit")
            }
        }
        .presentationDetents([.medium, .large])
        .task { provider = await environment.quickEntry.activeProvider() }
        .onAppear { isFocused = true }
        .onDisappear { task?.cancel() }
    }

    private func submit() {
        guard let currentUserID = model.currentUserID else { return }
        isWorking = true
        let members = model.members
        let currency = model.currency
        let input = text
        task = Task {
            let suggestion = await environment.quickEntry.suggest(
                from: input, members: members, currentUserID: currentUserID, currency: currency
            )
            guard !Task.isCancelled else { return }
            model.apply(suggestion)
            isWorking = false
            dismiss()
        }
    }
}
