import Foundation
import StoreKit

/// What the Natural Voice paywall may say about price and trial, from Apple's loaded products only
/// (guideline 3.1.2): no hard-coded prices, a savings badge computed from real prices, and a
/// free-trial claim only when Apple says this person is eligible.
struct NaturalVoicePricing: Equatable {
    struct Plan: Equatable {
        let displayPrice: String
        let price: Decimal
    }

    enum Trial: Equatable { case eligible, ineligible, unknown }

    var monthly: Plan?
    var yearly: Plan?
    var trial: Trial

    static let loading = NaturalVoicePricing(monthly: nil, yearly: nil, trial: .unknown)

    func plan(_ productID: String) -> Plan? {
        productID == NaturalVoiceAccess.yearlyID ? yearly : productID == NaturalVoiceAccess.monthlyID ? monthly : nil
    }

    /// Apple's localized price, or nil while it loads (the row then says "Loading price…").
    func priceText(_ productID: String) -> String? { plan(productID)?.displayPrice }

    /// Buying waits until the price the person is agreeing to is on screen.
    func canBuy(_ productID: String) -> Bool { plan(productID) != nil }

    /// "Save N%" of yearly against twelve months, rounded down; hidden unless both prices loaded and it saves.
    var savingsBadge: String? {
        guard let monthly, let yearly, monthly.price > 0 else { return nil }
        let fullYear = monthly.price * 12
        guard yearly.price < fullYear else { return nil }
        var raw = (fullYear - yearly.price) / fullYear * 100, whole = Decimal()
        NSDecimalRound(&whole, &raw, 0, .down)
        let percent = NSDecimalNumber(decimal: whole).intValue
        return percent >= 1 ? "Save \(percent)%" : nil
    }

    var offersTrial: Bool { trial == .eligible }

    static func buttonTitle(offersTrial: Bool) -> String { offersTrial ? "Start Free Trial" : "Subscribe" }

    /// Loads both plans and the intro-offer eligibility from StoreKit. Missing pieces stay nil/unknown.
    static func load() async -> NaturalVoicePricing {
        guard let products = try? await Product.products(for: NaturalVoiceAccess.productIDs) else { return .loading }
        func plan(_ id: String) -> Plan? {
            products.first { $0.id == id }.map { Plan(displayPrice: $0.displayPrice, price: $0.price) }
        }
        var trial = Trial.unknown
        if let subscription = products.first(where: { $0.subscription?.introductoryOffer != nil })?.subscription {
            trial = await subscription.isEligibleForIntroOffer ? .eligible : .ineligible
        }
        return NaturalVoicePricing(monthly: plan(NaturalVoiceAccess.monthlyID), yearly: plan(NaturalVoiceAccess.yearlyID), trial: trial)
    }
}
