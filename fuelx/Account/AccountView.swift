import AuthenticationServices
import Combine
import ConvexMobile
import SwiftUI

/// Mirrors the user returned by `auth:getCurrentUser` (convex/auth.ts).
nonisolated struct CurrentUser: Decodable, Sendable {
    let id: String
    let name: String
    let email: String
    private let anonymous: Bool?

    var isAnonymous: Bool { anonymous == true }

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case name, email
        case anonymous = "isAnonymous"
    }
}

/// Presented as a sheet from ``HomeView``.
struct AccountView: View {
    @Environment(AuthModel.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var user: CurrentUser?
    @State private var appleNonce: String?
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if let user, !isWorking {
                    if user.isAnonymous {
                        guestSection
                    } else {
                        Section {
                            LabeledContent("Name", value: user.name.isEmpty ? "—" : user.name)
                            LabeledContent("Email", value: user.email)
                        }
                        Section {
                            Button("Sign Out", role: .destructive) {
                                Task { await run { await auth.signOut() } }
                            }
                        }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }

                Section {
                    NavigationLink {
                        ProfileForm()
                    } label: {
                        Label("Nutrition Profile", systemImage: "target")
                    }
                    appleHealthRow
                    NavigationLink {
                        AboutView()
                    } label: {
                        Label("About", systemImage: "info.circle")
                    }
                } footer: {
                    Text("Your body, activity and weight goal set your daily targets.")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
            }
            .task {
                // Follows auth changes: switches from the guest to the Apple user (and back) live.
                let updates = convex.subscribe(to: "auth:getCurrentUser", yielding: CurrentUser?.self)
                do {
                    for try await value in updates.values { user = value }
                } catch {
                    print("auth:getCurrentUser failed: \(error)")
                }
            }
        }
    }

    @ViewBuilder
    private var appleHealthRow: some View {
        let health = HealthSync.shared
        if health.isConnected {
            LabeledContent {
                Text("Connected")
            } label: {
                Label("Apple Health", systemImage: "heart")
            }
        } else {
            Button("Connect Apple Health", systemImage: "heart") {
                Task { await health.connect() }
            }
        }
        if let error = health.lastError {
            Text(error).font(.caption).foregroundStyle(.red)
        }
    }

    private var guestSection: some View {
        Section {
            Text("You're using Fuelx as a guest.")
            if AuthModel.isAppleSignInAvailable {
                appleButton
            }
        } footer: {
            if AuthModel.isAppleSignInAvailable {
                Text("Sign in with Apple to keep your data if you reinstall or switch devices.")
            }
        }
    }

    private var appleButton: some View {
        SignInWithAppleButton(.continue) { request in
            let nonce = AppleNonce.make()
            appleNonce = nonce
            request.requestedScopes = [.fullName, .email]
            request.nonce = AppleNonce.sha256(nonce)
        } onCompletion: { result in
            Task { await handleApple(result) }
        }
        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
        .frame(height: 50)
        .listRowInsets(EdgeInsets())
    }

    private func handleApple(_ result: Result<ASAuthorization, Error>) async {
        errorMessage = nil
        switch result {
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            errorMessage = error.localizedDescription
        case .success(let authorization):
            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let identityToken = String(data: tokenData, encoding: .utf8),
                let rawNonce = appleNonce
            else {
                errorMessage = String(localized: "Sign in with Apple didn't return an identity token.")
                return
            }
            let apple = AppleIDToken(
                identityToken: identityToken,
                rawNonce: rawNonce,
                givenName: credential.fullName?.givenName,
                familyName: credential.fullName?.familyName)
            await run { try await auth.signInWithApple(apple) }
        }
    }

    /// Shows progress while an auth action runs and surfaces its error.
    private func run(_ action: () async throws -> Void) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await action()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    AccountView()
        .environment(AuthModel(client: convex, api: betterAuth))
}
