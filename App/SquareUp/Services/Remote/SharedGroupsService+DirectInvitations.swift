import Foundation
import OSLog

/// "Find a person": looking someone up by email or phone, inviting them, and the invitations this
/// account sent. Any member of a shared group can do this; nothing about the group changes until
/// the person accepts. The address or number is sent only to look them up, in a request body
/// (`SharedGroupAPI`), and is never logged or kept on this iPhone.
/// The invitations someone receives wait in `receivedInvitations` until they're answered.
extension SharedGroupsService {
    /// The account it belongs to, or `nil` when nobody can be invited with it (the same answer
    /// whatever the reason: no account, not verified, or no name chosen yet).
    func lookUpPerson(_ person: PersonIdentifier, in groupID: GroupID) async throws(LedgerError) -> PersonMatchDTO? {
        guard let api else { throw .remote(.notConfigured) }
        do {
            return try await api.lookUpPerson(person.request, group: SharedGroupMapper.id(groupID))
        } catch {
            throw LedgerError.from(error)
        }
    }

    /// Sends one invitation, waiting for the person to accept in their own Groups tab.
    func invitePerson(_ person: PersonIdentifier, to groupID: GroupID) async throws(LedgerError) -> SentInvitationDTO {
        guard let api else { throw .remote(.notConfigured) }
        do {
            let invitation = try await api.sendInvitation(to: person.request, group: SharedGroupMapper.id(groupID))
            Log.sync.info("Sent a direct invitation")
            return invitation
        } catch {
            throw LedgerError.from(error)
        }
    }

    /// The ones this account sent to this group (the owner: everyone's), newest first.
    func sentInvitations(in groupID: GroupID) async throws(LedgerError) -> [SentInvitationDTO] {
        guard let api else { throw .remote(.notConfigured) }
        do {
            return try await api.sentInvitations(group: SharedGroupMapper.id(groupID))
        } catch {
            throw LedgerError.from(error)
        }
    }

    func cancelSentInvitation(_ invitationID: String, in groupID: GroupID) async throws(LedgerError) -> SentInvitationDTO {
        guard let api else { throw .remote(.notConfigured) }
        do {
            return try await api.cancelSentInvitation(invitationID, group: SharedGroupMapper.id(groupID))
        } catch {
            throw LedgerError.from(error)
        }
    }

    // MARK: - Invitations sent to this account

    /// Reads the invitations waiting for this account. Keeps the last list when offline (or when
    /// the server predates direct invitations).
    func refreshReceivedInvitations() async {
        guard let api, isReady else { return }
        if let invitations = try? await api.receivedInvitations() { receivedInvitations = invitations }
    }

    /// Joins the group it's for, with this account's name (needs a live answer; never queued).
    /// Only now does the group, its people, and its balances reach this iPhone.
    func accept(_ invitation: ReceivedInvitationDTO) async throws(LedgerError) -> GroupID {
        guard let api else { throw .remote(.notConfigured) }
        let response: AcceptGroupInvitationResponse
        do {
            response = try await api.acceptReceivedInvitation(invitation.invitationId)
        } catch {
            // It may have ended meanwhile (cancelled, expired, the group archived): show what's left.
            await refreshReceivedInvitations()
            throw LedgerError.from(groupInvitation: error)
        }
        receivedInvitations.removeAll { $0.id == invitation.id }
        guard let id = GroupID(string: response.snapshot.group.id) else { throw .remote(.unavailable) }
        _ = register(response.snapshot)
        Log.sync.info("Joined a shared group from a direct invitation")
        return id
    }

    /// Says no; the person who sent it sees it was declined. Nothing else changes.
    func decline(_ invitation: ReceivedInvitationDTO) async throws(LedgerError) {
        guard let api else { throw .remote(.notConfigured) }
        do {
            _ = try await api.declineReceivedInvitation(invitation.invitationId)
        } catch {
            if case .server(let refusal) = error, refusal.code == "not_found" {
                receivedInvitations.removeAll { $0.id == invitation.id } // already gone
                return
            }
            throw LedgerError.from(error)
        }
        receivedInvitations.removeAll { $0.id == invitation.id }
    }
}
