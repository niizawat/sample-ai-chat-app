import SwiftUI

@main
struct PushEventChatApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appDelegateHolder = AppDelegateHolder()
    @State private var accessToken: String?

    var body: some Scene {
        WindowGroup {
            ContentView(accessToken: $accessToken)
                .environmentObject(appDelegateHolder)
                .onAppear {
                    appDelegateHolder.delegate = appDelegate
                    restoreSessionIfPossible()
                }
        }
    }

    private func restoreSessionIfPossible() {
        guard accessToken == nil else { return }
        Task {
            do {
                let token = try await CognitoAuthService().validAccessToken()
                await MainActor.run {
                    accessToken = token
                }
            } catch {
                // Stay on login.
            }
        }
    }
}
