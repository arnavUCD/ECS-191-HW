import SwiftUI

/// Profile → Account → Sign-in methods: how this account can sign in, and adding a phone number.
/// A number is linked to this same Firebase account after its code is entered — never a second
/// account, and never merged with another account that already uses the number.
struct SignInMethodsView: View {
    @Environment(AuthCoordinator.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @State private var isAddingPhone = false
    @State private var added = false

    private var details: AccountSession.AccountDetails? { auth.details }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let email = details?.email ?? auth.email {
                        methodRow(symbol: "envelope", title: email, verified: details?.emailVerified ?? false,
                                  pending: String(localized: "Not verified"), identifier: "methods.email")
                    } else {
                        Label(String(localized: "Not added"), systemImage: "envelope")
                            .foregroundStyle(SUColor.textSecondary)
                            .accessibilityIdentifier("methods.email.none")
                    }
                } header: {
                    Text(String(localized: "Email and password"))
                } footer: {
                    if details?.email == nil, auth.email == nil {
                        Text(String(localized: "Adding an email and password to a phone account is coming in a later version."))
                    }
                }
                Section {
                    if let phone = details?.phoneNumber {
                        methodRow(symbol: "phone", title: PhoneNumbers.shared.display(phone), verified: true,
                                  pending: "", identifier: "methods.phone")
                    } else if auth.phone.isAvailable {
                        Button {
                            isAddingPhone = true
                        } label: {
                            Label(String(localized: "Add phone number"), systemImage: "plus.circle")
                        }
                        .accessibilityIdentifier("methods.addPhone")
                    } else {
                        Label(String(localized: "Phone sign-in isn't available in this build"), systemImage: "phone")
                            .foregroundStyle(SUColor.textSecondary)
                    }
                } header: {
                    Text(String(localized: "Phone number"))
                } footer: {
                    Text(details?.phoneNumber == nil
                        ? String(localized: "Sign in with a text message code instead of a password. Google's Firebase processes your number to send codes and prevent abuse.")
                        : String(localized: "You can sign in with a text message code sent to this number."))
                }
                if added {
                    Section {
                        Label(String(localized: "Phone number added. You can now sign in with it."), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(SUColor.positive)
                            .accessibilityIdentifier("methods.added")
                    }
                }
            }
            .suListRows()
            .scrollContentBackground(.hidden)
            .suScreenBackground()
            .navigationTitle(String(localized: "Sign-in methods"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(String(localized: "Done")) { dismiss() } }
            }
            .navigationDestination(isPresented: $isAddingPhone) {
                AddPhoneNumberView { added = true }
            }
        }
        .onAppear { if auth.phone.pendingLink != nil { isAddingPhone = true } }
    }

    private func methodRow(symbol: String, title: String, verified: Bool, pending: String, identifier: String) -> some View {
        HStack {
            Label {
                Text(verbatim: title).foregroundStyle(SUColor.textPrimary).lineLimit(1).truncationMode(.middle)
            } icon: {
                Image(systemName: symbol)
            }
            Spacer(minLength: SUSpacing.xs)
            Label(verified ? String(localized: "Verified") : pending, systemImage: verified ? "checkmark.seal.fill" : "exclamationmark.circle")
                .font(SUFont.metadata)
                .foregroundStyle(verified ? SUColor.positive : SUColor.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }
}

/// Add a phone number: the number, then its code. Linked to the signed-in account.
private struct AddPhoneNumberView: View {
    let onAdded: () -> Void
    @Environment(AuthCoordinator.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @State private var draft = PhoneDraft()
    @State private var issue: String?
    @State private var code = ""
    @State private var failure: AuthFailure?
    @FocusState private var numberFocused: Bool
    @FocusState private var codeFocused: Bool

    private var phone: PhoneSignIn { auth.phone }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SUSpacing.lg) {
                if let pending = phone.pendingLink {
                    SUHeadline(primary: String(localized: "Enter the code"),
                               secondary: String(localized: "Sent to \(PhoneNumbers.shared.display(pending.phoneNumber))"))
                    if let failure {
                        SUInlineStatus(text: failure.message, identifier: "addPhone.failure")
                    } else if let notice = phone.notice {
                        SUInlineStatus(text: notice.message, isProblem: notice.isProblem)
                    }
                    SUCodeField(code: $code, isInvalid: failure == .account(.invalidCode), identifier: "addPhone.code", isFocused: $codeFocused) { _ in link() }
                    Button(action: link) {
                        SUProgressLabel(title: String(localized: "Add number"), workingTitle: String(localized: "Verifying…"), isWorking: phone.isWorking)
                    }
                    .buttonStyle(.suGlassPrimary)
                    .disabled(phone.isWorking || code.count < 6)
                    .accessibilityIdentifier("addPhone.verify")
                    PhoneResendButton()
                    Button(String(localized: "Use a different number")) {
                        phone.forgetVerification()
                        code = ""
                        failure = nil
                    }
                    .buttonStyle(.suText)
                    .accessibilityIdentifier("addPhone.changeNumber")
                } else {
                    SUHeadline(primary: String(localized: "Add a phone number"),
                               secondary: String(localized: "We'll text a code to confirm it's yours."))
                    if let failure { SUInlineStatus(text: failure.message, identifier: "addPhone.failure") }
                    PhoneNumberField(draft: $draft, issue: issue, isFocused: $numberFocused, identifier: "addPhone.number", onSubmit: send)
                    Text(String(localized: """
                    We'll send a one-time code to verify your number. Standard message rates may apply. \
                    Google's Firebase processes your number to send the code and to prevent spam and abuse.
                    """))
                    .font(SUFont.metadata)
                    .foregroundStyle(SUColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    Button(action: send) {
                        SUProgressLabel(title: String(localized: "Send code"), workingTitle: String(localized: "Sending code…"), isWorking: phone.isWorking)
                    }
                    .buttonStyle(.suGlassPrimary)
                    .disabled(phone.isWorking)
                    .accessibilityIdentifier("addPhone.send")
                    PhoneCooldownNote()
                }
            }
            .padding(.horizontal, SUSpacing.screenMargin)
            .padding(.vertical, SUSpacing.lg)
            .frame(maxWidth: SUMetrics.readableWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .suScreenBackground()
        .navigationTitle(String(localized: "Add phone number"))
        .navigationBarTitleDisplayMode(.inline)
        .privacyShieldWhenInactive()
    }

    private func send() {
        guard !phone.isWorking else { return }
        failure = nil
        let region = PhoneNumbers.shared.region(draft.regionCode ?? "") ?? PhoneNumbers.shared.defaultRegion
        guard let e164 = PhoneNumbers.shared.check(draft.text, region: region).e164 else {
            issue = String(localized: "Enter a valid \(region.name()) mobile number, or choose a different country.")
            numberFocused = true
            return
        }
        issue = nil
        Task {
            do throws(AuthFailure) {
                try await phone.sendCode(to: e164, purpose: .link)
                codeFocused = true
            } catch {
                failure = error
                AccessibilityNotification.Announcement(error.message).post()
            }
        }
    }

    private func link() {
        guard !phone.isWorking, code.count == 6 else { return }
        failure = nil
        let entered = code
        Task {
            do throws(AuthFailure) {
                try await phone.link(code: entered)
                onAdded()
                dismiss()
            } catch {
                failure = error
                code = ""
                AccessibilityNotification.Announcement(error.message).post()
            }
        }
    }
}
