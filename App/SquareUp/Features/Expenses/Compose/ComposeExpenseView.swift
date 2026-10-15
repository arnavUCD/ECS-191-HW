import SwiftUI

/// The Add Expense sheet: a focused, staged flow (amount → split → review).
struct ComposeExpenseView: View {
    let request: ComposerRequest
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        ComposeExpenseScreen(request: request, environment: environment)
    }
}

private struct ComposeExpenseScreen: View {
    let environment: AppEnvironment
    @State private var model: ComposeExpenseModel
    @State private var isConfirmingDiscard = false
    @State private var isShowingQuickEntry: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(request: ComposerRequest, environment: AppEnvironment) {
        self.environment = environment
        _model = State(initialValue: ComposeExpenseModel(request: request))
        _isShowingQuickEntry = State(initialValue: request.mode == .quickEntry)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let error = model.loadError {
                    SUErrorState(
                        title: String(localized: "Couldn't open your groups"),
                        message: ComposeExpenseModel.message(for: error)
                    ) { Task { await model.load(from: environment.ledger) } }
                } else if model.snapshot == nil {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.groups.isEmpty {
                    SUEmptyState(
                        systemImage: "person.3.sequence.fill",
                        title: String(localized: "Join or create a group first"),
                        message: String(localized: "Expenses belong to a group so everyone involved can see them.")
                    )
                } else {
                    stepContent
                }
            }
            .suScreenBackground()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
        }
        .task { await model.load(from: environment.ledger) }
        .interactiveDismissDisabled(model.hasChanges && model.saveState != .saved)
        .confirmationDialog(
            String(localized: "Discard this expense?"),
            isPresented: $isConfirmingDiscard,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Discard"), role: .destructive) { dismiss() }
            Button(String(localized: "Keep editing"), role: .cancel) {}
        } message: {
            Text("Nothing has been saved yet.")
        }
        .sheet(isPresented: $isShowingQuickEntry) {
            QuickEntrySheet(model: model)
        }
        .sensoryFeedback(.warning, trigger: model.rejectionCount)
        .sensoryFeedback(.success, trigger: model.saveState) { _, new in new == .saved }
        .sensoryFeedback(.error, trigger: model.saveState) { _, new in
            if case .failed = new { true } else { false }
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        ZStack {
            switch model.step {
            case .amount:
                AmountStepView(model: model) { isShowingQuickEntry = true }
                    .transition(stepTransition)
            case .split:
                SplitStepView(model: model)
                    .transition(stepTransition)
            case .review:
                ReviewStepView(model: model) {
                    Task {
                        if await model.save(to: environment.ledger, now: environment.now) {
                            try? await Task.sleep(for: .milliseconds(reduceMotion ? 500 : 900))
                            dismiss()
                        }
                    }
                }
                .transition(stepTransition)
            }
        }
        .suAnimation(.reveal, value: model.step)
    }

    private var stepTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }

    private var title: String {
        switch model.step {
        case .amount: if model.isEditing { String(localized: "Edit expense") } else { String(localized: "Add expense") }
        case .split: String(localized: "Who paid and who shares")
        case .review: String(localized: "Review")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if model.step == .amount || model.saveState == .saved {
                Button(String(localized: "Cancel"), systemImage: "xmark", role: .cancel) {
                    if model.hasChanges && model.saveState != .saved { isConfirmingDiscard = true } else { dismiss() }
                }
                .accessibilityIdentifier("compose.cancel")
            } else {
                Button(String(localized: "Back"), systemImage: "chevron.backward") {
                    withSUAnimation(.reveal, reduceMotion: reduceMotion) { model.goBack() }
                }
                .disabled(model.saveState == .saving)
            }
        }
        ToolbarItem(placement: .principal) {
            StepIndicator(step: model.step)
        }
    }
}

/// Three capsules showing progress through the flow.
private struct StepIndicator: View {
    let step: ComposeExpenseModel.Step

    var body: some View {
        HStack(spacing: SUSpacing.xxs) {
            ForEach(ComposeExpenseModel.Step.allCases, id: \.self) { item in
                Capsule()
                    .fill(item <= step ? Color.white : SUColor.glassFillPressed)
                    .frame(width: item == step ? 22 : 8, height: 6)
            }
        }
        .suAnimation(.reconcile, value: step)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Step \(step.rawValue + 1) of 3"))
    }
}

#Preview("Compose") {
    ComposeExpenseView(request: ComposerRequest())
        .environment(AppEnvironment.preview(.standard))
        .environment(AppRouter())
}
