import Foundation

/// Process-level configuration read once at launch.
///
/// Launch arguments (UI tests and visual QA):
/// - `-SUInMemoryStore` — use a throwaway in-memory SwiftData store seeded with sample data.
/// - `-SUScenario <name>` — DEBUG only; render a `DemoScenario` instead of the real store.
/// - `-SUReferenceDate <seconds since 2001>` — fixed "now" for deterministic dates.
/// - `-SUUITesting` — disables tips and long-running decorative animation.
/// - `-SUSimulateHandoffs` — payment handoffs don't open other apps (UI tests).
/// - `-SUFreshStore` — DEBUG only; erase the on-disk store and receipt files at launch (relaunch UI tests).
/// - `-SUSharedRoomsServer <origin>` — DEBUG only; shared rooms against a development server
///   (`Dev` identities), even in UI tests, e.g. `http://127.0.0.1:8080` (two-device UI tests).
/// - `-SUAuthDemo <scenario>` — DEBUG only; the sign-in flow against an in-process stand-in for
///   Firebase (`DemoAuthBackend`): no real accounts or email. Release builds ignore it.
/// - `-SUOpen <squp:// link>` — DEBUG only; open a deep link once the app is ready (visual QA of
///   a tab or screen without tapping through), e.g. `-SUOpen squp://activity`.
/// - `-SUPhoneAuthTestNumbers` — DEBUG only; Firebase's app verification off, so the project's
///   fictional phone numbers work in the Simulator without reCAPTCHA. Real numbers still fail.
/// - `-SUDevUserID <id>` — DEBUG only; the development account's identity against a development
///   server (`Dev <id>`), instead of one made up per install. Its address there is
///   `<id>@squareup.test`, so UI tests can find each other with "Find a person".
///
/// - `-SUDemoServer <origin>` — DEBUG only; the launch flow as built (Firebase), but Square Up's
///   server at a development origin, so "Enter Demo" can be tried against a local server, e.g.
///   `http://127.0.0.1:8095`.
///
/// Hosting unit tests implies an in-memory store and testing mode.
nonisolated struct LaunchConfiguration: Sendable, Equatable {
    var usesInMemoryStore = false
    var scenario: DemoScenario?
    var referenceDate: Date?
    var isUITesting = false
    /// UI tests: payment handoffs report "opened" without leaving the app or opening anything.
    var simulatesHandoffs = false
    /// UI tests: start from a fresh on-disk store so relaunch can be tested without leftovers.
    var erasesStoreAtLaunch = false
    /// DEBUG: a development server for shared rooms, overriding the build's configuration.
    var sharedRoomsServer: URL?
    /// DEBUG: run the launch flow against `DemoAuthBackend` with this scenario.
    var authDemo: String?
    /// DEBUG: a deep link to open once the app is ready.
    var openAtLaunch: URL?
    /// DEBUG: Firebase phone verification with fictional test numbers only (never in Release).
    var usesPhoneAuthTestNumbers = false
    /// DEBUG: the development account's identity (letters, digits, `-`, `_`; 3–64 characters).
    var developmentUserID: String?
    /// DEBUG: Square Up's server at a development origin for a Firebase-mode build (Demo Mode QA).
    var demoServer: URL?

    static func from(arguments: [String], environment: [String: String] = [:]) -> LaunchConfiguration {
        var configuration = LaunchConfiguration()
        // When the app is the host for unit tests, never touch the on-disk store or show tips.
        let isTestHost = environment["XCTestConfigurationFilePath"] != nil
        configuration.usesInMemoryStore = arguments.contains("-SUInMemoryStore") || isTestHost
        configuration.isUITesting = arguments.contains("-SUUITesting") || isTestHost
        configuration.simulatesHandoffs = arguments.contains("-SUSimulateHandoffs")
        if let index = arguments.firstIndex(of: "-SUReferenceDate"), arguments.indices.contains(index + 1),
           let seconds = TimeInterval(arguments[index + 1]) {
            configuration.referenceDate = Date(timeIntervalSinceReferenceDate: seconds)
        }
        #if DEBUG
        configuration.erasesStoreAtLaunch = arguments.contains("-SUFreshStore")
        if let index = arguments.firstIndex(of: "-SUSharedRoomsServer"), arguments.indices.contains(index + 1) {
            configuration.sharedRoomsServer = URL(string: arguments[index + 1])
        }
        if let index = arguments.firstIndex(of: "-SUAuthDemo"), arguments.indices.contains(index + 1) {
            configuration.authDemo = arguments[index + 1]
        }
        if let index = arguments.firstIndex(of: "-SUScenario"), arguments.indices.contains(index + 1) {
            configuration.scenario = DemoScenario(rawValue: arguments[index + 1])
        }
        if let index = arguments.firstIndex(of: "-SUOpen"), arguments.indices.contains(index + 1) {
            configuration.openAtLaunch = URL(string: arguments[index + 1])
        }
        if let index = arguments.firstIndex(of: "-SUDemoServer"), arguments.indices.contains(index + 1) {
            configuration.demoServer = URL(string: arguments[index + 1])
        }
        configuration.usesPhoneAuthTestNumbers = arguments.contains("-SUPhoneAuthTestNumbers")
        if let index = arguments.firstIndex(of: "-SUDevUserID"), arguments.indices.contains(index + 1) {
            let id = arguments[index + 1]
            if (3...64).contains(id.count), id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) {
                configuration.developmentUserID = id
            }
        }
        #endif
        return configuration
    }

    static let current = LaunchConfiguration.from(
        arguments: ProcessInfo.processInfo.arguments,
        environment: ProcessInfo.processInfo.environment
    )
}
