import Foundation
import Observation

/// What someone typed into "Find a person", checked before anything is sent: an email address
/// (trimmed, lower-cased) or a phone number in E.164, the only forms the server accepts.
nonisolated enum PersonIdentifier: Equatable, Sendable {
    case email(String)
    case phone(String)

    nonisolated enum Kind: String, CaseIterable, Identifiable, Sendable {
        case email
        case phone

        var id: String { rawValue }
    }

    nonisolated enum Check: Equatable, Sendable {
        case empty
        case invalid(Kind)
        case valid(PersonIdentifier)
    }

    var request: PersonLookupRequest {
        switch self {
        case .email(let address): PersonLookupRequest(email: address)
        case .phone(let number): PersonLookupRequest(phone: number)
        }
    }

    /// An address Firebase could have verified: one `@`, a dotted domain, no spaces.
    static func checkEmail(_ text: String) -> Check {
        let address = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !address.isEmpty else { return .empty }
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        guard address.count <= 254, parts.count == 2, (1...64).contains(parts[0].count), !address.contains(where: \.isWhitespace) else {
            return .invalid(.email)
        }
        let labels = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return .invalid(.email) }
        return .valid(.email(address))
    }

    /// A number in `region`, or any country's when it starts with `+` (or `00`).
    @MainActor
    static func checkPhone(_ text: String, region: PhoneRegion, numbers: PhoneNumbers = .shared) -> Check {
        switch numbers.check(text, region: numbers.regionOfInternational(text) ?? region) {
        case .empty: .empty
        case .valid(let e164): .valid(.phone(e164))
        case .incomplete, .invalid: .invalid(.phone)
        }
    }
}

/// "Find a person" for one shared group: look someone up by email or phone, invite them, and see
/// (and cancel) the invitations this person sent — or, for the owner, everyone's. The view only
/// renders this state; the server decides who can be found and invited.
@Observable
final class FindPersonModel {
    enum Phase: Equatable {
        case idle
        case searching
        /// Nobody can be invited with that (always the same answer, whatever the reason).
        case noMatch
        case found(PersonMatchDTO, PersonIdentifier)
        case sending(PersonMatchDTO, PersonIdentifier)
        case sent(SentInvitationDTO)
        case failed(String)
    }

    let groupID: GroupID
    var kind: PersonIdentifier.Kind = .email {
        didSet { if kind != oldValue { edited() } }
    }

    var text = "" {
        didSet { if text != oldValue { edited() } }
    }

    let region: PhoneRegion
    private(set) var phase: Phase = .idle
    /// Shows why the entry can't be searched yet, once the person has tried.
    private(set) var showsIssue = false
    private(set) var sentInvitations: [SentInvitationDTO] = []
    private(set) var listError: String?
    private(set) var cancelling: Set<String> = []

    @ObservationIgnored private let service: SharedGroupsService

    init(groupID: GroupID, service: SharedGroupsService, region: PhoneRegion = PhoneNumbers.shared.defaultRegion) {
        self.groupID = groupID
        self.service = service
        self.region = region
    }

    var check: PersonIdentifier.Check {
        switch kind {
        case .email: PersonIdentifier.checkEmail(text)
        case .phone: PersonIdentifier.checkPhone(text, region: region)
        }
    }

    var issue: String? {
        guard showsIssue, case .invalid(let kind) = check else { return nil }
        switch kind {
        case .email: return String(localized: "Enter a full email address, like name@example.com.")
        case .phone: return String(localized: "Enter a phone number with its area code. For another country, start with + and its code.")
        }
    }

    var isBusy: Bool {
        switch phase {
        case .searching, .sending: true
        default: false
        }
    }

    func search() async {
        guard case .valid(let person) = check else {
            showsIssue = true
            return
        }
        phase = .searching
        do {
            let match = try await service.lookUpPerson(person, in: groupID)
            phase = match.map { .found($0, person) } ?? .noMatch
        } catch {
            phase = .failed(LedgerErrorMessages.text(for: error))
        }
    }

    func invite() async {
        guard case .found(let match, let person) = phase, match.status == "available" else { return }
        phase = .sending(match, person)
        do {
            let invitation = try await service.invitePerson(person, to: groupID)
            text = "" // still sending, so this doesn't reset the phase
            phase = .sent(invitation)
            await loadSent()
        } catch {
            phase = .failed(LedgerErrorMessages.text(for: error))
        }
    }

    /// Back to an empty search after an invitation went out.
    func startOver() {
        text = ""
        phase = .idle
        showsIssue = false
    }

    func loadSent() async {
        do {
            sentInvitations = try await service.sentInvitations(in: groupID)
            listError = nil
        } catch {
            listError = String(localized: "Couldn't load the invitations you sent. \(LedgerErrorMessages.text(for: error))")
        }
    }

    func cancel(_ invitation: SentInvitationDTO) async {
        cancelling.insert(invitation.id)
        defer { cancelling.remove(invitation.id) }
        do {
            let cancelled = try await service.cancelSentInvitation(invitation.id, in: groupID)
            sentInvitations = sentInvitations.map { $0.id == cancelled.id ? cancelled : $0 }
            listError = nil
        } catch {
            listError = LedgerErrorMessages.text(for: error)
            await loadSent()
        }
    }

    /// Typing something else (or switching between email and phone) starts a new search.
    private func edited() {
        guard !isBusy else { return }
        phase = .idle
        showsIssue = false
    }
}
