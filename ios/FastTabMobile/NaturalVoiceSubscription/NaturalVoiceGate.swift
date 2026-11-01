import Foundation
import IndieStore

/// The rules for the paid cloud voice, kept pure so they are unit-tested. Built-in device voices
/// are never gated: no sign-in, no purchase.
enum NaturalVoiceGate {
    /// Unlocked while the server says the subscription is live, or StoreKit on this device holds
    /// one (bought but not yet confirmed by the server, or offline). The server still checks every
    /// request (`POST /v1/tts` answers 402 `tts_subscription_required`), so this only decides the UI.
    static func isEntitled(state: SubscriptionState, ownsOnDevice: Bool, now: Date) -> Bool {
        switch state {
        case .active(let until, _): return until > now || ownsOnDevice
        case .grace(let until): return until > now || ownsOnDevice
        default: return ownsOnDevice
        }
    }

    /// The server has a live record. Only then does `POST /v1/tts` answer; StoreKit's word alone does not.
    static func isConfirmedByServer(state: SubscriptionState, now: Date) -> Bool {
        switch state {
        case .active(let until, _): return until > now
        case .grace(let until): return until > now
        default: return false
        }
    }

    /// Paid at Apple, server not confirmed yet: say "Confirming your purchase", never "needs a subscription".
    static func awaitingConfirmation(state: SubscriptionState, ownsOnDevice: Bool, now: Date) -> Bool {
        ownsOnDevice && !isConfirmedByServer(state: state, now: now)
    }

    enum PurchaseStep: Equatable { case unlocked, confirming, waitingForApproval, cancelled, failed(SubscriptionError) }

    /// What the paywall does after the App Store sheet closes.
    static func afterPurchase(_ result: SubscriptionPurchaseResult, confirmed: Bool) -> PurchaseStep {
        switch result {
        case .purchased: return confirmed ? .unlocked : .confirming
        case .failed(.unavailableRetryLater): return .confirming
        case .failed(let error): return .failed(error)
        case .pending: return .waitingForApproval
        case .cancelled: return .cancelled
        }
    }

    /// Read Aloud uses the cloud voice only when the person turned it on and is entitled.
    static func usesNaturalVoice(toggleOn: Bool, entitled: Bool) -> Bool { toggleOn && entitled }

    enum ToggleAction: Equatable { case turnOn, turnOff, showPaywall }

    /// What flipping the "Natural voice" switch does.
    static func toggleAction(wantsOn: Bool, entitled: Bool) -> ToggleAction {
        guard wantsOn else { return .turnOff }
        return entitled ? .turnOn : .showPaywall
    }

    struct SettingsRow: Equatable { let subtitle: String; let offersRestore: Bool }

    /// The Read Aloud "Natural voice" row. Owned at Apple but unconfirmed by the server (e.g.
    /// bought under another account, or the account was deleted) offers Restore, the only way to
    /// re-link it; otherwise the person is stuck on "Subscribed" with the cloud voice refused.
    static func settingsRow(entitled: Bool, awaitingConfirmation: Bool) -> SettingsRow {
        if awaitingConfirmation { return SettingsRow(subtitle: "Confirming your purchase…", offersRestore: true) }
        return SettingsRow(subtitle: entitled ? "Subscribed" : "Subscription · free 7-day trial", offersRestore: false)
    }
}
