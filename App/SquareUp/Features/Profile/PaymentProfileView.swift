import SwiftUI

nonisolated struct PaymentProfileSummary: Equatable, Sendable {
    let owner: Member
    let destinations: [PaymentDestination]
    /// Destinations referenced by payments that aren't finished, keyed for the change warning.
    let inUse: Set<PaymentDestinationID>

    static func make(from snapshot: LedgerSnapshot) throws -> PaymentProfileSummary {
        guard let owner = snapshot.currentUser else { throw LedgerError.currentUserMissing }
        return PaymentProfileSummary(
            owner: owner,
            destinations: snapshot.destinations(of: owner.id),
            inUse: Set(snapshot.paymentAttempts.filter { !$0.state.isTerminal }.compactMap(\.destinationID))
        )
    }
}

/// "How can friends pay you?" (milestone 2 §6, §10). Optional, skippable, owner-controlled.
struct PaymentProfileView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        PaymentProfileScreen(environment: environment)
    }
}

private struct PaymentProfileScreen: View {
    let environment: AppEnvironment
    @State private var model: SnapshotModel<PaymentProfileSummary>
    @State private var editing: DestinationEditorRequest?
    @State private var pendingDeletion: PaymentDestination?
    @State private var actionError: String?

    init(environment: AppEnvironment) {
        self.environment = environment
        _model = State(initialValue: SnapshotModel(ledger: environment.ledger, derive: PaymentProfileSummary.make))
    }

    var body: some View {
        content
            .navigationTitle(String(localized: "How friends pay you"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "Add method"), systemImage: "plus") { editing = .add }
                        .accessibilityIdentifier("profile.addMethod")
                }
            }
            .task(id: environment.ledger.revision) { await model.load() }
            .sheet(item: $editing) { request in
                DestinationEditorView(request: request, ownerID: model.value?.owner.id)
            }
            .confirmationDialog(
                String(localized: "Remove \(pendingDeletion?.provider.displayName ?? "")?"),
                isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
                titleVisibility: .visible,
                presenting: pendingDeletion
            ) { destination in
                Button(String(localized: "Remove method"), role: .destructive) { Task { await delete(destination) } }
            } message: { destination in
                Text(model.value?.inUse.contains(destination.id) == true
                    ? String(localized: "A payment in progress uses this method. Its record keeps the method's name, but the details will no longer be shown.")
                    : String(localized: "Friends won't see this method anymore. Past payments stay in history."))
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).suScreenBackground()
        case .failed(let error):
            SUErrorState(title: String(localized: "Couldn't load payment methods"), message: LedgerErrorMessages.text(for: error)) {
                Task { await model.load() }
            }
            .frame(maxHeight: .infinity)
            .suScreenBackground()
        case .loaded(let summary):
            list(summary)
        }
    }

    private func list(_ summary: PaymentProfileSummary) -> some View {
        List {
            Section {
                Text(String(localized: """
                Choose the ways you accept money. When someone owes you, they'll see only these, with your preferred \
                method first. Square Up never moves money or asks for bank logins.
                """))
                .font(SUFont.supporting).foregroundStyle(SUColor.textSecondary)
            }
            .suListRows()
            if let actionError {
                Section { Label(actionError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(SUColor.negative) }
                    .suListRows()
            }
            if summary.destinations.isEmpty {
                Section {
                    SUEmptyState(
                        systemImage: "creditcard.and.123",
                        title: String(localized: "How can friends pay you?"),
                        message: String(localized: "Add Apple Cash, PayPal, Cash App, Zelle, Venmo, or cash. You can skip this and add one later."),
                        primaryTitle: String(localized: "Add a method"),
                        primaryAction: { editing = .add }
                    )
                    .listRowBackground(Color.clear)
                }
                .suListRows()
            } else {
                Section {
                    ForEach(summary.destinations) { destination in
                        DestinationRow(destination: destination, isInUse: summary.inUse.contains(destination.id)) {
                            editing = .edit(destination)
                        } setPreferred: {
                            Task { await save(destination, preferred: true, enabled: true) }
                        } setEnabled: { enabled in
                            Task { await save(destination, preferred: destination.isPreferred && enabled, enabled: enabled) }
                        } remove: {
                            pendingDeletion = destination
                        }
                    }
                } header: {
                    Text("Your methods")
                } footer: {
                    Text("Details are shown in full only to people who owe you. Everyone else sees a masked version.")
                }
                .suListRows()
            }
        }
        .scrollContentBackground(.hidden)
        .suScreenBackground()
    }

    private func save(_ destination: PaymentDestination, preferred: Bool, enabled: Bool) async {
        var updated = destination
        updated.isPreferred = preferred
        updated.isEnabled = enabled
        do {
            try await environment.ledger.save(updated)
            actionError = nil
        } catch {
            actionError = LedgerErrorMessages.text(for: error as? LedgerError ?? .unavailable)
        }
    }

    private func delete(_ destination: PaymentDestination) async {
        do {
            try await environment.ledger.deleteDestination(destination.id)
            actionError = nil
        } catch {
            actionError = LedgerErrorMessages.text(for: error as? LedgerError ?? .unavailable)
        }
    }
}

private struct DestinationRow: View {
    let destination: PaymentDestination
    let isInUse: Bool
    let edit: () -> Void
    let setPreferred: () -> Void
    let setEnabled: @MainActor @Sendable (Bool) -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SUSpacing.sm) {
            HStack(spacing: SUSpacing.sm) {
                ProviderMark(provider: destination.provider)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: SUSpacing.xs) {
                        Text(destination.label ?? destination.provider.displayName).font(SUFont.cardTitle)
                        if destination.isPreferred {
                            SUCapsuleLabel(title: String(localized: "Preferred"), systemImage: "star.fill", tone: .accent)
                        }
                    }
                    // The owner sees their own details in full.
                    Text(DestinationPresentation.revealed(destination.value, provider: destination.provider))
                        .font(SUFont.supporting).foregroundStyle(SUColor.textSecondary)
                    if !destination.isEnabled {
                        Text(String(localized: "Hidden from friends")).font(SUFont.metadata).foregroundStyle(SUColor.textTertiary)
                    }
                    if isInUse {
                        Label(String(localized: "Used by a payment in progress"), systemImage: "hourglass")
                            .font(SUFont.metadata).foregroundStyle(SUColor.warning)
                    }
                }
            }
            Toggle(String(localized: "Show to friends"), isOn: Binding(get: { destination.isEnabled }, set: setEnabled))
                .tint(SUColor.accent)
            HStack {
                if !destination.isPreferred, destination.isEnabled {
                    Button(String(localized: "Make preferred"), action: setPreferred).buttonStyle(.borderless)
                }
                Spacer()
                Button(String(localized: "Edit"), action: edit).buttonStyle(.borderless)
                Button(String(localized: "Remove"), role: .destructive, action: remove).buttonStyle(.borderless)
            }
            .font(SUFont.supporting.weight(.semibold))
        }
        .padding(.vertical, SUSpacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("profile.method.\(destination.provider.rawValue)")
    }
}

enum DestinationEditorRequest: Identifiable {
    case add
    case edit(PaymentDestination)

    var id: String {
        switch self {
        case .add: "add"
        case .edit(let destination): destination.id.description
        }
    }
}

/// Add or edit one payment method, with provider-specific fields and inline validation.
///
/// - `sheet`: a system form in its own navigation stack (Profile).
/// - `setup`: a full screen pushed inside first-run setup, in the dusk style of the account screens.
struct DestinationEditorView: View {
    nonisolated enum Presentation { case sheet, setup }
    nonisolated enum Field: Hashable { case primary, link, label }

    let request: DestinationEditorRequest
    let ownerID: MemberID?
    var presentation: Presentation = .sheet
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var input: DestinationInput
    @State private var isPreferred: Bool
    @State private var error: String?
    @State private var isSaving = false
    @FocusState private var focus: Field?

    init(request: DestinationEditorRequest, ownerID: MemberID?, presentation: Presentation = .sheet) {
        self.request = request
        self.ownerID = ownerID
        self.presentation = presentation
        switch request {
        case .add:
            _input = State(initialValue: DestinationInput(provider: .appleCash, primary: ""))
            _isPreferred = State(initialValue: false)
        case .edit(let destination):
            _input = State(initialValue: DestinationInput(
                provider: destination.provider,
                primary: Self.editableText(destination.value, provider: destination.provider),
                link: Self.editableLink(destination),
                label: destination.label ?? ""
            ))
            _isPreferred = State(initialValue: destination.isPreferred)
        }
    }

    var body: some View {
        switch presentation {
        case .sheet:
            NavigationStack {
                form
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel"), role: .cancel) { dismiss() } }
                    }
            }
        case .setup:
            form.authNavigationChrome()
        }
    }

    private var hasLinkField: Bool { input.provider == .cashApp || input.provider == .zelle }
    private var labelPlaceholder: String {
        input.provider == .other ? String(localized: "Name (required)") : String(localized: "Label (optional)")
    }

    private var isEditing: Bool { if case .edit = request { true } else { false } }

    /// The one editor, in the style of the account screens: pushed inside first-run setup, or
    /// presented from Profile.
    private var form: some View {
        SUAuthScaffold(isAnimated: environment.allowsAmbientAnimation) {
            SUAuthHeader(title: isEditing ? String(localized: "Edit\n\(input.provider.displayName)") : String(localized: "Add a way\nto get paid"),
                         subtitle: isEditing ? String(localized: "Change the details friends use to pay you.")
                             : String(localized: "Choose the service friends will use to pay you, then add your details."))
            if case .add = request {
                PaymentServicePicker(selection: $input.provider)
                    .accessibilityIdentifier("destination.provider")
            }
            VStack(alignment: .leading, spacing: SUSpacing.sm) {
                SUFormField(label: primaryPlaceholder, text: $input.primary, symbol: input.provider.outlineSymbolName,
                            keyboard: keyboard, identifier: "destination.primary", focus: $focus, field: .primary) {
                    focus = hasLinkField ? .link : .label
                }
                if hasLinkField {
                    SUFormField(label: linkPlaceholder, text: $input.link, symbol: "link", keyboard: .URL,
                                identifier: "destination.link", focus: $focus, field: .link) { focus = .label }
                }
                SUFormField(label: labelPlaceholder, text: $input.label, symbol: "tag", capitalization: .sentences,
                            submitLabel: .done, identifier: "destination.label", focus: $focus, field: .label) { focus = nil }
                Text(guidance)
                    .font(SUFont.metadata)
                    .foregroundStyle(SUColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, SUSpacing.xxs)
            }
            Toggle(isOn: $isPreferred) {
                Label(String(localized: "Preferred method"), systemImage: "star")
                    .font(SUFont.body)
                    .foregroundStyle(SUColor.textPrimary)
            }
            .tint(SUDusk.rose)
            .padding(.horizontal, SUSpacing.md)
            .frame(minHeight: 58)
            .background(.white.opacity(0.07), in: SUShape.compact)
            .overlay { SUShape.compact.strokeBorder(.white.opacity(0.1), lineWidth: 1) }
            if let error {
                SUInlineStatus(text: error, identifier: "destination.error")
            }
            Button {
                focus = nil
                Task { await save() }
            } label: {
                SUProgressLabel(title: String(localized: "Save method"), workingTitle: String(localized: "Saving…"), isWorking: isSaving)
            }
            .buttonStyle(.suGlassPrimary)
            .disabled(isSaving)
            .accessibilityIdentifier("destination.save")
        }
        .accessibilityIdentifier("auth.paymentEditor")
        .onChange(of: input.provider) { error = nil }
    }

    private func save() async {
        guard let ownerID else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let normalized = try PaymentDestinationValidator.validate(input)
            let destination: PaymentDestination
            switch request {
            case .add:
                destination = PaymentDestination(ownerID: ownerID, provider: input.provider, label: normalized.label,
                                                 value: normalized.value, link: normalized.link, isPreferred: isPreferred,
                                                 createdAt: environment.now)
            case .edit(let existing):
                var updated = existing
                updated.label = normalized.label
                updated.value = normalized.value
                updated.link = normalized.link
                updated.isPreferred = isPreferred
                destination = updated
            }
            try await environment.ledger.save(destination)
            dismiss()
        } catch let validation as DestinationValidationError {
            error = LedgerErrorMessages.text(for: validation)
        } catch {
            self.error = LedgerErrorMessages.text(for: error as? LedgerError ?? .unavailable)
        }
    }

    private var primaryPlaceholder: String {
        switch input.provider {
        case .appleCash: String(localized: "Phone or email used for iMessage")
        case .paypal: String(localized: "PayPal.Me name or link")
        case .cashApp: String(localized: "$Cashtag")
        case .zelle: String(localized: "Zelle email or US phone")
        case .venmo: String(localized: "Venmo username")
        case .cash: String(localized: "Instructions (optional)")
        case .other: String(localized: "How to pay you")
        }
    }

    private var linkPlaceholder: String {
        input.provider == .cashApp ? String(localized: "Cash App payment link (optional)") : String(localized: "Zelle QR link from your bank (optional)")
    }

    private var keyboard: UIKeyboardType {
        switch input.provider {
        case .appleCash, .zelle: .emailAddress
        case .paypal: .URL
        default: .default
        }
    }

    private var guidance: String {
        switch input.provider {
        case .appleCash: String(localized: "Square Up can't check that this contact uses Apple Cash. Friends will be sent to Messages to pay you.")
        case .paypal: String(localized: "Friends will open your PayPal.Me link with the amount filled in.")
        case .cashApp: String(localized: "Only official cash.app links can be added. Without one, friends copy your $Cashtag.")
        case .zelle: String(localized: "Use the email or phone enrolled with Zelle at your bank. Square Up can't check enrolment.")
        case .venmo: String(localized: "Friends will copy your username and the amount into Venmo.")
        case .cash: String(localized: "For paying in person.")
        case .other: String(localized: "Short instructions only. Links and scripts aren't allowed.")
        }
    }

    static func editableLink(_ destination: PaymentDestination) -> String {
        if case .link(let url) = destination.value { return url.absoluteString }
        return destination.link?.absoluteString ?? ""
    }

    static func editableText(_ value: DestinationValue, provider: PaymentProviderKind) -> String {
        switch value {
        case .phone(let phone): DestinationPresentation.formatUSPhone(phone)
        case .email(let email): email
        case .username(let name): provider == .cashApp ? "$\(name)" : name
        case .link: ""
        case .instructions(let text): text
        }
    }
}

/// The payment services as a grid of glass tiles; the chosen one is bright. VoiceOver and Voice
/// Control get a standard picker.
private struct PaymentServicePicker: View {
    @Binding var selection: PaymentProviderKind
    @ScaledMetric(relativeTo: .footnote) private var tileWidth: CGFloat = 96

    var body: some View {
        GlassEffectContainer(spacing: SUSpacing.xs) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: tileWidth), spacing: SUSpacing.xs)], spacing: SUSpacing.xs) {
                ForEach(PaymentProviderKind.allCases, id: \.self) { provider in
                    tile(provider)
                }
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
        .accessibilityRepresentation {
            Picker(String(localized: "Service"), selection: $selection) {
                ForEach(PaymentProviderKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
        }
    }

    private func tile(_ provider: PaymentProviderKind) -> some View {
        let isSelected = provider == selection
        return Button {
            selection = provider
        } label: {
            VStack(spacing: SUSpacing.xs) {
                Image(systemName: provider.outlineSymbolName)
                    .font(.title3)
                    .symbolVariant(isSelected ? .fill : .none)
                    .contentTransition(.symbolEffect(.replace))
                Text(provider.displayName)
                    .font(SUFont.metadata.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(isSelected ? Color.black : SUColor.textPrimary)
            .padding(.vertical, SUSpacing.sm)
            .padding(.horizontal, SUSpacing.xxs)
            .frame(maxWidth: .infinity, minHeight: 78)
            .contentShape(SUShape.compact)
            .glassEffect(isSelected ? .regular.tint(.white).interactive() : .regular.interactive(), in: SUShape.compact)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("destination.provider.\(provider.rawValue)")
    }
}

extension PaymentProviderKind {
    /// Outline symbols for fields and pickers (the filled `symbolName` marks a saved method).
    var outlineSymbolName: String {
        switch self {
        case .appleCash: "message"
        case .paypal: "p.circle"
        case .cashApp: "dollarsign.square"
        case .zelle: "building.columns"
        case .venmo: "v.circle"
        case .cash: "banknote"
        case .other: "ellipsis.circle"
        }
    }
}

#Preview("Payment profile") {
    NavigationStack { PaymentProfileView() }
        .environment(AppEnvironment.preview(.standard))
        .environment(AppRouter())
}
