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

    /// Read Aloud uses the cloud voice only when the person turned it on and is entitled.
    static func usesNaturalVoice(toggleOn: Bool, entitled: Bool) -> Bool { toggleOn && entitled }

    enum ToggleAction: Equatable { case turnOn, turnOff, showPaywall }

    /// What flipping the "Natural voice" switch does.
    static func toggleAction(wantsOn: Bool, entitled: Bool) -> ToggleAction {
        guard wantsOn else { return .turnOff }
        return entitled ? .turnOn : .showPaywall
    }
}
