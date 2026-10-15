import SwiftUI

/// Create or edit a personal group: name, description, mark, currency, and members.
struct GroupEditorView: View {
    let request: GroupEditorRequest
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        GroupEditorScreen(request: request, environment: environment)
    }
}

private struct GroupEditorScreen: View {
    let environment: AppEnvironment
    @State private var model: GroupEditorModel
    @State private var pendingRemoval: Member?
    @Environment(\.dismiss) private var dismiss
    @Environment(AppRouter.self) private var router
    @FocusState private var focusedField: Field?

    private enum Field { case name, memberName }

    init(request: GroupEditorRequest, environment: AppEnvironment) {
        self.environment = environment
        _model = State(initialValue: GroupEditorModel(request: request))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(model.isCreating ? String(localized: "New group") : String(localized: "Edit group"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
        }
        .task {
            await model.load(from: environment.ledger)
            if model.isCreating, environment.sharedGroups.isReady { model.location = .shared }
        }
        .interactiveDismissDisabled(model.saveState == .saving)
        .sensoryFeedback(.success, trigger: model.saveState) { _, new in
            if case .saved = new { true } else { false }
        }
        .confirmationDialog(
            String(localized: "Remove \(pendingRemoval?.displayName ?? "")?"),
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { member in
            Button(String(localized: "Remove from group"), role: .destructive) {
                Task { await model.remove(member, using: environment.ledger) }
            }
        } message: { _ in
            Text("They won't be part of new expenses. Their past expenses, payments, and activity stay in the group.")
        }
    }

    private var locationFooter: String {
        switch model.location {
        case .shared:
            if environment.sharedGroups.isReady {
                String(localized: """
                Kept on the server: everyone you invite sees the same expenses and balances on their own iPhone. Needs a connection \
                to create. Up to 25 people.
                """)
            } else {
                String(localized: "Sign in from Profile with an email and password to create shared groups.")
            }
        case .local:
            String(localized: "Only on this iPhone — good for trying things out or keeping track yourself. You can share it later.")
        }
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.loadError {
            SUErrorState(title: String(localized: "Couldn't open this group"), message: LedgerErrorMessages.text(for: error)) {
                Task { await model.load(from: environment.ledger) }
            }
        } else if model.snapshot == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            form
        }
    }

    private var form: some View {
        Form {
            if model.isCreating, environment.sharedGroups.isConfigured {
                Section {
                    Picker(String(localized: "Where it lives"), selection: $model.location) {
                        Text(String(localized: "Shared")).tag(GroupEditorModel.Location.shared)
                        Text(String(localized: "On this iPhone")).tag(GroupEditorModel.Location.local)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("groupEditor.location")
                } header: {
                    Text(String(localized: "Where it lives"))
                } footer: {
                    Text(locationFooter)
                }
                .suListRows()
            }
            Section {
                TextField(String(localized: "Group name"), text: $model.name)
                    .font(SUFont.body.weight(.semibold))
                    .focused($focusedField, equals: .name)
                    .submitLabel(.next)
                    .accessibilityIdentifier("groupEditor.name")
                if let error = model.nameError {
                    Label(error, systemImage: "exclamationmark.circle").font(SUFont.metadata).foregroundStyle(SUColor.negative)
                }
                TextField(String(localized: "Description (optional)"), text: $model.details, axis: .vertical)
                    .lineLimit(1...3)
                    .accessibilityIdentifier("groupEditor.details")
            } header: {
                Text("Name")
            }
            .suListRows()

            Section(String(localized: "Icon")) {
                symbolGrid
            }
            .suListRows()

            Section {
                Picker(String(localized: "Currency"), selection: $model.currency) {
                    ForEach(GroupEditorModel.currencies, id: \.self) { code in
                        Text(Locale.autoupdatingCurrent.localizedString(forCurrencyCode: code.rawValue).map { "\($0) (\(code.rawValue))" } ?? code.rawValue)
                            .tag(code)
                    }
                }
                .disabled(model.isCurrencyLocked)
            } header: {
                Text("Currency")
            } footer: {
                if model.isCurrencyLocked {
                    Text("The currency can't change once the group has expenses or payments.")
                } else {
                    Text("Every expense in this group uses this currency.")
                }
            }
            .suListRows()

            if isSharedGroup {
                sharedPeopleSection
            } else {
                membersSection
            }

            if case .failed(let message) = model.saveState {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(SUColor.negative)
                }
                .suListRows()
            }
        }
        .scrollContentBackground(.hidden)
        .suScreenBackground()
    }

    private var symbolGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: SUSpacing.sm)], spacing: SUSpacing.sm) {
            ForEach(GroupEditorModel.symbols, id: \.self) { symbol in
                let isSelected = model.symbolName == symbol
                Button {
                    model.symbolName = symbol
                } label: {
                    Image(systemName: symbol)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(isSelected ? SUColor.onAccent : SUColor.accent)
                        .frame(width: 52, height: 52)
                        .background(isSelected ? SUColor.accent : SUColor.accent.opacity(0.12), in: SUShape.control)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Self.symbolName(symbol))
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(.vertical, SUSpacing.xs)
        .sensoryFeedback(.selection, trigger: model.symbolName)
    }

    /// A shared group starts with its creator only; everyone else joins with their own invitation
    /// (from the group's People screen), so nobody is added by name.
    private var isSharedGroup: Bool {
        if model.isCreating { return model.location == .shared }
        return model.group.map { environment.sharedGroups.isShared($0.id) } ?? false
    }

    private var sharedPeopleSection: some View {
        Section {
            if let me = model.currentUser {
                memberRow(me, isYou: true)
            }
        } header: {
            Text("Members")
        } footer: {
            Text(model.isCreating
                ? String(localized: "Just you for now. Once it's created, open People → Invite people to send each person their own invitation.")
                : String(localized: "People join with their own invitation. Manage them from the group's People screen."))
        }
        .suListRows()
        .accessibilityIdentifier("groupEditor.sharedPeople")
    }

    @ViewBuilder
    private var membersSection: some View {
        Section {
            if let me = model.currentUser {
                memberRow(me, isYou: true)
            }
            if model.isCreating {
                ForEach(model.pickedMembers) { member in
                    memberRow(member, isYou: false) { model.unpickExisting(member.id) }
                }
                ForEach(model.pendingMembers) { pending in
                    memberRow(Member(displayName: pending.displayName, handle: pending.handle.isEmpty ? nil : pending.handle), isYou: false) {
                        model.removePending(pending.id)
                    }
                }
            } else {
                ForEach(model.activeMembers.filter { $0.id != model.currentUser?.id }) { member in
                    memberRow(member, isYou: false) { pendingRemoval = member }
                }
            }
            addPersonFields
        } header: {
            Text("Members")
        } footer: {
            Text("Use full names. Add a handle if two people share a name.")
        }
        .suListRows()

        if !model.knownPeople.isEmpty {
            Section(String(localized: "People you know")) {
                ForEach(model.knownPeople.filter { known in !model.pickedExisting.contains(known.id) }) { member in
                    Button {
                        if model.isCreating {
                            model.pickExisting(member)
                        } else {
                            Task { await model.addExisting(member, using: environment.ledger) }
                        }
                    } label: {
                        HStack(spacing: SUSpacing.sm) {
                            SUAvatar(member: member, size: .small)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(member.displayName).foregroundStyle(SUColor.textPrimary)
                                if let handle = member.handle {
                                    Text("@\(handle)").font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                                }
                            }
                            Spacer()
                            Image(systemName: "plus.circle.fill").foregroundStyle(SUColor.accent).accessibilityHidden(true)
                        }
                    }
                    .accessibilityLabel(String(localized: "Add \(member.displayName)"))
                }
            }
            .suListRows()
        }

        if !model.isCreating, !model.formerMembers.isEmpty {
            Section {
                ForEach(model.formerMembers) { member in
                    HStack {
                        SUAvatar(member: member, size: .small)
                        Text(member.displayName).foregroundStyle(SUColor.textSecondary)
                        Spacer()
                        Button(String(localized: "Add back")) {
                            Task { await model.addExisting(member, using: environment.ledger) }
                        }
                    }
                }
            } header: {
                Text("Former members")
            } footer: {
                Text("Their past expenses and payments are still part of this group's history.")
            }
            .suListRows()
        }
    }

    private var addPersonFields: some View {
        VStack(alignment: .leading, spacing: SUSpacing.xs) {
            TextField(String(localized: "Full name"), text: $model.memberName)
                .textContentType(.name)
                .focused($focusedField, equals: .memberName)
                .submitLabel(.done)
                .onSubmit(addPerson)
                .accessibilityIdentifier("groupEditor.memberName")
            HStack {
                TextField(String(localized: "Handle (optional)"), text: $model.memberHandle)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("groupEditor.memberHandle")
                Button(String(localized: "Add"), action: addPerson)
                    .buttonStyle(.borderless)
                    .disabled(model.memberName.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("groupEditor.addMember")
            }
            if let message = model.memberMessage {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(SUFont.metadata)
                    .foregroundStyle(SUColor.negative)
                    .accessibilityIdentifier("groupEditor.memberMessage")
            }
        }
        .padding(.vertical, SUSpacing.xxs)
    }

    private func addPerson() {
        if model.isCreating {
            if model.queueTypedMember() { focusedField = .memberName }
        } else {
            Task { await model.addTypedMember(using: environment.ledger) }
        }
    }

    private func memberRow(_ member: Member, isYou: Bool, remove: (() -> Void)? = nil) -> some View {
        HStack(spacing: SUSpacing.sm) {
            SUAvatar(member: member, size: .small, isCurrentUser: isYou)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: SUSpacing.xs) {
                    Text(member.displayName).foregroundStyle(SUColor.textPrimary)
                    if isYou { SURoleBadge(kind: .you) }
                }
                if let handle = member.handle {
                    Text("@\(handle)").font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                }
            }
            Spacer()
            if let remove {
                Button(role: .destructive, action: remove) {
                    Image(systemName: "minus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(SUColor.negative)
                        .frame(minWidth: SUMetrics.minimumTouchTarget, minHeight: SUMetrics.minimumTouchTarget)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(String(localized: "Remove \(member.displayName)"))
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(String(localized: "Cancel"), role: .cancel) { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button {
                Task {
                    if let id = await model.save(using: environment.ledger, sharedGroups: environment.sharedGroups) {
                        dismiss()
                        if model.isCreating { router.openGroupAfterSheet(id) }
                    }
                }
            } label: {
                if model.saveState == .saving {
                    ProgressView()
                } else {
                    Text(model.isCreating ? String(localized: "Create") : String(localized: "Save"))
                }
            }
            .disabled(!model.canSave || (model.isCreating && model.location == .shared && !environment.sharedGroups.isReady))
            .accessibilityIdentifier("groupEditor.save")
        }
    }

    static func symbolName(_ symbol: String) -> String {
        switch symbol {
        case "person.3.fill": String(localized: "Friends")
        case "house.fill": String(localized: "Home")
        case "airplane": String(localized: "Travel")
        case "mountain.2.fill": String(localized: "Outdoors")
        case "fork.knife": String(localized: "Food")
        case "car.fill": String(localized: "Road trip")
        case "party.popper.fill": String(localized: "Party")
        case "sportscourt.fill": String(localized: "Sports")
        case "graduationcap.fill": String(localized: "School")
        case "tent.fill": String(localized: "Camping")
        case "cart.fill": String(localized: "Shopping")
        case "heart.fill": String(localized: "Family")
        default: symbol
        }
    }
}

#Preview("New group") {
    GroupEditorView(request: .create)
        .environment(AppEnvironment.preview(.standard))
        .environment(AppRouter())
}

#Preview("Edit group") {
    GroupEditorView(request: .edit(SampleLedger.GroupKey.apartment.id))
        .environment(AppEnvironment.preview(.standard))
        .environment(AppRouter())
}
