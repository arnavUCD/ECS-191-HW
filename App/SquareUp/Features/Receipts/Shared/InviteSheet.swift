import CoreImage.CIFilterBuiltins
import SwiftUI

/// The host's invitation (milestone 4 §6; "Split with people now"): a QR code, a link to share, and
/// a short code to read across the table. Each is a secret: anyone with it can join until it expires
/// or is turned off, so they're shown only here, kept in the Keychain, and never logged.
///
/// Anyone with Square Up can always join with the code (Home → Join a receipt), even where links
/// don't open the app. The App Clip isn't available yet, so this sheet never promises it.
struct InviteSheet: View {
    let roomID: ReceiptRoomID
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var current: SharingService.SavedInvitation?
    @State private var invitations: [InvitationDTO] = []
    @State private var isWorking = false
    @State private var error: String?
    @State private var isConfirmingStop = false
    @State private var copied = false

    private var url: URL? { current?.url.flatMap(URL.init(string:)) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: SUSpacing.lg) {
                    if let current {
                        if let url {
                            QRCodeView(text: url.absoluteString)
                                .frame(maxWidth: 240)
                                .accessibilityLabel(String(localized: "QR code for the invitation"))
                                .accessibilityIdentifier("invite.qr")
                            Text(String(localized: "Point a camera at this code to join."))
                                .font(SUFont.supporting).foregroundStyle(SUColor.textSecondary).multilineTextAlignment(.center)
                        }
                        if let code = current.code { codePanel(code) }
                        if let url { shareButtons(url, code: current.code) }
                        details
                        if invitations.filter(\.isActive).count > 1 || invitations.contains(where: { !$0.isActive }) {
                            invitationList
                        }
                    } else if isWorking {
                        ProgressView().padding(.vertical, SUSpacing.xl)
                    }
                    if let error {
                        SUConfirmationBanner(title: String(localized: "Couldn't make an invitation"), message: error,
                                             systemImage: "exclamationmark.triangle.fill", tone: .negative,
                                             actionTitle: String(localized: "Try again")) { Task { await create(revokeExisting: false) } }
                    }
                }
                .padding(.horizontal, SUSpacing.screenMargin)
                .padding(.vertical, SUSpacing.lg)
                .frame(maxWidth: SUMetrics.readableWidth)
                .frame(maxWidth: .infinity)
            }
            .suScreenBackground()
            .navigationTitle(String(localized: "Invite people"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(String(localized: "Done")) { dismiss() } }
            }
            .confirmationDialog(String(localized: "Stop new people joining?"), isPresented: $isConfirmingStop, titleVisibility: .visible) {
                Button(String(localized: "Turn off every link and code"), role: .destructive) { Task { await stop() } }
            } message: {
                Text(String(localized: "Links and codes stop working. People already in the room stay in it."))
            }
            .sensoryFeedback(.success, trigger: copied)
        }
        .task { await load() }
    }

    /// The short code, large and grouped for reading aloud, with a copy button.
    private func codePanel(_ code: String) -> some View {
        VStack(spacing: SUSpacing.xs) {
            Text(String(localized: "Or enter this code in Square Up")).font(SUFont.metadata.weight(.semibold)).foregroundStyle(SUColor.textSecondary)
            Text(code)
                .font(.system(.title, design: .monospaced, weight: .semibold))
                .kerning(1.5)
                .foregroundStyle(SUColor.textPrimary)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .textSelection(.enabled)
                .accessibilityLabel(String(localized: "Room code"))
                .accessibilityValue(code.map(String.init).joined(separator: " "))
                .accessibilityIdentifier("invite.code")
            Button {
                environment.handoff.copy(code)
                copied.toggle()
            } label: {
                Label(String(localized: "Copy code"), systemImage: "doc.on.doc")
            }
            .buttonStyle(.suPill)
            .accessibilityIdentifier("invite.copyCode")
        }
        .padding(SUSpacing.md)
        .frame(maxWidth: .infinity)
        .suSurface(SUShape.card, elevated: true)
    }

    private func shareButtons(_ url: URL, code: String?) -> some View {
        VStack(spacing: SUSpacing.xs) {
            ShareLink(item: url, subject: Text(String(localized: "Join my receipt")),
                      message: Text(code.map { String(localized: "Claim what you had on Square Up. Or open Square Up and enter the code \($0).") }
                          ?? String(localized: "Claim what you had on Square Up."))) {
                Label(String(localized: "Share link"), systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
            }
            .buttonStyle(.suPrimary)
            .accessibilityIdentifier("invite.share")
            Button {
                environment.handoff.copy(url.absoluteString)
                copied.toggle()
            } label: {
                Label(String(localized: "Copy link"), systemImage: "link").frame(maxWidth: .infinity)
            }
            .buttonStyle(.suSecondary)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: SUSpacing.sm) {
            Label {
                Text(expiry.map { String(localized: "Works until \($0.formatted(date: .abbreviated, time: .shortened)), unless you turn it off.") }
                    ?? String(localized: "Works until it expires, unless you turn it off."))
            } icon: {
                Image(systemName: "clock")
            }
            Label(String(localized: "People see the receipt's items and amounts and who claimed what — never your groups or balances."),
                  systemImage: "eye")
            Label(String(localized: "Without Square Up, the link explains how to get it and join with the code."), systemImage: "iphone")
            HStack(spacing: SUSpacing.xs) {
                Button(String(localized: "New invitation")) { Task { await create(revokeExisting: false) } }
                    .buttonStyle(.suPill)
                    .disabled(isWorking)
                    .accessibilityIdentifier("invite.another")
                Button(String(localized: "Turn off all"), role: .destructive) { isConfirmingStop = true }
                    .buttonStyle(.suPill)
                    .disabled(isWorking)
                    .accessibilityIdentifier("invite.revoke")
            }
        }
        .font(SUFont.supporting)
        .foregroundStyle(SUColor.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var expiry: Date? {
        invitations.first { $0.invitationId == current?.invitationID }.flatMap { RemoteRoomMapper.timestamp($0.expiresAt) }
    }

    /// Every invitation for this room: how many joined with it, and a way to turn each one off.
    private var invitationList: some View {
        SUPanelSection(title: String(localized: "Invitations"), subtitle: String(localized: "Each link and code works on its own.")) {
            ForEach(invitations) { invitation in
                let saved = environment.sharing.savedInvitations(for: roomID).first { $0.invitationID == invitation.invitationId }
                HStack(spacing: SUSpacing.sm) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(saved?.code ?? String(localized: "Invitation")).font(SUFont.body.monospaced())
                        Text(invitation.isActive ? Inflect.string("^[\(invitation.guestCount) person](inflect: true) joined")
                            : String(localized: "Turned off or expired"))
                            .font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                    }
                    Spacer(minLength: SUSpacing.xs)
                    if invitation.isActive {
                        if saved != nil, saved?.invitationID != current?.invitationID {
                            Button(String(localized: "Show")) { current = saved }.buttonStyle(.suPill)
                        }
                        Button(String(localized: "Turn off"), role: .destructive) { Task { await revoke(invitation) } }
                            .buttonStyle(.suPill)
                            .accessibilityIdentifier("invite.turnOff")
                    }
                }
                .accessibilityElement(children: .contain)
            }
        }
    }

    // MARK: Actions

    private func load() async {
        invitations = await (try? environment.sharing.invitations(for: roomID)) ?? []
        let active = Set(invitations.filter(\.isActive).map(\.invitationId))
        if let saved = environment.sharing.savedInvitations(for: roomID).last(where: { active.contains($0.invitationID) }) {
            current = saved
            return
        }
        await create(revokeExisting: false)
    }

    private func create(revokeExisting: Bool) async {
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            let invitation = try await environment.sharing.createInvitation(for: roomID, revokeExisting: revokeExisting)
            current = SharingService.SavedInvitation(invitationID: invitation.invitationId, url: invitation.url, code: invitation.code)
            invitations = await (try? environment.sharing.invitations(for: roomID)) ?? [invitation]
        } catch {
            self.error = LedgerErrorMessages.text(for: error)
        }
    }

    private func revoke(_ invitation: InvitationDTO) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await environment.sharing.revokeInvitation(invitation.invitationId, in: roomID)
            invitations = await (try? environment.sharing.invitations(for: roomID)) ?? invitations
            if current?.invitationID == invitation.invitationId {
                let active = Set(invitations.filter(\.isActive).map(\.invitationId))
                current = environment.sharing.savedInvitations(for: roomID).last { active.contains($0.invitationID) }
            }
        } catch {
            self.error = LedgerErrorMessages.text(for: error)
        }
    }

    private func stop() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await environment.sharing.revokeInvitations(for: roomID)
            dismiss()
        } catch {
            self.error = LedgerErrorMessages.text(for: error)
        }
    }
}

extension InvitationDTO {
    /// Not turned off and not expired.
    var isActive: Bool {
        revokedAt == nil && (RemoteRoomMapper.timestamp(expiresAt).map { $0 > .now } ?? true)
    }
}

/// A crisp QR code (Core Image, no dependency), drawn with nearest-neighbour scaling and a quiet zone.
struct QRCodeView: View {
    let text: String

    var body: some View {
        if let image = Self.image(for: text) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(SUSpacing.md)
                .background(Color.white, in: SUShape.compact)
        } else {
            Image(systemName: "qrcode").font(.system(size: 120)).accessibilityHidden(true)
        }
    }

    static func image(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
