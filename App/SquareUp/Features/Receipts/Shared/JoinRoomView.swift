import SwiftUI

/// Opening an invitation in the full app (milestone 4 §13): what the room is, who's hosting, and
/// who you are — an existing seat from the host's group or a new name. Joining with the same
/// account again returns to the same participant.
struct JoinRoomView: View {
    /// The invitation's link token, or the room's short code typed by hand.
    let invitation: SharingService.InvitationKey
    let open: (ReceiptRoomID) -> Void

    init(invitation: SharingService.InvitationKey, open: @escaping (ReceiptRoomID) -> Void) {
        self.invitation = invitation
        self.open = open
    }

    init(token: String, open: @escaping (ReceiptRoomID) -> Void) {
        self.init(invitation: .token(token), open: open)
    }

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var preview: InvitationPreviewDTO?
    @State private var failure: LedgerError?
    @State private var seatID: String?
    @State private var name = ""
    @State private var isJoining = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if let preview {
                    form(preview)
                } else if let failure {
                    SUEmptyState(systemImage: failure == .remote(.accessEnded) ? "link.badge.plus" : "wifi.exclamationmark",
                                 title: failure == .remote(.accessEnded) ? String(localized: "This invitation doesn't work")
                                     : String(localized: "Couldn't open the invitation"),
                                 message: failure == .remote(.accessEnded)
                                     ? String(localized: "It may have expired or been turned off. Ask the host for a new link.")
                                     : LedgerErrorMessages.text(for: failure),
                                 primaryTitle: String(localized: "Try again"), primaryAction: { Task { await load() } },
                                 secondaryTitle: String(localized: "Close"), secondaryAction: { dismiss() })
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .suScreenBackground()
            .navigationTitle(String(localized: "Join receipt"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel")) { dismiss() } }
            }
        }
        .task { await load() }
    }

    private func form(_ preview: InvitationPreviewDTO) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SUSpacing.lg) {
                VStack(alignment: .leading, spacing: SUSpacing.xs) {
                    Text(preview.merchant.isEmpty ? String(localized: "A receipt") : preview.merchant)
                        .font(SUFont.screenTitle).foregroundStyle(SUColor.textPrimary).accessibilityAddTraits(.isHeader)
                    Text(String(localized: "\(preview.host.displayName) invited you to claim what you had."))
                        .font(SUFont.body).foregroundStyle(SUColor.textSecondary)
                    if let date = RemoteRoomMapper.date(fromDay: preview.date) {
                        Text(date.formatted(date: .long, time: .omitted)).font(SUFont.metadata).foregroundStyle(SUColor.textTertiary)
                    }
                }
                if preview.youAreParticipantId != nil {
                    SUConfirmationBanner(title: String(localized: "You're already in this room"), systemImage: "person.crop.circle.badge.checkmark", tone: .positive)
                } else if preview.isClosed {
                    SUConfirmationBanner(title: String(localized: "This room is closed"), message: String(localized: "It isn't taking new people."),
                                         systemImage: "lock", tone: .warning)
                } else {
                    identityPicker(preview)
                }
                Button {
                    Task { await join() }
                } label: {
                    HStack {
                        if isJoining { ProgressView() }
                        Text(preview.youAreParticipantId != nil ? String(localized: "Open room") : String(localized: "Join"))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.suPrimary)
                .disabled(isJoining || !canJoin(preview))
                .accessibilityIdentifier("join.submit")
                if let failure {
                    Text(LedgerErrorMessages.text(for: failure)).font(SUFont.supporting).foregroundStyle(SUColor.negative)
                }
            }
            .padding(.horizontal, SUSpacing.screenMargin)
            .padding(.vertical, SUSpacing.lg)
            .frame(maxWidth: SUMetrics.readableWidth)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func identityPicker(_ preview: InvitationPreviewDTO) -> some View {
        VStack(alignment: .leading, spacing: SUSpacing.sm) {
            SUSectionHeader(title: String(localized: "Who are you?"))
            ForEach(preview.openSeats) { seat in
                choice(String(localized: "I'm \(seat.displayName)"), selected: seatID == seat.id) { seatID = seat.id }
            }
            choice(preview.openSeats.isEmpty ? String(localized: "Your name") : String(localized: "Someone else"), selected: seatID == nil) {
                seatID = nil
                nameFocused = true
            }
            if seatID == nil {
                TextField(String(localized: "Your name"), text: $name)
                    .textContentType(.givenName)
                    .focused($nameFocused)
                    .submitLabel(.join)
                    .padding(SUSpacing.sm)
                    .suSurface(SUShape.compact)
                    .accessibilityIdentifier("join.name")
                Text(String(localized: "Shown to others in this room. It doesn't sign you in to anything."))
                    .font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
            }
        }
    }

    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(SUFont.body).foregroundStyle(SUColor.textPrimary)
                Spacer()
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? SUColor.accent : SUColor.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(SUSpacing.sm)
            .frame(minHeight: SUMetrics.minimumTouchTarget)
            .suSurface(SUShape.compact)
            .contentShape(SUShape.compact)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func canJoin(_ preview: InvitationPreviewDTO) -> Bool {
        if preview.youAreParticipantId != nil { return true }
        if preview.isClosed { return false }
        return seatID != nil || !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func load() async {
        failure = nil
        do {
            preview = try await environment.sharing.preview(invitation)
        } catch {
            failure = error
        }
    }

    private func join() async {
        isJoining = true
        failure = nil
        defer { isJoining = false }
        do {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let id = try await environment.sharing.join(invitation, displayName: seatID == nil && !trimmed.isEmpty ? String(trimmed.prefix(40)) : nil,
                                                        seatID: seatID)
            dismiss()
            open(id)
        } catch {
            failure = error
        }
    }
}

/// Paste or type an invitation link, or type the room's short code (for builds without universal
/// links, for links received in another app, and for a code read aloud at the table).
struct JoinWithLinkSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var isInvalid = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "Link or code"), text: $text, prompt: Text(verbatim: "ABCD-EFGH-JKMN"), axis: .vertical)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(SUFont.body.monospaced())
                        .accessibilityIdentifier("join.link")
                    PasteButton(payloadType: String.self) { strings in
                        if let first = strings.first { text = first }
                    }
                } footer: {
                    Text(isInvalid ? String(localized: "That isn't a Square Up invitation link or room code.")
                        : String(localized: "Enter the code the host shows you, or paste the link they sent. To use a QR code, point the Camera app at it."))
                        .foregroundStyle(isInvalid ? SUColor.negative : SUColor.textSecondary)
                }
                .suListRows()
            }
            .scrollContentBackground(.hidden)
            .suScreenBackground()
            .navigationTitle(String(localized: "Join a receipt"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Continue")) {
                        let host = environment.sharing.configuration?.baseURL.host()
                        let port = environment.sharing.configuration?.baseURL.port
                        switch InvitationInput.parse(text, expectedHost: host, expectedPort: port) {
                        case .token(let token)?:
                            dismiss()
                            environment.sharing.pendingInvitation = SharingService.PendingInvitation(token: token)
                        case .code(let code)?:
                            dismiss()
                            environment.sharing.pendingInvitation = SharingService.PendingInvitation(code: code)
                        case nil:
                            isInvalid = true
                        }
                    }
                    .disabled(text.isEmpty)
                    .accessibilityIdentifier("join.continue")
                }
            }
        }
        .presentationDetents([.medium])
    }
}

extension InvitationPreviewDTO {
    /// Not taking new people: finalized or cancelled, or a temporary room that ended.
    var isClosed: Bool { roomState == "finalized" || roomState == "cancelled" || ended == true }
}
