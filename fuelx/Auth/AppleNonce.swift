import CryptoKit
import Foundation
import Security

/// Nonces for Sign in with Apple. Apple embeds `sha256(raw)` in the identity token; the server
/// receives `raw` and checks it matches, so a stolen token can't be replayed with a new nonce.
nonisolated enum AppleNonce {
  static func make() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    precondition(status == errSecSuccess, "Unable to generate nonce")
    return hex(bytes)
  }

  static func sha256(_ value: String) -> String {
    hex(SHA256.hash(data: Data(value.utf8)))
  }

  private static func hex(_ bytes: some Sequence<UInt8>) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
  }
}
