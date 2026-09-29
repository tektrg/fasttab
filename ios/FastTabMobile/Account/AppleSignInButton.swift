import AuthenticationServices
import IndieAccount
import SwiftUI

/// Sign in with Apple → `AccountSession.signIn` (ported from Parklet). A fresh nonce per
/// attempt: Apple gets its SHA-256, the server gets the raw value. Cancelling is silent;
/// other failures land in `accountSession.lastError`. `onSignedIn` runs after a successful sign-in.
struct AppleSignInButton: View {
    var onSignedIn: () -> Void = {}

    @Environment(AccountSession.self) private var accountSession
    @Environment(\.colorScheme) private var colorScheme
    @State private var rawNonce = ""
    @State private var isSigningIn = false

    var body: some View {
        SignInWithAppleButton(.signIn, onRequest: configure, onCompletion: complete)
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(height: 48)
            .disabled(isSigningIn)
            .overlay {
                if isSigningIn { ProgressView() }
            }
    }

    private func configure(_ request: ASAuthorizationAppleIDRequest) {
        rawNonce = SignInNonce.makeRawNonce()
        request.requestedScopes = [.fullName, .email]
        request.nonce = SignInNonce.sha256Hex(rawNonce)
    }

    private func complete(_ result: Result<ASAuthorization, any Error>) {
        switch result {
        case let .success(authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let identityToken = credential.identityToken.flatMap({ String(data: $0, encoding: .utf8) })
            else {
                accountSession.lastError = .appleSignInFailed
                return
            }
            let authorizationCode = credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
            let nonce = rawNonce
            isSigningIn = true
            Task {
                let signedIn = await accountSession.signIn(
                    identityToken: identityToken,
                    authorizationCode: authorizationCode,
                    rawNonce: nonce,
                    fullName: credential.fullName
                )
                isSigningIn = false
                if signedIn { onSignedIn() }
            }
        case let .failure(error):
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            accountSession.lastError = .appleSignInFailed
        }
    }
}
