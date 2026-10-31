import SwiftUI

@main struct Fuelx: App {
    @State private var auth = AuthModel(client: convex, api: betterAuth)

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(auth)
        }
    }
}
