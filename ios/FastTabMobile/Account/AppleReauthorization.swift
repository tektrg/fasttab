// Ported from Parklet (jevdump/Parklet/Features/Account/AppleReauthorization.swift).
import AuthenticationServices
import UIKit

/// Runs Sign in with Apple again (no scopes) to get a fresh `authorizationCode`, which the
/// server needs right before deleting the account so it can revoke Apple sign-in. Apple's
/// codes live 5 minutes and work once, so ask immediately before the delete call.
@MainActor
final class AppleReauthorization: NSObject {
    enum Outcome: Equatable {
        case authorized(code: String)
        case cancelled
        case failed
    }

    private var continuation: CheckedContinuation<Outcome, Never>?
    /// Keeps the controller alive while Apple's sheet is up.
    private var controller: ASAuthorizationController?

    func requestAuthorizationCode() async -> Outcome {
        guard continuation == nil else { return .failed } // one request at a time
        let request = ASAuthorizationAppleIDProvider().createRequest()
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        self.controller = controller
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            controller.performRequests()
        }
    }

    private func finish(_ outcome: Outcome) {
        continuation?.resume(returning: outcome)
        continuation = nil
        controller = nil
    }
}

extension AppleReauthorization: ASAuthorizationControllerDelegate {
    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        let code = (authorization.credential as? ASAuthorizationAppleIDCredential)?
            .authorizationCode
            .flatMap { String(data: $0, encoding: .utf8) }
        MainActor.assumeIsolated {
            finish(code.map { .authorized(code: $0) } ?? .failed)
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: any Error) {
        let wasCancelled = (error as? ASAuthorizationError)?.code == .canceled
        MainActor.assumeIsolated {
            finish(wasCancelled ? .cancelled : .failed)
        }
    }
}

extension AppleReauthorization: ASAuthorizationControllerPresentationContextProviding {
    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let windowScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let keyWindow = windowScenes.flatMap(\.windows).first(where: \.isKeyWindow)
            return keyWindow ?? ASPresentationAnchor()
        }
    }
}
