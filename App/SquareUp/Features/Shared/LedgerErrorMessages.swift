import Foundation

/// Plain-language explanations for every ledger error. Each message says what happened and that
/// nothing was changed, and — where possible — what to do next.
nonisolated enum LedgerErrorMessages {
    static func text(for error: LedgerError, members: [MemberID: Member] = [:], locale: Locale = .autoupdatingCurrent) -> String {
        func name(_ id: MemberID) -> String { members[id]?.displayName ?? String(localized: "This person") }
        let money = { (value: Money) in MoneyFormatting.string(value, locale: locale) }

        switch error {
        case .invalidExpense:
            return String(localized: "The split doesn't add up yet. Nothing was saved.")
        case .groupNotFound:
            return String(localized: "This group is no longer available. Nothing was saved.")
        case .currentUserMissing, .storage, .unavailable:
            return String(localized: "Couldn't save right now. Nothing was changed — try again.")
        case .invalidDestination(let reason):
            return text(for: reason)
        case .invalidTransition(.notAuthorized):
            return String(localized: "Only the payer or recipient of this payment can do that.")
        case .invalidTransition(.notAllowed):
            return String(localized: "This payment has already moved on, so that action no longer applies.")
        case .remote(let issue):
            return text(for: issue)
        case .receipt(let receiptError):
            return ReceiptLanguage.error(receiptError, names: ReceiptLanguage.names(members), locale: locale)
        case .rule(let violation):
            switch violation {
            case .groupNameRequired: return String(localized: "Give the group a name.")
            case .textTooLong: return String(localized: "That's a little long — please shorten it.")
            case .memberNameRequired: return String(localized: "Enter the person's full name.")
            case .invalidHandle: return String(localized: "Handles can use letters, numbers, dots, dashes, and underscores.")
            case .memberAlreadyInGroup(let id): return String(localized: "\(name(id)) is already in this group.")
            case .memberNotFound: return String(localized: "That person couldn't be found.")
            case .notAGroupMember: return String(localized: "That person isn't an active member of this group.")
            case .cannotRemoveYourself: return String(localized: "You can't remove yourself from a group.")
            case .memberHasBalance(let id, let balance):
                return balance.isPositive
                    ? String(localized: "\(name(id)) is still owed \(money(balance)). Settle up before removing them.")
                    : String(localized: "\(name(id)) still owes \(money(balance.magnitude)). Settle up before removing them.")
            case .memberHasOpenPayment(let id): return String(localized: "\(name(id)) has a payment in progress. Resolve it before removing them.")
            case .currencyLocked: return String(localized: "The currency can't change once the group has expenses or payments.")
            case .expenseNotFound: return String(localized: "This expense no longer exists.")
            case .expenseDeleted: return String(localized: "This expense was deleted. Restore it before editing.")
            case .expenseNotDeleted: return String(localized: "This expense isn't deleted.")
            case .inactiveParticipant(let id): return String(localized: "\(name(id)) is no longer in this group, so they can't be added to new expenses.")
            case .pendingPaymentConflict:
                return String(localized: "A payment that affects these balances is awaiting confirmation. Confirm, reject, or cancel it first, then try again.")
            case .destinationNotFound: return String(localized: "That payment method was removed.")
            case .notDestinationOwner: return String(localized: "Only the owner can change their payment methods.")
            case .destinationUnavailable: return String(localized: "That payment method isn't available anymore. Choose another.")
            case .cannotPaySelf: return String(localized: "You can't pay yourself.")
            case .nonPositiveAmount: return String(localized: "Enter an amount greater than zero.")
            case .currencyMismatch: return String(localized: "Payments must be in the group's currency.")
            case .noObligation: return String(localized: "Nothing is owed here anymore. Balances may have changed.")
            case .exceedsObligation(let owed):
                return String(localized: "That's more than is currently owed (\(money(owed))). Balances may have changed.")
            case .attemptNotFound: return String(localized: "That payment couldn't be found.")
            }
        }
    }

    static func text(for issue: RemoteIssue) -> String {
        switch issue {
        case .notConfigured:
            return String(localized: "Sharing isn't set up in this build of Square Up.")
        case .offline:
            return String(localized: "You're offline. Nothing changed — try again when you're connected.")
        case .conflict:
            return String(localized: "Someone changed this first, so your change wasn't saved. Check the latest and try again.")
        case .accessEnded:
            return String(localized: "Your access to this room has ended. Ask the host for a new invitation.")
        case .guestsNeedMatching:
            return String(localized: "Match each guest to someone in the group before saving the expense.")
        case .signInFailed(let failure):
            return text(for: failure)
        case .refused(let message):
            return message
        case .unavailable:
            return String(localized: "Couldn't reach Square Up right now. Nothing changed — try again.")
        case .connectionRequired:
            return String(localized: "This needs a connection to the server. Nothing was changed — try again when you're online.")
        case .removedFromGroup:
            return String(localized: "You're no longer in this group. Its history stays with the people still in it.")
        case .invitation(let reason):
            return text(for: reason)
        case .emailNotVerified:
            return String(localized: "Verify your email address to use shared groups. Nothing was changed.")
        }
    }

    static func text(for issue: GroupInvitationIssue) -> String {
        switch issue {
        case .invalid: String(localized: "This invitation isn't valid. Check the code, or ask for a new invitation.")
        case .expired: String(localized: "This invitation expired. Ask for a new one.")
        case .revoked: String(localized: "This invitation was turned off. Ask for a new one.")
        case .used: String(localized: "This invitation was already used. Each invitation works once — ask for a new one.")
        case .alreadyMember: String(localized: "You're already in this group.")
        case .archived: String(localized: "This group was archived, so no one new can join.")
        case .seatUnavailable: String(localized: "The place this invitation was for is no longer available. Ask for a new invitation.")
        case .accountRequired: String(localized: "Add an email and password to your account to join shared groups.")
        case .profileRequired: String(localized: "Choose the name people will see before joining.")
        case .groupFull: String(localized: "This group already has 25 people, its limit. Ask the owner about it.")
        }
    }

    static func text(for failure: AccountSession.Failure) -> String {
        switch failure {
        case .notConfigured: String(localized: "Accounts aren't set up in this build of Square Up.")
        case .offline: String(localized: "You're offline. Try again when you're connected.")
        case .invalidCredentials: String(localized: "That email and password don't match. Check them and try again.")
        case .emailInUse: String(localized: "That email can't be used for a new account. If it's yours, sign in instead.")
        case .invalidEmail: String(localized: "Enter a valid email address.")
        case .weakPassword: String(localized: "That password doesn't meet the requirements. Choose a longer or stronger one.")
        case .tooManyAttempts: String(localized: "Too many attempts. Wait a few minutes and try again.")
        case .sessionEnded: String(localized: "Your session ended. Sign in again to continue.")
        case .signedOut: String(localized: "Sign in to continue.")
        case .accountDisabled: String(localized: "This account can't be used right now.")
        case .operationNotAllowed: String(localized: "Email sign-in isn't available right now. Try again later.")
        case .recentSignInRequired: String(localized: "For your security, sign in again before making this change.")
        case .unavailable: String(localized: "Couldn't reach the account service. Try again.")
        case .invalidPhoneNumber: String(localized: "Check the number and its country, then try again.")
        case .invalidCode: String(localized: "That code isn't right. Check the latest text message and try again.")
        case .codeExpired: String(localized: "That code has expired. Send a new one.")
        case .codeCooldown: String(localized: "Wait a moment before asking for another code.")
        case .smsQuotaExceeded: String(localized: "Square Up can't send more codes right now. Try again later, or use email instead.")
        case .phoneInUse: String(localized: "This number is already used by another Square Up account. Use a different number, or sign in with that one separately.")
        case .verificationCancelled: String(localized: "The check was closed before it finished. Tap Continue to try again.")
        case .appVerificationFailed: String(localized: "Square Up couldn't confirm this request came from the app. Try again, or use email instead.")
        case .phoneNotAllowed: String(localized: "Phone sign-in isn't available for this number yet. Use email instead.")
        }
    }

    static func text(for error: DestinationValidationError) -> String {
        switch error {
        case .missingValue: String(localized: "Enter the details friends will use to pay you.")
        case .invalidPhone: String(localized: "Enter a 10-digit US phone number.")
        case .invalidEmail: String(localized: "Enter a valid email address.")
        case .invalidPhoneOrEmail: String(localized: "Enter a US phone number or an email address.")
        case .invalidUsername: String(localized: "That username doesn't look right for this service.")
        case .invalidLink: String(localized: "That link isn't from this service. Only official https links can be added.")
        case .missingLabel: String(localized: "Give this method a name.")
        case .tooLong: String(localized: "That's a little long — please shorten it.")
        }
    }
}
