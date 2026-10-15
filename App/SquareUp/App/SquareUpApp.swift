import AppIntents
import SwiftUI

@main
struct SquareUpApp: App {
    /// APNs and Firebase's silent notification for phone verification (nothing else).
    @UIApplicationDelegateAdaptor(SquareUpAppDelegate.self) private var appDelegate
    /// Which account's local data is open (none while signed out), and the environment screens use.
    @State private var session: AppSession
    @State private var router: AppRouter
    @State private var auth: AuthCoordinator

    init() {
        let session = AppSession.live()
        let router = AppRouter()
        let configuration = session.signedOutEnvironment.configuration
        let backend = session.signedOutEnvironment.authBackend
        // Invitations wait in the Keychain across relaunches, except in tests (nothing persists).
        let keepsState = backend != nil && !configuration.isUITesting
        let auth = AuthCoordinator(
            backend: backend,
            invitations: PendingInvitationStore(keychain: keepsState ? KeychainStore() : nil),
            defaults: keepsState ? .standard : nil,
            phoneVerifications: PendingPhoneVerificationStore(keychain: keepsState ? KeychainStore() : nil)
        )
        // Delivered only once the app is ready, so always into the signed-in account's own services.
        auth.deliverInvitation = { [session, router] invitation in
            let environment = session.environment
            switch invitation {
            case .group(let code):
                router.open(.groups)
                environment.sharedGroups.pendingInvitation = SharedGroupsService.PendingGroupInvitation(code: code)
            case .room(let token):
                router.open(.home)
                environment.sharing.pendingInvitation = SharingService.PendingInvitation(token: token)
            }
        }
        _session = State(initialValue: session)
        _router = State(initialValue: router)
        _auth = State(initialValue: auth)

        SquareUpTips.configure(isUITesting: configuration.isUITesting)
        AppDependencyManager.shared.add(dependency: router)
        // Intents read the signed-in account through the session (nothing while signed out).
        AppDependencyManager.shared.add(dependency: session)
    }

    /// Invitations first (they carry a token or code), then the app's own deep links. Before
    /// sign-in finishes, an invitation waits and opens once the app is ready.
    private func open(_ url: URL) {
        // Firebase's reCAPTCHA redirect (`app-…://`) during phone verification; never a Square Up link.
        if FirebasePhoneVerifier.shared?.canHandle(url) == true { return }
        // Milestone 7: group invitations (`squp://join-group/<code>`, or the HTTPS page's address).
        let environment = session.environment
        if let code = SharedGroupsService.invitationCode(from: url.absoluteString, configuration: environment.sharedGroups.configuration),
           url.scheme?.lowercased() == DeepLink.scheme || url.path().hasPrefix("/g/") {
            auth.receive(.group(code: code))
        } else if let token = environment.sharing.token(from: url) {
            auth.receive(.room(token: token))
        } else if auth.phase == .ready, let link = DeepLink.parse(url) {
            router.open(link)
        }
    }

    var body: some Scene {
        WindowGroup {
            AuthGate {
                // Only while an account's own data is open — never the previous account's, and
                // never an empty stand-in while one closes. A different account's data never reuses
                // the previous account's screens or state.
                if session.scope != nil {
                    RootView()
                        .id(session.generation)
                } else {
                    LaunchView()
                }
            }
            .environment(session.environment)
            .environment(session)
            .environment(router)
            .environment(auth)
            .squareUpTheme()
            .onOpenURL { url in open(url) }
            .onChange(of: session.generation) { router.reset() }
            // DEBUG visual QA: `-SUOpen squp://…` opens a screen once the app is ready.
            .onChange(of: auth.phase == .ready && session.scope != nil, initial: true) { _, isReady in
                if isReady, let url = session.signedOutEnvironment.configuration.openAtLaunch { open(url) }
            }
            // Universal links to invitations (https://<server>/r/<token>) when Associated Domains are available.
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                if let url = activity.webpageURL { open(url) }
            }
        }
    }
}
