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
        // Silent pushes need no permission prompt, so this never asks to show notifications. If
        // registration fails (the Simulator, or a build signed without Push Notifications in
        // `Config/SquareUp.entitlements`), Firebase uses reCAPTCHA instead.
        if FirebasePhoneVerifier.shared != nil, !LaunchConfiguration.current.isUITesting {
            application.registerForRemoteNotifications()
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        FirebasePhoneVerifier.shared?.setAPNSToken(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        // Expected in the Simulator or without the Push Notifications entitlement; phone sign-in
        // falls back to reCAPTCHA.
        Log.app.info("Remote notifications unavailable; phone verification will use reCAPTCHA")
    }

    /// Firebase's silent verification push, and the test notification it sends first to check that
    /// this delegate forwards notifications. Square Up has no notifications of its own.
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        _ = FirebasePhoneVerifier.shared?.canHandleNotification(userInfo)
        return .noData
    }
}
