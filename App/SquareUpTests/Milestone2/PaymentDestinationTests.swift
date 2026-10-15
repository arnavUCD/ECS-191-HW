import Foundation
@testable import SquareUp
import Testing

@Suite("M2.4 Destination validation")
struct DestinationValidationTests {
    private func validate(_ provider: PaymentProviderKind, _ primary: String, link: String = "", label: String = "")
        throws(DestinationValidationError) -> PaymentDestinationValidator.Normalized {
        try PaymentDestinationValidator.validate(DestinationInput(provider: provider, primary: primary, link: link, label: label))
    }

    @Test("US phone numbers normalise to E.164", arguments: [
        ("(530) 555-0142", "+15305550142"), ("530.555.0142", "+15305550142"), ("+1 530 555 0142", "+15305550142"), ("15305550142", "+15305550142"),
    ])
    func phones(input: String, expected: String) throws {
        #expect(try validate(.appleCash, input).value == .phone(expected))
        #expect(try validate(.zelle, input).value == .phone(expected))
    }

    @Test("Invalid phones and emails are rejected", arguments: [
        ("555-0142", DestinationValidationError.invalidPhone), ("(030) 555-0142", .invalidPhone), ("+44 20 7946 0958", .invalidPhone),
        ("maya@", .invalidEmail), ("maya at ucdavis", .invalidPhoneOrEmail), ("", .missingValue),
    ])
    func badContacts(input: String, error: DestinationValidationError) {
        #expect(throws: error) { try validate(.appleCash, input) }
    }

    @Test("Emails are lower-cased")
    func email() throws {
        #expect(try validate(.zelle, "Maya.Chen@UCDavis.edu").value == .email("maya.chen@ucdavis.edu"))
    }

    @Test("PayPal.Me names from usernames or official links", arguments: [
        "mayachen", "@mayachen", "paypal.me/mayachen", "https://paypal.me/mayachen", "https://www.paypal.me/mayachen/25",
        "https://www.paypal.com/paypalme/mayachen",
    ])
    func paypal(input: String) throws {
        #expect(try validate(.paypal, input).value == .username("mayachen"))
    }

    @Test("PayPal rejects other hosts, schemes, and malformed names", arguments: [
        "https://evil.example/mayachen", "http://paypal.me/mayachen", "javascript:alert(1)", "maya chen", "paypal.me/", "https://www.paypal.com/maya",
    ])
    func paypalRejects(input: String) {
        #expect(throws: DestinationValidationError.invalidUsername) { try validate(.paypal, input) }
    }

    @Test("Cash App: cashtag, official link, or both")
    func cashApp() throws {
        #expect(try validate(.cashApp, "$MayaC").value == .username("MayaC"))
        let both = try validate(.cashApp, "MayaC", link: "cash.app/$MayaC")
        #expect(both.link == URL(string: "https://cash.app/$MayaC"))
        #expect(try validate(.cashApp, "", link: "https://cash.app/$MayaC").value == .link(URL(string: "https://cash.app/$MayaC")!))
        #expect(throws: DestinationValidationError.invalidLink) { try validate(.cashApp, "MayaC", link: "https://cash.app.evil.com/$MayaC") }
        #expect(throws: DestinationValidationError.invalidLink) { try validate(.cashApp, "MayaC", link: "cashme://MayaC") }
        #expect(throws: DestinationValidationError.invalidLink) { try validate(.cashApp, "", link: "https://cash.app/") }
        #expect(throws: DestinationValidationError.invalidUsername) { try validate(.cashApp, "$1234") }
    }

    @Test("Zelle QR links must be on Zelle's domains")
    func zelle() throws {
        #expect(try validate(.zelle, "maya@ucdavis.edu", link: "https://enroll.zellepay.com/qr-codes?data=abc").link != nil)
        #expect(try validate(.zelle, "maya@ucdavis.edu", link: "https://www.zelle.com/pay/abc").link != nil)
        #expect(throws: DestinationValidationError.invalidLink) {
            try validate(.zelle, "maya@ucdavis.edu", link: "https://zelle.com.attacker.net/qr")
        }
        #expect(throws: DestinationValidationError.invalidLink) {
            try validate(.zelle, "maya@ucdavis.edu", link: "data:text/html,hi")
        }
    }

    @Test("Venmo usernames")
    func venmo() throws {
        #expect(try validate(.venmo, "@alex-morgan").value == .username("alex-morgan"))
        #expect(throws: DestinationValidationError.invalidUsername) { try validate(.venmo, "al") }
        #expect(throws: DestinationValidationError.invalidUsername) { try validate(.venmo, "venmo://paycharge?txn=pay") }
    }

    @Test("Cash defaults its instructions; other requires a name and plain text only")
    func manual() throws {
        #expect(try validate(.cash, "").value == .instructions("Cash in person"))
        #expect(throws: DestinationValidationError.missingLabel) { try validate(.other, "Pay at practice") }
        #expect(try validate(.other, "Pay at practice", label: "Team box").label == "Team box")
        #expect(throws: DestinationValidationError.tooLong) { try validate(.other, String(repeating: "x", count: 141), label: "x") }
    }
}

@Suite("M2.4 URL allowlist")
struct ExternalURLPolicyTests {
    @Test("Only HTTPS on provider hosts", arguments: [
        ("https://paypal.me/maya/10USD", PaymentProviderKind.paypal, true),
        ("http://paypal.me/maya", .paypal, false),
        ("https://paypal.me.evil.com/maya", .paypal, false),
        ("https://user:pass@paypal.me/maya", .paypal, false),
        ("https://paypal.me:8443/maya", .paypal, false),
        ("https://cash.app/$Maya", .cashApp, true),
        ("https://www.cash.app/$Maya", .cashApp, false),
        ("https://enroll.zellepay.com/qr", .zelle, true),
        ("https://zelle.com/x", .zelle, true),
        ("https://venmo.com/u/maya", .venmo, false),
        ("https://example.com", .appleCash, false),
        ("javascript:alert(1)", .paypal, false),
        ("file:///etc/passwd", .cashApp, false),
        ("data:text/plain,hi", .zelle, false),
    ])
    func allowlist(text: String, provider: PaymentProviderKind, allowed: Bool) {
        let isAllowed = URL(string: text).map { ExternalURLPolicy.isAllowed($0, for: provider) } ?? false
        #expect(isAllowed == allowed)
    }

    @Test("Parsing user input rejects explicit non-HTTPS schemes and whitespace")
    func parsing() {
        #expect(ExternalURLPolicy.url(from: "cash.app/$Maya", for: .cashApp) != nil)
        #expect(ExternalURLPolicy.url(from: "javascript:alert(1)", for: .cashApp) == nil)
        #expect(ExternalURLPolicy.url(from: "squareup://x", for: .paypal) == nil)
        #expect(ExternalURLPolicy.url(from: "https://cash.app/$Maya now", for: .cashApp) == nil)
    }
}

@Suite("M2.4 Masking and privacy")
struct DestinationPrivacyTests {
    @Test("Masked display", arguments: [
        (DestinationValue.phone("+15305554821"), PaymentProviderKind.appleCash, "•••-•••-4821"),
        (.email("maya.chen@ucdavis.edu"), .zelle, "m•••@ucdavis.edu"),
        (.username("mayachen"), .paypal, "paypal.me/m•••n"),
        (.username("MayaC"), .cashApp, "$M•••C"),
        (.username("alex-morgan"), .venmo, "@a•••n"),
        (.link(URL(string: "https://cash.app/$MayaC")!), .cashApp, "cash.app/•••"),
    ])
    func masked(value: DestinationValue, provider: PaymentProviderKind, expected: String) {
        #expect(DestinationPresentation.masked(value, provider: provider) == expected)
    }

    @Test("Revealed display for the payer")
    func revealed() {
        #expect(DestinationPresentation.revealed(.phone("+15305554821"), provider: .appleCash) == "(530) 555-4821")
        #expect(DestinationPresentation.revealed(.username("mayachen"), provider: .paypal) == "paypal.me/mayachen")
        #expect(DestinationPresentation.revealed(.username("MayaC"), provider: .cashApp) == "$MayaC")
        #expect(DestinationPresentation.revealed(.username("alex-morgan"), provider: .venmo) == "@alex-morgan")
    }

    @Test("VoiceOver distinguishes masked values without reading them")
    func spoken() {
        let spoken = DestinationPresentation.spokenMasked(.phone("+15305554821"), provider: .appleCash)
        #expect(spoken.contains("4 8 2 1"))
        #expect(!spoken.contains("530"))
        #expect(DestinationPresentation.spokenMasked(.email("maya@ucdavis.edu"), provider: .zelle).contains("ucdavis.edu"))
    }

    @Test("Diagnostic descriptions never contain identifiers")
    func redaction() throws {
        let snapshot = sample()
        for destination in snapshot.paymentDestinations {
            for text in [String(describing: destination), String(reflecting: destination), "\(destination.value)", String(reflecting: destination.value)] {
                switch destination.value {
                case .phone(let raw), .email(let raw), .username(let raw), .instructions(let raw):
                    #expect(!text.contains(raw), "Leaked \(destination.provider.rawValue) value")
                case .link(let url):
                    #expect(!text.contains(url.absoluteString))
                }
            }
        }
        // Containers of destinations (commands, changes) inherit the redaction.
        let maya = try #require(destination(of: People.maya, .appleCash, in: snapshot))
        #expect(!String(describing: LedgerChange.upsertDestination(maya)).contains("5554821"))
    }
}

@Suite("M2.4 Destination rules in the ledger")
struct DestinationRuleTests {
    @Test("Only the owner can change destinations; one preferred at a time; disabled can't be preferred")
    func ownership() throws {
        var harness = EngineHarness(sample())
        var maya = try #require(destination(of: People.maya, .paypal, in: harness.state))
        #expect(throws: LedgerError.rule(.notDestinationOwner)) { try harness.run(.saveDestination(maya)) }
        maya.isPreferred = true
        try harness.run(.saveDestination(maya), as: People.maya)
        let mayas = harness.state.destinations(of: People.maya)
        #expect(mayas.filter(\.isPreferred).map(\.provider) == [.paypal])
        #expect(mayas.first?.provider == .paypal, "Preferred sorts first")

        maya.isEnabled = false
        try harness.run(.saveDestination(maya), as: People.maya)
        #expect(harness.state.destination(maya.id)?.isPreferred == false)
    }

    @Test("Deleting the preferred method promotes the next enabled one")
    func deletePreferred() throws {
        var harness = EngineHarness(sample())
        let preferred = try #require(harness.state.destinations(of: People.maya).first { $0.isPreferred })
        try harness.run(.deleteDestination(preferred.id), as: People.maya)
        #expect(harness.state.destination(preferred.id) == nil)
        #expect(harness.state.destinations(of: People.maya).filter(\.isPreferred).count == 1)
    }

    @Test("A bypassed UI can't store a non-allowlisted link")
    func defenceInDepth() {
        var harness = EngineHarness(sample())
        let sneaky = PaymentDestination(ownerID: People.riley, provider: .cashApp, value: .username("Riley"),
                                        link: URL(string: "https://evil.example/$Riley"), createdAt: harness.now)
        #expect(throws: LedgerError.invalidDestination(.invalidLink)) { try harness.run(.saveDestination(sneaky)) }
    }
}

@Suite("M2.5 Handoff planning")
struct HandoffPlannerTests {
    let snapshot = sample()

    private func plan(_ provider: PaymentProviderKind, owner: MemberID = People.maya, amount: String = "27.83") -> HandoffPlan {
        HandoffPlanner.plan(
            destination: destination(of: owner, provider, in: snapshot), provider: provider, amount: dollars(amount),
            memo: "Square Up · Weekend Trip · SU-4821", reference: "SU-4821", recipientName: "Maya", groupName: "Weekend Trip",
            locale: Locale(identifier: "en_US")
        )
    }

    @Test("Apple Cash: Messages composer, amount copied, honest steps")
    func appleCash() {
        let plan = plan(.appleCash)
        #expect(plan.primaryTitle == "Continue in Messages")
        #expect(plan.capability == .copyAndContinue)
        #expect(plan.action == .composeMessage(recipient: "+15305554821", body: "Square Up: Paying you $27.83 for Weekend Trip. Settlement SU-4821."))
        #expect(plan.copyItems.first?.value == "27.83")
        #expect(plan.steps.contains("In Messages, tap +, choose Apple Cash, paste $27.83, review, and send."))
    }

    @Test("PayPal: amount-specific PayPal.Me link")
    func paypal() {
        let plan = plan(.paypal)
        #expect(plan.capability == .amountPrepared)
        #expect(plan.action == .openURL(URL(string: "https://paypal.me/mayachen/27.83USD")!))
    }

    @Test("Cash App: recipient's official link when present, otherwise copy — never a custom scheme")
    func cashApp() {
        #expect(plan(.cashApp).action == .openURL(URL(string: "https://cash.app/$MayaC")!))
        let jordan = plan(.cashApp, owner: People.jordan)
        #expect(jordan.action == .copyDetails)
        #expect(jordan.copyItems.map(\.value).contains("$JBrooks"))
    }

    @Test("Zelle: copy details, bank finder, irreversibility warning")
    func zelle() {
        let plan = plan(.zelle)
        #expect(plan.action == .copyDetails)
        #expect(plan.copyItems.map(\.value).contains("maya.chen@ucdavis.edu"))
        #expect(plan.secondaryLinks.map(\.url) == [HandoffPlanner.zelleBankFinder])
        #expect(plan.warning?.contains("can't be cancelled") == true)
        #expect(plan.steps.contains { $0.contains("shows Maya as the recipient") })
    }

    @Test("Venmo: guided copy only (no undocumented link)")
    func venmo() {
        let plan = plan(.venmo, owner: People.alexMorgan)
        #expect(plan.action == .copyDetails)
        #expect(plan.copyItems.map(\.value) == ["@alex-morgan", "27.83", "Square Up · Weekend Trip · SU-4821"])
    }

    @Test("Cash and other: record manually")
    func manual() {
        #expect(plan(.cash, owner: People.alexRivera).action == .recordManually)
        #expect(plan(.other, owner: SampleLedger.Person.dev.id).steps.first == "Leave cash in the jar on the beach house counter")
    }

    @Test("Every opened link passes the allowlist, and no plan claims verification or success")
    func honesty() {
        let forbidden = ["verified", "instant", "secure", "paid successfully", "payment complete"]
        for provider in PaymentProviderKind.allCases {
            for owner in [People.maya, People.alexMorgan, People.jordan, People.alexRivera, SampleLedger.Person.dev.id] {
                let plan = plan(provider, owner: owner)
                if case .openURL(let url) = plan.action { #expect(ExternalURLPolicy.isAllowed(url, for: provider)) }
                let text = ([plan.primaryTitle, plan.capability.label, plan.warning ?? ""] + plan.steps).joined(separator: " ").lowercased()
                for word in forbidden { #expect(!text.contains(word), "\(provider) plan says \(word)") }
            }
        }
    }

    @Test("Incomplete destinations fall back to copying the amount")
    func unavailable() {
        let broken = PaymentDestination(ownerID: People.maya, provider: .paypal, value: .username("bad name"), createdAt: .now)
        #expect(!HandoffPlanner.isUsable(broken))
        let plan = HandoffPlanner.plan(destination: broken, provider: .paypal, amount: dollars("5.00"), memo: "m", reference: "r",
                                       recipientName: "Maya", groupName: "g")
        #expect(plan.action == .copyDetails)
        #expect(plan.warning != nil)
    }
}
