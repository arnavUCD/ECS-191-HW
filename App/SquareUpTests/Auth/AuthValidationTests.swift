import Foundation
@testable import SquareUp
import Testing

@Suite("Account forms · validation")
struct AuthValidationTests {
    @Test(arguments: ["maya@example.com", "a.b+tag@sub.example.co", " maya@example.com "])
    func plausibleEmails(_ email: String) {
        #expect(AuthValidation.emailIssue(email) == nil)
    }

    @Test(arguments: ["", "maya", "maya@", "@example.com", "maya@example", "maya@example.", "ma ya@example.com", "a@b@c.com"])
    func implausibleEmails(_ email: String) {
        #expect(AuthValidation.emailIssue(email) != nil)
    }

    @Test func namesAreRequiredAndBounded() {
        #expect(AuthValidation.nameIssue("   ") != nil)
        #expect(AuthValidation.nameIssue("Maya") == nil)
        #expect(AuthValidation.nameIssue(String(repeating: "a", count: 60)) == nil)
        #expect(AuthValidation.nameIssue(String(repeating: "a", count: 61)) != nil, "the server's limit")
    }

    @Test func aCompleteFormHasNoIssues() {
        #expect(AuthFixtures.form.issues(rules: PasswordRules()).isEmpty)
    }

    @Test func everyFieldExplainsItsOwnProblem() {
        let form = SignUpForm(name: "", email: "maya@", password: "short", confirmation: "shorter")
        let issues = form.issues(rules: PasswordRules())
        #expect(Set(issues.keys) == [.name, .email, .password, .confirmation])
        #expect(issues[.confirmation] == AuthValidation.confirmationIssue(password: "short", confirmation: "shorter"))
        let missing = SignUpForm(name: "Maya", email: "maya@example.com", password: "long-enough-1", confirmation: "")
        #expect(missing.issues(rules: PasswordRules()).keys.contains(.confirmation))
    }

    @Test func squareUpAsksForAtLeastEightCharacters() {
        let rules = PasswordRules()
        #expect(rules.minimumLength == 8)
        #expect(!rules.accepts("1234567") && rules.accepts("12345678"))
        #expect(rules.requirements(for: "").map(\.id) == ["length"])
        // Firebase's built-in floor (6) never lowers it.
        #expect(PasswordRules(policy: AccountSession.PasswordPolicy(minimumLength: 6)).minimumLength == 8)
    }

    @Test func anEnforcedProjectPolicyAddsItsRequirements() {
        let policy = AccountSession.PasswordPolicy(minimumLength: 12, maximumLength: 30, requiresLowercase: true, requiresUppercase: true,
                                                   requiresNumber: true, requiresSymbol: true)
        let rules = PasswordRules(policy: policy)
        #expect(rules.minimumLength == 12)
        let weak = rules.requirements(for: "password")
        #expect(weak.map(\.id) == ["length", "lower", "upper", "number", "symbol"])
        #expect(weak.filter(\.isMet).map(\.id) == ["lower"])
        #expect(rules.accepts("Correct-Horse-9"))
        #expect(!rules.accepts(String(repeating: "Aa1!", count: 9)), "over the maximum")
    }

    @Test func noticesUseWordsAndSayWhetherSomethingWentWrong() {
        let all: [AuthNotice] = [.sessionEnded, .signedOut, .offline, .serviceUnavailable, .verificationNotSent, .verificationSent,
                                 .notVerifiedYet, .problem("Nope")]
        #expect(all.allSatisfy { !$0.message.isEmpty })
        #expect(all.filter { !$0.isProblem } == [.signedOut, .verificationSent])
    }
}
