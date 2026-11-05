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
    /// Couldn't create a first session (e.g. offline). Retry with ``ensureSession()``. A stored
    /// session never ends up here: the app keeps showing cached days and retries by itself.
    case failed(String)
  }

  private static let firstRetryDelay: Duration = .seconds(2)
  private static let maxRetryDelay: Duration = .seconds(30)

  private(set) var status = Status.loading
  /// Set once Convex accepts the session, and new for each session. Queries must wait for it,
  /// because until then Convex answers as if signed out: no profile, no entries.
  private(set) var session: UUID? {
    didSet { dayStore.sessionDidChange(session) }
  }

  private let client: ConvexClientWithAuth<BetterAuthSession>
  private let api: BetterAuthAPI
  private let dayStore: DayStore
  /// Set while deliberately replacing the session, so the auth observer doesn't react to it.
  private var isSwitchingSession = false
  private var retryTask: Task<Void, Never>?
  private var retryDelay = AuthModel.firstRetryDelay

  init(
    client: ConvexClientWithAuth<BetterAuthSession>,
    api: BetterAuthAPI,
    dayStore: DayStore = .shared
  ) {
    self.client = client
    self.api = api
    self.dayStore = dayStore
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
    retryTask?.cancel()
    retryTask = nil
    session = nil
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
      retryDelay = Self.firstRetryDelay
      status = .signedIn
      session = UUID()
    } catch {
      if SessionTokenStore.read() == nil {
        status = .failed(error.localizedDescription)
      } else {
        retryLater()
      }
    }
  }

  /// The stored session survives network errors, so this only has to wait for a connection.
  private func retryLater() {
    let delay = retryDelay
    retryDelay = min(delay * 2, Self.maxRetryDelay)
    retryTask = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled, let self else { return }
      // `ensureSession()` cancels this task, which would cancel its own login.
      retryTask = nil
      await ensureSession()
    }
  }

  /// Signs in with Apple. If the current user is a guest, their data moves to the Apple account.
  func signInWithApple(_ apple: AppleIDToken) async throws {
    let sessionToken = try await api.signInWithApple(
      apple, guestSessionToken: SessionTokenStore.read())
    await switchSession {
      try SessionTokenStore.save(sessionToken)
      dayStore.clear()
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
    session = nil
    do {
      try await body()
      session = UUID()
    } catch {
      await ensureSession()
    }
  }

  private func startGuestSession() async throws {
    try SessionTokenStore.save(try await api.signInAnonymously())
    dayStore.clear()
  }
}
