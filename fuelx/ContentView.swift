import Playgrounds
import SwiftUI

struct ContentView: View {
    @Environment(AuthModel.self) private var auth

    var body: some View {
        switch auth.status {
        case .loading:
            ProgressView()
        case .failed(let message):
            ContentUnavailableView {
                Label("Can't Connect", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") {
                    Task { await auth.ensureSession() }
                }
            }
        case .signedIn:
            HomeView()
        }
    }
}

#Preview {
    ContentView()
        .environment(AuthModel(client: convex, api: betterAuth))
}

#Playground {
    _ = 1 + 2
}
