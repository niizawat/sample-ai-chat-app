import UIKit
import UserNotifications

#if canImport(FirebaseCore)
import FirebaseCore
#endif
#if canImport(FirebaseMessaging)
import FirebaseMessaging
#endif

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        #if canImport(FirebaseCore)
        if AppConfig.hasFirebasePlist {
            FirebaseApp.configure()
        }
        #endif

        UNUserNotificationCenter.current().delegate = self

        #if canImport(FirebaseMessaging)
        #if !targetEnvironment(simulator)
        if AppConfig.hasFirebasePlist {
            Messaging.messaging().delegate = self
        }
        #endif
        #endif

        if let remote = launchOptions?[.remoteNotification] as? [AnyHashable: Any] {
            handleNotificationUserInfo(remote)
        }

        requestNotificationPermissionAndRegister()

        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        #if canImport(FirebaseMessaging)
        Messaging.messaging().apnsToken = deviceToken
        #endif
    }

    func requestNotificationPermissionAndRegister() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            #if targetEnvironment(simulator)
            _ = granted
            #else
            guard granted else { return }
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
            }
            #endif
        }
    }

    func registerCurrentFCMToken(accessToken: String) async {
        #if targetEnvironment(simulator)
        return
        #else
        #if canImport(FirebaseMessaging)
        guard AppConfig.hasFirebasePlist else { return }
        do {
            let token = try await Messaging.messaging().token()
            let idToken = try await CognitoAuthService().validIdToken()
            try await DeviceRegistrationService().register(
                fcmToken: token,
                idToken: idToken
            )
            await MainActor.run {
                PushEventCenter.shared.registrationError = nil
            }
        } catch {
            await MainActor.run {
                PushEventCenter.shared.registrationError = error.localizedDescription
            }
        }
        #endif
        #endif
    }

    private func handleNotificationUserInfo(_ userInfo: [AnyHashable: Any]) {
        let eventId =
            (userInfo["eventId"] as? String)
            ?? ((userInfo["data"] as? [AnyHashable: Any])?["eventId"] as? String)
        Task { @MainActor in
            PushEventCenter.shared.setPendingEventId(eventId)
        }
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        handleNotificationUserInfo(notification.request.content.userInfo)
        completionHandler([.banner, .sound, .badge])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        handleNotificationUserInfo(response.notification.request.content.userInfo)
        completionHandler()
    }
}

#if canImport(FirebaseMessaging)
#if !targetEnvironment(simulator)
extension AppDelegate: MessagingDelegate {
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let fcmToken, !fcmToken.isEmpty else { return }
        Task {
            do {
                let idToken = try await CognitoAuthService().validIdToken()
                try await DeviceRegistrationService().register(
                    fcmToken: fcmToken,
                    idToken: idToken
                )
                await MainActor.run {
                    PushEventCenter.shared.registrationError = nil
                }
            } catch {
                // Not signed in yet, or API not configured — ignore until login.
            }
        }
    }
}
#endif
#endif
