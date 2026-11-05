import SwiftUI

@main struct Fuelx: App {
    @State private var auth = AuthModel(client: convex, api: betterAuth)

    init() {
        ConnectionMonitor.shared.start()
        HealthSync.shared.startObserving()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(auth)
        }
    }
}
