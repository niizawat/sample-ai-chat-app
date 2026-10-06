import SwiftUI

struct ContentView: View {
    @Binding var accessToken: String?
    @EnvironmentObject private var appDelegate: AppDelegateHolder

    var body: some View {
        Group {
            if accessToken != nil {
                ChatView(accessToken: $accessToken)
            } else {
                LoginView(accessToken: $accessToken)
            }
        }
        .onChange(of: accessToken) { _, newValue in
            guard let token = newValue else { return }
            Task {
                appDelegate.delegate?.requestNotificationPermissionAndRegister()
                await appDelegate.delegate?.registerCurrentFCMToken(accessToken: token)
            }
        }
        .task {
            if let token = accessToken {
                appDelegate.delegate?.requestNotificationPermissionAndRegister()
                await appDelegate.delegate?.registerCurrentFCMToken(accessToken: token)
            }
        }
    }
}

/// Thin holder so SwiftUI can reach the UIApplicationDelegate instance.
final class AppDelegateHolder: ObservableObject {
    weak var delegate: AppDelegate?
}

#Preview {
    ContentView(accessToken: .constant(nil))
        .environmentObject(AppDelegateHolder())
}
