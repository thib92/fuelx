import ConvexMobile

/// The auth data `ConvexClientWithAuth` reports in `AuthState.authenticated`.
nonisolated struct BetterAuthSession: Sendable {
  let convexToken: String
}

/// Bridges Better Auth sessions to ConvexMobile.
///
/// Credentials are exchanged for a session token by ``AuthModel`` before `login()` runs, so both
/// login paths only have to turn the stored session token into a Convex JWT.
nonisolated struct BetterAuthProvider: AuthProvider {
  let api: BetterAuthAPI

  func login(onIdToken: @Sendable @escaping (String?) -> Void) async throws -> BetterAuthSession {
    try await loginFromCache(onIdToken: onIdToken)
  }

  /// Called on launch, and by ConvexMobile whenever the Convex JWT needs refreshing.
  func loginFromCache(onIdToken: @Sendable @escaping (String?) -> Void) async throws
    -> BetterAuthSession
  {
    guard let sessionToken = SessionTokenStore.read() else { throw BetterAuthError.notSignedIn }
    do {
      return BetterAuthSession(convexToken: try await api.convexToken(sessionToken: sessionToken))
    } catch let error as BetterAuthError where error.isUnauthorized {
      // The session expired or was revoked server-side: forget it and sign the client out.
      SessionTokenStore.delete()
      onIdToken(nil)
      throw error
    }
  }

  func logout() async throws {
    guard let sessionToken = SessionTokenStore.read() else { return }
    SessionTokenStore.delete()
    // Best effort: signing out locally must not depend on the network.
    try? await api.signOut(sessionToken: sessionToken)
  }

  func extractIdToken(from authResult: BetterAuthSession) -> String {
    authResult.convexToken
  }
}
