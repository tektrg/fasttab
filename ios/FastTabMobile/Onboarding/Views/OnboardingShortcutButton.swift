import SwiftUI

/// The fix-the-cause button under an empty state: opens the one guide screen
/// that solves why the screen is empty.
struct OnboardingShortcutButton: View {
    enum Shortcut {
        /// No Mac synced yet → the "Connect your Mac" screen.
        case connectMac
        /// Nothing shared yet → the "Send links to your Mac" screen (share sheet setup).
        case addToShareSheet

        var title: String {
            switch self {
            case .connectMac: return "Connect your Mac"
            case .addToShareSheet: return "Add FastTab to share sheet"
            }
        }

        var step: OnboardingStep {
            switch self {
            case .connectMac: return .connectMac
            case .addToShareSheet: return .sendToMac
            }
        }
    }

    enum Prominence {
        /// Solid button in a full-screen empty state.
        case primary
        /// Soft capsule inside an inline (card) empty state.
        case inline
    }

    let shortcut: Shortcut
    var prominence: Prominence = .primary

    var body: some View {
        switch prominence {
        case .primary:
            button.buttonStyle(.dsPrimary)
        case .inline:
            button.buttonStyle(.dsTinted(DS.Tint.action)).padding(.top, DS.Space.xs)
        }
    }

    private var button: some View {
        Button(shortcut.title) {
            OnboardingPresenter.shared.present(.singleStep(shortcut.step))
        }
    }
}
