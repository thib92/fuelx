import Combine
import ConvexMobile
import Foundation

/// Tracks the Convex connection so saves can fail with a message when offline.
///
/// Mutations made while disconnected wait for a reconnect instead of failing, so without this
/// check the save button would hang, and logging again would add the food twice. The app also
/// opens before it's signed in, so this holds saves until the session is accepted.
final class ConnectionMonitor {
    static let shared = ConnectionMonitor()

    private static let reconnectWait: Duration = .seconds(3)
    private static let pollInterval: Duration = .milliseconds(100)

    /// The publisher only sends changes, so this is `nil` until the first one arrives, which
    /// is treated as connected.
    private var state: WebSocketState?
    private var isAuthenticated = false
    private var subscriptions = Set<AnyCancellable>()

    private var isConnecting: Bool {
        if case .connecting = state { true } else { false }
    }

    /// Call at launch, so no state change is missed.
    func start() {
        convex.watchWebSocketState()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.state = $0 }
            .store(in: &subscriptions)
        convex.authState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                if case .authenticated = state {
                    self?.isAuthenticated = true
                } else {
                    self?.isAuthenticated = false
                }
            }
            .store(in: &subscriptions)
    }

    /// Gives a brief reconnect, such as after returning to the app, a moment to finish.
    func ensureConnected() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + Self.reconnectWait
        while isConnecting || !isAuthenticated {
            guard clock.now < deadline else { throw ConnectionError.offline }
            try await Task.sleep(for: Self.pollInterval)
        }
    }
}

nonisolated enum ConnectionError: LocalizedError {
    case offline

    var errorDescription: String? {
        String(localized: "You're offline. Check your connection and try again.")
    }
}
