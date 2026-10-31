import Combine
import ConvexMobile
import Foundation
import Observation

/// App-facing auth state and actions, backed by Better Auth + ConvexMobile.
///
/// There is always a user: on first launch (or after signing out) the app silently creates a
/// guest account, which can later be upgraded with Sign in with Apple.
@Observable
final class AuthModel {
  /// Sign in with Apple needs a paid Apple Developer Program team. Flip to `true` once the
  /// target is signed with that team and has the "Sign in with Apple" capability again.
  static let isAppleSignInAvailable = true

  enum Status: Equatable {
    case loading
    case signedIn
    /// Couldn't restore or create a session (e.g. offline). Retry with ``ensureSession()``.
    case failed(String)
  }

  private(set) var status = Status.loading

  private let client: ConvexClientWithAuth<BetterAuthSession>
  private let api: BetterAuthAPI
  /// Set while deliberately replacing the session, so the auth observer doesn't react to it.
  private var isSwitchingSession = false

  init(client: ConvexClientWithAuth<BetterAuthSession>, api: BetterAuthAPI) {
    self.client = client
    self.api = api
    Task { [weak self] in
      await self?.ensureSession()
      // A session can expire or be revoked while the app runs; fall back to a fresh guest.
      for await state in client.authState.values {
        guard let self else { return }
        if case .unauthenticated = state, status == .signedIn, !isSwitchingSession {
          await ensureSession()
        }
      }
    }
  }

  /// Restores the stored session, or starts a guest session if there is none.
  func ensureSession() async {
    status = .loading
    do {
      if SessionTokenStore.read() == nil {
        try await startGuestSession()
      }
      var result = await client.login()
      if case .failure = result, SessionTokenStore.read() == nil {
        // The stored session was rejected and cleared by BetterAuthProvider: start over as a guest.
        // Network errors keep the stored session, so a guest's account is never silently replaced.
        try await startGuestSession()
        result = await client.login()
      }
      _ = try result.get()
      status = .signedIn
    } catch {
      status = .failed(error.localizedDescription)
    }
  }

  /// Signs in with Apple. If the current user is a guest, their data moves to the Apple account.
  func signInWithApple(_ apple: AppleIDToken) async throws {
    let sessionToken = try await api.signInWithApple(
      apple, guestSessionToken: SessionTokenStore.read())
    await switchSession {
      try SessionTokenStore.save(sessionToken)
      _ = try await client.login().get()
    }
  }

  /// Signs out of the Apple account and continues as a new guest.
  func signOut() async {
    await switchSession {
      await client.logout()
      try await startGuestSession()
      _ = try await client.login().get()
    }
  }

  /// Replaces the session in place, keeping `status == .signedIn` so the UI (and any open sheet)
  /// stays put. If anything fails midway, falls back to ``ensureSession()``.
  private func switchSession(_ body: () async throws -> Void) async {
    isSwitchingSession = true
    defer { isSwitchingSession = false }
    do {
      try await body()
    } catch {
      await ensureSession()
    }
  }

  private func startGuestSession() async throws {
    try SessionTokenStore.save(try await api.signInAnonymously())
  }
}
