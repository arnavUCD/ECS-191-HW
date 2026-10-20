import SwiftUI

nonisolated struct ProfileSummary: Equatable, Sendable {
    let member: Member
    let groupCount: Int
    let currency: CurrencyCode
    /// Enabled payment methods the current user accepts (masked summary).
    let paymentMethods: [PaymentDestination]
    /// PROTOTYPE: sample identities that can use this device.
    let sampleIdentities: [Member]

    static func make(from snapshot: LedgerSnapshot) throws -> ProfileSummary {
        guard let me = snapshot.currentUser else { throw LedgerError.currentUserMissing }
        let groups = snapshot.groupsForCurrentUser
        return ProfileSummary(
            member: me,
            groupCount: groups.count,
            currency: snapshot.defaultCurrency,
            paymentMethods: snapshot.destinations(of: me.id).filter(\.isEnabled),
            sampleIdentities: snapshot.members.values.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        )
    }
}

/// Identity, preferences, AI and privacy controls, and prototype data management.
struct ProfileView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        ProfileScreen(environment: environment)
    }
}

private struct ProfileScreen: View {
    let environment: AppEnvironment
    @State private var model: SnapshotModel<ProfileSummary>
    @State private var onDeviceAvailability: AIAvailability?
    @State private var isConfirmingReset = false
    @State private var resetCount = 0

    @AppStorage(HapticsService.preferenceKey) private var signatureHaptics = true
    @AppStorage(QuickEntryService.onDevicePreferenceKey) private var allowOnDeviceAI = true

    init(environment: AppEnvironment) {
        self.environment = environment
        _model = State(initialValue: SnapshotModel(ledger: environment.ledger, derive: ProfileSummary.make))
    }

    var body: some View {
        Form {
            if let summary = model.value {
                identity(summary)
                paymentMethods(summary)
                preferences(summary)
                if !environment.requiresAccount { sampleIdentity(summary) }
            }
            AccountSection()
            intelligence
            if environment.receiptIntelligence != nil { receiptProcessing }
            privacy
            if !environment.requiresAccount { sampleData }
            about
            #if DEBUG
            Section(String(localized: "Developer")) {
                NavigationLink(String(localized: "Design system")) { DesignSystemGallery() }
                LabeledContent(String(localized: "Visual QA scenarios"), value: "-SUScenario <name>")
            }
            .suListRows()
            #endif
        }
        .scrollContentBackground(.hidden)
        .suScreenBackground()
        .navigationTitle(String(localized: "Profile"))
        .task(id: environment.ledger.revision) { await model.load() }
        .task { onDeviceAvailability = await environment.quickEntry.onDeviceAvailability() }
        .sensoryFeedback(.success, trigger: resetCount)
        .confirmationDialog(
            String(localized: "Reset sample data?"),
            isPresented: $isConfirmingReset,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Reset sample data"), role: .destructive) {
                Task {
                    try? await environment.resetSampleData()
                    resetCount += 1
                }
            }
        } message: {
            Text("Every expense and payment on this iPhone will be replaced with the original sample groups. This can't be undone.")
        }
    }

    private func identity(_ summary: ProfileSummary) -> some View {
        Section {
            SUCoverPanel(palette: .attention, symbol: "person.crop.circle", coverHeight: 150) {
                SUAvatar(member: summary.member, size: .hero, isCurrentUser: true)
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                SUTagPill(title: Inflect.string("In ^[\(summary.groupCount + environment.sharedGroups.summaries.count) group](inflect: true)"),
                          systemImage: "person.3.fill")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            } content: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.member.displayName)
                        .font(.system(.title2, weight: .semibold))
                        .foregroundStyle(SUColor.textPrimary)
                    if let handle = summary.member.handle {
                        Text("@\(handle)").font(SUFont.supporting).foregroundStyle(SUColor.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        } footer: {
            Text(environment.sharedGroups.isReady
                ? String(localized: "This is the sample person for groups on this iPhone. Shared groups use your account's name, below.")
                : String(localized: "This is the sample person for groups on this iPhone. To share groups with other people's iPhones, add an account below."))
        }
    }

    private func paymentMethods(_ summary: ProfileSummary) -> some View {
        // Signed in: the methods saved to the account (shared groups use them); otherwise this iPhone's.
        let methods = environment.sharedGroups.isReady ? environment.sharedGroups.profileDestinations.filter(\.isEnabled) : summary.paymentMethods
        return Section {
            NavigationLink(value: AppRoute.paymentProfile) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(methods.isEmpty ? String(localized: "How can friends pay you?") : String(localized: "How friends pay you"))
                        .font(SUFont.body.weight(.semibold))
                    Text(methods.isEmpty
                        ? String(localized: "Add Apple Cash, PayPal, Cash App, Zelle, Venmo, or cash. Optional.")
                        : methods.map(\.provider.displayName).formatted(.list(type: .and)))
                        .font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                }
            }
            .accessibilityIdentifier("profile.paymentMethods")
        } header: {
            Text("Getting paid")
        } footer: {
            if environment.sharedGroups.isReady {
                Text(String(localized: """
                Saved to your account. In shared groups, others see which methods you accept; the details appear only to someone \
                who owes you, when they pay.
                """))
            }
        }
        .suListRows()
    }

    /// PROTOTYPE: choose which sample person is using this iPhone (clearly local, not sync).
    private func sampleIdentity(_ summary: ProfileSummary) -> some View {
        Section {
            Picker(String(localized: "Using Square Up as"), selection: Binding(
                get: { summary.member.id },
                set: { id in Task { try? await environment.ledger.switchCurrentUser(to: id) } }
            )) {
                ForEach(summary.sampleIdentities) { member in
                    Text(member.displayName).tag(member.id)
                }
            }
            .accessibilityIdentifier("profile.sampleIdentity")
        } header: {
            Text("Local prototype")
        } footer: {
            Text("""
            Everyone in the sample groups lives on this iPhone. Switching lets you play another person — for \
            example, to confirm a payment as its recipient. Nothing is sent to other devices.
            """)
        }
        .suListRows()
    }

    private func preferences(_ summary: ProfileSummary) -> some View {
        Section(String(localized: "Preferences")) {
            LabeledContent(String(localized: "Default currency"), value: summary.currency.rawValue)
            Toggle(isOn: $signatureHaptics) {
                Label(String(localized: "Signature haptics"), systemImage: "hand.tap")
            }
            if signatureHaptics && environment.haptics.isAvailable {
                Button(String(localized: "Feel the “all square” haptic")) {
                    environment.haptics.play(.settle)
                }
            }
        }
        .suListRows()
    }

    private var intelligence: some View {
        Section {
            Toggle(isOn: $allowOnDeviceAI) {
                Label(String(localized: "Apple Intelligence for quick entry"), systemImage: "apple.intelligence")
            }
            LabeledContent(String(localized: "Status")) {
                switch onDeviceAvailability {
                case .available: Text(String(localized: "Available on this iPhone"))
                case .unavailable(let reason): Text(reason).multilineTextAlignment(.trailing)
                case nil: ProgressView()
                }
            }
        } header: {
            Text(String(localized: "AI assistance"))
        } footer: {
            Text("""
            Suggestions are processed on this iPhone. AI fills in a draft you review — it never calculates \
            balances, records payments, or saves anything on its own. When it's unavailable, a built-in \
            parser is used instead.
            """)
        }
        .suListRows()
    }

    /// Milestone 5 §7: the AI receipt-processing choice, reversible at any time.
    private var receiptProcessing: some View {
        Section {
            Picker(selection: receiptAIBinding) {
                Text(String(localized: "Automatic AI processing")).tag(ReceiptAIMode.automatic)
                Text(String(localized: "On-device only")).tag(ReceiptAIMode.onDeviceOnly)
            } label: {
                Label(String(localized: "Receipt processing"), systemImage: "doc.text.viewfinder")
            }
            .accessibilityIdentifier("profile.receiptProcessing")
        } header: {
            Text(String(localized: "Receipts"))
        } footer: {
            Text(environment.receiptAI.mode == .onDeviceOnly
                ? String(localized: "Receipts are read and organized on this iPhone. Nothing is sent for processing.")
                : String(localized: """
                With AI processing, the receipt image and the text read on this iPhone go to Square Up's server and to \
                Anthropic's Claude to identify items and totals. Nothing is saved until you review it. Anthropic deletes \
                API data within 30 days under its current policy; Square Up keeps the result (not the image) for up to \
                24 hours so the same receipt isn't processed twice. Choosing on-device only deletes those results.
                """))
        }
        .suListRows()
    }

    private var receiptAIBinding: Binding<ReceiptAIMode> {
        Binding(get: { environment.receiptAI.mode }, set: { mode in
            Task { await environment.setReceiptAIMode(mode) }
        })
    }

    private var privacy: some View {
        Section {
            Label(String(localized: "Diagnostics never include names, amounts, notes, or receipt text."), systemImage: "lock.shield")
                .font(SUFont.supporting)
                .foregroundStyle(SUColor.textSecondary)
        } header: {
            Text(String(localized: "Privacy"))
        }
        .suListRows()
    }

    private var sampleData: some View {
        Section {
            Button(String(localized: "Reset sample data"), role: .destructive) { isConfirmingReset = true }
        } header: {
            Text(String(localized: "Sample data"))
        } footer: {
            Text("This prototype ships with sample people, groups, and expenses so every workflow can be tried without an account.")
        }
        .suListRows()
    }

    private var about: some View {
        Section(String(localized: "About")) {
            LabeledContent(String(localized: "Version"), value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
            LabeledContent(String(localized: "Storage"), value: String(localized: "On this iPhone"))
            if let privacyPolicy = Self.privacyPolicyURL {
                Link(String(localized: "Privacy policy"), destination: privacyPolicy)
                    .accessibilityIdentifier("profile.privacyPolicy")
            }
        }
        .suListRows()
    }

    /// The published privacy policy (`SQUAREUP_PRIVACY_POLICY_ADDRESS` in `Config/Remote.xcconfig`).
    private static var privacyPolicyURL: URL? {
        guard let address = (Bundle.main.object(forInfoDictionaryKey: "SquareUpPrivacyPolicyAddress") as? String)?
            .trimmingCharacters(in: .whitespaces), !address.isEmpty, !address.hasPrefix("$(") else { return nil }
        return URL(string: "https://\(address)")
    }
}

#Preview("Profile") {
    NavigationStack { ProfileView() }
        .environment(AppEnvironment.preview())
        .environment(AppRouter())
}
