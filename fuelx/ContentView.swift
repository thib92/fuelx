import Playgrounds
import SwiftUI

struct ContentView: View {
    @Environment(AuthModel.self) private var auth
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch auth.status {
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
            case .loading, .signedIn:
                // Never waits for the network: days show from the cache, or as placeholders.
                HomeView()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await auth.retryNow() }
            }
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
