import Foundation

/// What the More tab's "Premium" card and the last onboarding step say, kept pure so it is
/// unit-tested. Prices come only from Apple's loaded products (`NaturalVoicePricing`), never hard-coded.
enum PremiumWording {
    static let title = "Natural Voice + AI Summary"
    static let freeNote = "Everything else in Fast Tab is free."

    enum State: Equatable {
        /// Apple hasn't returned the price yet; Subscribe waits until it does.
        case loadingPrice
        case notSubscribed
        /// Not subscribed, and Apple says this person can start the 7-day free trial.
        case trialAvailable
        /// Paid at Apple, the server hasn't confirmed it yet.
        case confirming
        case subscribed
    }

    static func state(entitled: Bool, awaitingConfirmation: Bool, pricing: NaturalVoicePricing) -> State {
        if awaitingConfirmation { return .confirming }
        if entitled { return .subscribed }
        if pricing.monthly == nil && pricing.yearly == nil { return .loadingPrice }
        return pricing.offersTrial ? .trialAvailable : .notSubscribed
    }

    struct Card: Equatable {
        let subtitle: String
        /// "$4.99 / month · $39.99 / year", or nil while loading.
        let priceLine: String?
        let badge: String?
        /// Title of the button that opens the paywall; nil once subscribed.
        let subscribeTitle: String?
        let canSubscribe: Bool
    }

    static func card(_ state: State, pricing: NaturalVoicePricing) -> Card {
        let prices = priceLine(pricing)
        switch state {
        case .loadingPrice:
            return Card(subtitle: "Loading price…", priceLine: nil, badge: nil, subscribeTitle: "Subscribe", canSubscribe: false)
        case .notSubscribed:
            return Card(subtitle: "Listen in natural voices and get AI summaries.", priceLine: prices, badge: nil,
                        subscribeTitle: NaturalVoicePricing.buttonTitle(offersTrial: false), canSubscribe: true)
        case .trialAvailable:
            return Card(subtitle: "Listen in natural voices and get AI summaries.",
                        priceLine: prices.map { "7-day free trial, then " + $0 } ?? "7-day free trial", badge: nil,
                        subscribeTitle: NaturalVoicePricing.buttonTitle(offersTrial: true), canSubscribe: true)
        case .confirming:
            return Card(subtitle: "Confirming your purchase…", priceLine: nil, badge: nil, subscribeTitle: nil, canSubscribe: false)
        case .subscribed:
            return Card(subtitle: "Natural Voice and AI Summary are unlocked.", priceLine: nil, badge: "Active",
                        subscribeTitle: nil, canSubscribe: false)
        }
    }

    static func priceLine(_ pricing: NaturalVoicePricing) -> String? {
        let parts = [pricing.monthly.map { "\($0.displayPrice) / month" }, pricing.yearly.map { "\($0.displayPrice) / year" }]
        let joined = parts.compactMap { $0 }.joined(separator: " · ")
        return joined.isEmpty ? nil : joined
    }

    // MARK: Onboarding last step

    static let onboardingTitle = "Fast Tab is free"
    static let onboardingMessage = "Everything in Fast Tab is free. Premium adds two extras."

    /// "Premium ($4.99/month, 7-day free trial) …" — price from Apple when loaded, else no price claim.
    static func onboardingOffer(pricing: NaturalVoicePricing) -> String {
        var detail = pricing.monthly.map { "\($0.displayPrice)/month" } ?? ""
        if pricing.offersTrial { detail += (detail.isEmpty ? "" : ", ") + "7-day free trial" }
        let head = detail.isEmpty ? "Premium" : "Premium (\(detail))"
        return "\(head) adds Natural Voice, listen to articles in natural voices in languages other than English, and AI Summary."
    }

    static func onboardingStartTitle(pricing: NaturalVoicePricing) -> String {
        pricing.offersTrial ? "Start free trial" : "See Premium"
    }
}
