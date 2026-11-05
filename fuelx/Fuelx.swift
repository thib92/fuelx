import SwiftUI

@main struct Fuelx: App {
    @State private var auth = AuthModel(client: convex, api: betterAuth)

    init() {
        ConnectionMonitor.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(auth)
        }
    }
}
