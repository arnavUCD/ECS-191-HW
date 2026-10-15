import Foundation

/// The owner's invitations to a shared group: listing them in every state, turning one off, and
/// the links of ones this account made, kept in the Keychain (per account) while they can be used.
extension SharedGroupsService {
    /// The owner's invitations, every state. Links of ones that can no longer be used are forgotten.
    func invitations(for groupID: GroupID) async throws(LedgerError) -> [GroupInvitationDTO] {
        guard let api else { throw .remote(.notConfigured) }
        do {
            let invitations = try await api.invitations(group: SharedGroupMapper.id(groupID))
            for invitation in invitations where invitation.state(at: now()) != .unused {
                forgetLink(for: invitation.invitationId)
            }
            return invitations
        } catch {
            throw LedgerError.from(error)
        }
    }

    @discardableResult
    func revokeInvitation(_ invitationID: String, in groupID: GroupID) async throws(LedgerError) -> GroupInvitationDTO {
        guard let api else { throw .remote(.notConfigured) }
        do {
            let invitation = try await api.revokeInvitation(invitationID, group: SharedGroupMapper.id(groupID))
            forgetLink(for: invitationID)
            return invitation
        } catch {
            throw LedgerError.from(error)
        }
    }

    nonisolated struct InvitationLink: Codable, Equatable, Sendable {
        let code: String
        let url: String
        let appUrl: String?
    }

    /// The link of an invitation this account created on this iPhone, while it can still be used.
    func savedLink(for invitationID: String) -> InvitationLink? {
        guard let accountID, let data = invitationLinks.data(for: Self.linkKey(accountID, invitationID)) else { return nil }
        return try? JSONDecoder().decode(InvitationLink.self, from: data)
    }

    func saveLink(_ link: InvitationLink, for invitationID: String) {
        guard let accountID, let data = try? JSONEncoder().encode(link) else { return }
        _ = invitationLinks.set(data, for: Self.linkKey(accountID, invitationID))
    }

    func forgetLink(for invitationID: String) {
        guard let accountID else { return }
        _ = invitationLinks.remove(Self.linkKey(accountID, invitationID))
    }

    private nonisolated static func linkKey(_ accountID: String, _ invitationID: String) -> String { "\(accountID).\(invitationID)" }
}
