import IndieAccount

// Fast Tab's words for what IndieAccount reports. IndieAccount returns cases; each app
// says them in its own voice. Only the failures Fast Tab's account screens can hit.

extension AccountFailure {
    /// Plain English for the UI. Never shows raw codes.
    var userMessage: String {
        switch self {
        case let .api(error): error.userMessage
        case .appleSignInFailed: "Sign in with Apple didn't go through. Please try again."
        case .accountDeletionNotConfirmed:
            "Sign in with Apple didn't go through, so your account was not deleted. Try again."
        case .unexpected: "Something went wrong. Try again."
        }
    }
}

extension TheIndieAPIError {
    var userMessage: String {
        switch self {
        case .transport(.notConnectedToInternet), .transport(.networkConnectionLost):
            "You're offline. Check your connection and try again."
        case .transport:
            "Couldn't reach the account server. Try again."
        case .notSignedIn:
            "Please sign in again."
        case .invalidResponse:
            "The account server sent an unexpected answer. Try again later."
        case .server:
            switch code {
            case TheIndieErrorCode.unauthorized: "Your session ended. Please sign in again."
            case TheIndieErrorCode.invalidIdentityToken: "Sign in with Apple didn't go through. Please try again."
            case TheIndieErrorCode.appleUnavailable: "Apple's sign-in service is not responding. Try again in a moment."
            case TheIndieErrorCode.accountSuspended: "This account is suspended, so you've been signed out."
            case TheIndieErrorCode.authorizationCodeRequired, TheIndieErrorCode.invalidAuthorizationCode:
                "Apple couldn't confirm it's you. Sign in with Apple again to delete your account."
            case TheIndieErrorCode.rateLimited: "Too many tries. Wait a little and try again."
            case TheIndieErrorCode.unknownApp, TheIndieErrorCode.serverMisconfigured:
                "The account server isn't set up for Fast Tab yet. Try again later."
            default: "That didn't work. Try again."
            }
        }
    }
}
