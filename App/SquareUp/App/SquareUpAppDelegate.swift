import OSLog
import UIKit

/// The few `UIApplicationDelegate` callbacks SwiftUI doesn't offer, for Firebase phone
/// verification only: the APNs device token and Firebase's silent verification notification.
/// Firebase's method swizzling is off (`FirebaseAppDelegateProxyEnabled` = NO), so everything it
/// needs is forwarded explicitly here. The reCAPTCHA redirect arrives through SwiftUI's
/// `onOpenURL` (`SquareUpApp.open(_:)`), ahead of Square Up's own links.
///
/// Without phone sign-in configured (`FirebasePhoneVerifier.shared == nil`) nothing registers for
/// notifications and every callback is a no-op. Square Up sends no user-visible notifications.
final class SquareUpAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Firebase starts here, once the UIApplication exists (see `FirebasePhoneVerifier.auth`).
        FirebasePhoneVerifier.shared?.start()
        // Silent pushes need no permission prompt. Without the Push Notifications capability (it
        // needs a paid Apple Developer team) registration fails and Firebase uses reCAPTCHA instead.
        if FirebasePhoneVerifier.shared != nil, !LaunchConfiguration.current.isUITesting {
            application.registerForRemoteNotifications()
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        FirebasePhoneVerifier.shared?.setAPNSToken(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        // Expected without the Push Notifications capability; phone sign-in falls back to reCAPTCHA.
        Log.app.info("Remote notifications unavailable; phone verification will use reCAPTCHA")
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        if FirebasePhoneVerifier.shared?.canHandleNotification(userInfo) == true { return .noData }
        return .noData
    }
}
