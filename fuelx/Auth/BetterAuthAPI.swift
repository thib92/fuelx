import Foundation

/// Minimal client for the Better Auth HTTP API that Convex serves at
/// `<CONVEX_SITE_URL>/api/auth`.
///
/// The session is carried as a bearer token (`Authorization: Bearer <session token>`), which the
/// `convex()` Better Auth plugin accepts. Cookies are disabled on purpose: if URLSession replayed
/// Better Auth's session cookie, Better Auth would apply its browser CSRF check and reject POSTs
/// such as sign-out, because native requests carry no `Origin` header.
nonisolated struct BetterAuthAPI: Sendable {
  private let baseURL: URL
  private let session: URLSession

  init(siteURL: URL) {
    baseURL = siteURL.appending(path: "api/auth")
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpShouldSetCookies = false
    configuration.httpCookieStorage = nil
    session = URLSession(configuration: configuration)
  }

  /// Creates a guest user and returns its session token.
  func signInAnonymously() async throws -> String {
    let response: SessionResponse = try await send("sign-in/anonymous", body: EmptyBody())
    return try response.requireToken()
  }

  /// Signs in with an Apple identity token and returns the new session token.
  ///
  /// Pass the current guest session so Better Auth can hand the guest's data over to the Apple
  /// account (see `onLinkAccount` in convex/betterAuth/auth.ts) and then delete the guest.
  func signInWithApple(_ apple: AppleIDToken, guestSessionToken: String?) async throws -> String {
    let name = AppleSignInBody.Name(firstName: apple.givenName, lastName: apple.familyName)
    let body = AppleSignInBody(
      idToken: .init(
        token: apple.identityToken,
        nonce: apple.rawNonce,
        // Apple only shares the user's name on their first authorization.
        user: name.isEmpty ? nil : .init(name: name)))
    let response: SessionResponse = try await send(
      "sign-in/social", body: body, sessionToken: guestSessionToken)
    return try response.requireToken()
  }

  /// Exchanges a session token for a short-lived (15 min) JWT that Convex accepts.
  func convexToken(sessionToken: String) async throws -> String {
    let response: TokenResponse = try await send(
      "convex/token", method: "GET", sessionToken: sessionToken)
    return response.token
  }

  /// Revokes the session server-side.
  func signOut(sessionToken: String) async throws {
    let _: SignOutResponse = try await send(
      "sign-out", body: EmptyBody(), sessionToken: sessionToken)
  }

  private func send<Response: Decodable>(
    _ path: String,
    method: String = "POST",
    body: (any Encodable)? = nil,
    sessionToken: String? = nil
  ) async throws -> Response {
    var request = URLRequest(url: baseURL.appending(path: path))
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONEncoder().encode(body)
    }
    if let sessionToken {
      request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
    }

    let (data, response) = try await session.data(for: request)
    guard let status = (response as? HTTPURLResponse)?.statusCode else {
      throw BetterAuthError.invalidResponse
    }
    guard (200..<300).contains(status) else {
      let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
      throw BetterAuthError.requestFailed(status: status, code: body?.code, message: body?.message)
    }
    return try JSONDecoder().decode(Response.self, from: data)
  }

  private nonisolated struct EmptyBody: Encodable {}

  private nonisolated struct AppleSignInBody: Encodable {
    nonisolated struct IDToken: Encodable {
      let token: String
      let nonce: String
      let user: User?
    }

    nonisolated struct User: Encodable {
      let name: Name
    }

    nonisolated struct Name: Encodable {
      let firstName: String?
      let lastName: String?
      var isEmpty: Bool { (firstName ?? "").isEmpty && (lastName ?? "").isEmpty }
    }

    let provider = "apple"
    let idToken: IDToken
  }

  private nonisolated struct SessionResponse: Decodable {
    let token: String?

    func requireToken() throws -> String {
      guard let token else { throw BetterAuthError.noSession }
      return token
    }
  }

  private nonisolated struct TokenResponse: Decodable {
    let token: String
  }

  private nonisolated struct SignOutResponse: Decodable {
    let success: Bool
  }

  private nonisolated struct ErrorBody: Decodable {
    let code: String?
    let message: String?
  }
}

/// What the app forwards to Better Auth from an `ASAuthorizationAppleIDCredential`.
nonisolated struct AppleIDToken: Sendable {
  let identityToken: String
  /// The unhashed nonce. Apple receives its SHA-256; Better Auth hashes this to compare.
  let rawNonce: String
  let givenName: String?
  let familyName: String?
}

nonisolated enum BetterAuthError: LocalizedError {
  /// No session token is stored on this device.
  case notSignedIn
  /// The server responded without starting a session.
  case noSession
  case invalidResponse
  case requestFailed(status: Int, code: String?, message: String?)

  /// The stored session has expired or was revoked.
  var isUnauthorized: Bool {
    if case .requestFailed(status: 401, _, _) = self { return true }
    return false
  }

  var errorDescription: String? {
    switch self {
    case .notSignedIn: String(localized: "You're not signed in.")
    case .noSession: String(localized: "The server didn't start a session.")
    case .invalidResponse: String(localized: "Unexpected response from the server.")
    // Not the server's message, which is always in English.
    case .requestFailed(let status, _, _): String(localized: "Request failed (\(status)).")
    }
  }
}
