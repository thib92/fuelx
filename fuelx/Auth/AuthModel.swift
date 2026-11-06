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
    /// Couldn't sign in. Retry with ``ensureSession()``. With no session yet this is immediate
    /// (e.g. offline). A stored session gets a few quiet retries first, and while offline it only
    /// ends up here if there are no cached days to show.
    case failed(String)
  }

  private static let firstRetryDelay: Duration = .seconds(2)
  private static let maxRetryDelay: Duration = .seconds(30)
  /// Failed logins with a stored session before telling the user, about 15 seconds.
  private static let quietAttempts = 4

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
  /// The login in flight, which a session switch has to wait for.
  private var restoring: Task<Void, Never>?
  private var retryTask: Task<Void, Never>?
  private var retryDelay = AuthModel.firstRetryDelay
  private var failedAttempts = 0

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
    let login = Task { await restoreSession() }
    restoring = login
    await login.value
  }

  /// Tries again now rather than waiting out the backoff. For returning to the app, which is
  /// when a connection tends to be back.
  func retryNow() async {
    guard retryTask != nil || isFailed, !isSwitchingSession else { return }
    retryDelay = Self.firstRetryDelay
    await ensureSession()
  }

  private var isFailed: Bool {
    if case .failed = status { true } else { false }
  }

  private func cancelRetry() {
    retryTask?.cancel()
    retryTask = nil
  }

  private func restoreSession() async {
    cancelRetry()
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
      didSignIn()
    } catch {
      failedAttempts += 1
      if SessionTokenStore.read() == nil || shouldStopRetrying(after: error) {
        status = .failed(error.localizedDescription)
      } else {
        retryLater()
      }
    }
  }

  private func didSignIn() {
    retryDelay = Self.firstRetryDelay
    failedAttempts = 0
    status = .signedIn
    session = UUID()
  }

  /// Waiting only makes sense for a connection that may come back, with days to show meanwhile.
  private func shouldStopRetrying(after error: Error) -> Bool {
    failedAttempts >= Self.quietAttempts && (!(error is URLError) || dayStore.isEmpty)
  }

  /// The stored session survives network errors, so this usually only has to wait for a
  /// connection.
  private func retryLater() {
    let delay = retryDelay
    retryDelay = min(delay * 2, Self.maxRetryDelay)
    retryTask = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled, let self else { return }
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

  /// Replaces the session in place, without passing through `.loading`, so the UI (and any open
  /// sheet) stays put. If anything fails midway, falls back to ``ensureSession()``.
  private func switchSession(_ body: () async throws -> Void) async {
    isSwitchingSession = true
    defer { isSwitchingSession = false }
    cancelRetry()
    // A login running alongside this could replace the token, or start a second guest.
    await restoring?.value
    cancelRetry()
    session = nil
    do {
      try await body()
      didSignIn()
    } catch {
      await ensureSession()
    }
  }

  /// Clears first: if this fails offline, the previous account's days must not stay on disk.
  private func startGuestSession() async throws {
    dayStore.clear()
    try SessionTokenStore.save(try await api.signInAnonymously())
  }
}
