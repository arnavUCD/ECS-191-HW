import Foundation
import SnapshotTesting
@testable import SquareUp
import SwiftUI
import Testing
import UIKit

/// The launch flow's screens — light, dark, narrow, and an accessibility text size — each driven
/// into its state through `AuthCoordinator` with a fake backend (no network).
@Suite("Snapshots · sign-in and first run", .serialized)
@MainActor
struct AuthSnapshotTests {
    typealias Fix = AuthFixtures

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
        return NavigationStack { content() }
            .environment(environment)
            .environment(auth)
            .environment(AppRouter())
            .squareUpTheme()
    }

    private func coordinator(_ configure: (FakeAuthBackend) -> Void) async -> AuthCoordinator {
        let backend = FakeAuthBackend()
        configure(backend)
        let auth = AuthCoordinator.make(backend)
        await auth.start()
        return auth
    }

    @Test func welcome() async {
        let auth = await coordinator { _ in }
        let view = host(auth) { WelcomeView() }
        await assertScreen(view, named: "dark")
        await assertScreen(view, named: "narrow", size: SnapshotHost.compactPhone)
        await assertScreen(view.dynamicTypeSize(.accessibility3), named: "ax3", size: CGSize(width: 402, height: 1400))
    }

    @Test func welcomeWithAWaitingInvitation() async {
        let auth = await coordinator { _ in }
        auth.receive(.group(code: "ABCD2EFGH3JKMN4PQRS5"))
        await assertScreen(host(auth) { WelcomeView() }, named: "dark")
    }

    @Test func createAccount() async {
        let auth = await coordinator { _ in }
        let view = host(auth) { SignUpView() }
        await assertScreen(view, named: "dark", size: CGSize(width: 402, height: 1100))
        await assertScreen(view.dynamicTypeSize(.accessibility2), named: "ax2", size: CGSize(width: 402, height: 2200))
    }

    @Test func signInAfterTheSessionEnded() async {
        let auth = await coordinator { backend in
            backend.stored = Fix.stored(verified: true)
            backend.restoreResult = .failure(.account(.sessionEnded))
        }
        let view = host(auth) { SignInView() }
        await assertScreen(view, named: "dark")
        await assertScreen(view, named: "narrow", size: SnapshotHost.compactPhone)
    }

    @Test func checkYourEmail() async {
        let auth = await coordinator { backend in
            backend.stored = Fix.stored(verified: false, hasProfile: nil)
            backend.restoreResult = .success(Fix.newAccount)
        }
        let view = host(auth) { VerifyEmailView() }
        await assertScreen(view, named: "dark")
        await assertScreen(view.dynamicTypeSize(.accessibility2), named: "ax2", size: CGSize(width: 402, height: 1900))
    }

    @Test func checkYourEmailNotVerifiedYet() async {
        let auth = await coordinator { backend in
            backend.stored = Fix.stored(verified: false, hasProfile: nil)
            backend.restoreResult = .success(Fix.newAccount)
        }
        await auth.checkVerification(userInitiated: true)
        await assertScreen(host(auth) { VerifyEmailView() }, named: "dark")
    }

    @Test func profileName() async {
        let auth = await coordinator { backend in
            backend.stored = Fix.stored(verified: true, hasProfile: false)
            backend.restoreResult = .success(Fix.verified)
            backend.profileResult = .success(nil)
        }
        let view = host(auth) { ProfileNameView() }
        await assertScreen(view, named: "dark")
        await assertScreen(view.dynamicTypeSize(.accessibility2), named: "ax2", size: CGSize(width: 402, height: 1600))
    }

    @Test func setupComplete() async throws {
        let auth = await coordinator { backend in
            backend.stored = Fix.stored(verified: true, hasProfile: false)
            backend.restoreResult = .success(Fix.verified)
            backend.profileResult = .success(nil)
        }
        try await auth.saveProfile(displayName: "Maya Chen")
        auth.finishPaymentStep()
        let view = host(auth) { SetupCompleteView() }
        await assertScreen(view, named: "dark")
    }

    @Test func launch() async {
        let auth = AuthCoordinator.make(FakeAuthBackend())
        await assertScreen(host(auth) { LaunchView() }, named: "dark")
    }
}
