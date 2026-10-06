import SwiftUI

struct ContentView: View {
    @State private var accessToken: String?

    var body: some View {
        Group {
            if accessToken != nil {
                ChatView(accessToken: $accessToken)
            } else {
                LoginView(accessToken: $accessToken)
            }
        }
    }
}

#Preview {
    ContentView()
}
