import Foundation
import SnapshotTesting
@testable import SquareUp
import SwiftUI
import Testing
import UIKit

/// Phone sign-in screens (dark, narrow, and an accessibility text size), driven through
/// `AuthCoordinator` with a fake backend: no Firebase, no text message. Numbers are fictional.
@Suite("Snapshots · phone sign-in", .serialized)
@MainActor
struct PhoneAuthSnapshotTests {
    private func assertScreen<V: View>(
        _ view: V, named name: String, size: CGSize = SnapshotHost.phone, style: UIUserInterfaceStyle = .dark,
        fileID: StaticString = #fileID, file: StaticString = #filePath, testName: String = #function, line: UInt = #line, column: UInt = #column
    ) async {
        let image = await SnapshotHost.render(view, size: size, style: style, settle: .milliseconds(1500))
        assertSnapshot(of: image, as: .image(precision: 0.99), named: name, fileID: fileID, file: file, testName: testName, line: line, column: column)
    }

    private func host(_ auth: AuthCoordinator, @ViewBuilder _ content: () -> some View) -> some View {
        let environment = AppEnvironment(ledger: InMemoryLedgerStore(nil), connectivity: ConnectivityMonitor(forcedStatus: .online),
                                         configuration: LaunchConfiguration(isUITesting: true), fixedNow: DemoScenario.fixedReferenceDate)
        // Rendered off screen there's no active scene; the app-switcher shield would cover everything.
        return NavigationStack { content() }
            .environment(\.scenePhase, .active)
            .environment(environment)
            .environment(auth)
            .environment(AppRouter())
            .squareUpTheme()
    }

    private func coordinator(_ configure: (FakeAuthBackend) -> Void = { _ in }) async -> AuthCoordinator {
        let backend = FakeAuthBackend()
        backend.isPhoneSignInAvailable = true
        configure(backend)
        let auth = AuthCoordinator.make(backend)
        await auth.start()
        return auth
    }

    @Test func createAccountWithPhone() async {
        let auth = await coordinator()
        auth.show(.createAccount)
        auth.phone.draft = PhoneDraft(regionCode: "US", text: "(650) 555-3434")
        let view = host(auth) { PhoneEntryView(route: .createAccount) }
        await assertScreen(view, named: "dark")
        await assertScreen(view, named: "narrow", size: SnapshotHost.compactPhone)
        await assertScreen(view.dynamicTypeSize(.accessibility2), named: "ax2", size: CGSize(width: 402, height: 1900))
    }

    @Test func signInWithPhone() async {
        let auth = await coordinator()
        auth.show(.signIn)
        auth.phone.draft = PhoneDraft(regionCode: "GB", text: "")
        await assertScreen(host(auth) { PhoneEntryView(route: .signIn) }, named: "dark")
    }

    @Test func codeEntry() async throws {
        let auth = await coordinator()
        auth.show(.signIn)
        try await auth.phone.sendCode(to: "+16505553434", purpose: .signIn)
        let view = host(auth) { PhoneCodeView() }
        await assertScreen(view, named: "dark")
        await assertScreen(view.dynamicTypeSize(.accessibility2), named: "ax2", size: CGSize(width: 402, height: 1700))
    }

    @Test func emailOffersPhoneBack() async {
        let auth = await coordinator()
        auth.show(.signIn)
        auth.phone.use(.email, for: .signIn)
        await assertScreen(host(auth) { SignInView() }, named: "dark")
    }

    @Test func nameAfterANewNumberFromSignIn() async throws {
        let auth = await coordinator { backend in backend.profileResult = .success(nil) }
        auth.show(.signIn)
        try await auth.phone.sendCode(to: "+16505553434", purpose: .signIn)
        try await auth.phone.verify(code: "123456")
        await assertScreen(host(auth) { ProfileNameView() }, named: "dark")
    }

    @Test func signInMethods() async {
        let email = await coordinator { backend in
            backend.stored = AuthFixtures.stored(verified: true)
            backend.restoreResult = .success(AuthFixtures.verified)
        }
        await assertScreen(host(email) { SignInMethodsView() }, named: "email-dark")
        let phone = await coordinator { backend in
            backend.stored = AccountSession.StoredAccount(userID: "uid-phone", email: nil, emailVerified: nil, createdAt: AuthFixtures.created,
                                                          hasProfile: true, phoneNumber: "+16505553434")
            backend.restoreResult = .success(AuthFixtures.phoneAccount)
        }
        await assertScreen(host(phone) { SignInMethodsView() }, named: "phone-dark")
    }
}
