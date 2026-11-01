import XCTest
@testable import FastTabMobile

/// Guideline 3.1.2: the paywall shows only Apple's localized prices, a savings badge computed from
/// them, and a free-trial claim only for someone Apple says is eligible.
final class NaturalVoicePricingTests: XCTestCase {
    private let monthly = NaturalVoicePricing.Plan(displayPrice: "4,99 €", price: Decimal(string: "4.99")!)
    private let yearly = NaturalVoicePricing.Plan(displayPrice: "39,99 €", price: Decimal(string: "39.99")!)

    func testCannotBuyUntilTheSelectedPlanHasALoadedPrice() {
        let empty = NaturalVoicePricing(monthly: nil, yearly: nil, trial: .unknown)
        XCTAssertFalse(empty.canBuy(NaturalVoiceAccess.yearlyID))
        XCTAssertNil(empty.priceText(NaturalVoiceAccess.yearlyID), "never a hard-coded USD fallback")
        let loaded = NaturalVoicePricing(monthly: monthly, yearly: yearly, trial: .unknown)
        XCTAssertTrue(loaded.canBuy(NaturalVoiceAccess.yearlyID))
        XCTAssertEqual(loaded.priceText(NaturalVoiceAccess.monthlyID), "4,99 €")
    }

    func testSavingsBadgeComesFromLoadedPricesOrIsHidden() {
        XCTAssertEqual(NaturalVoicePricing(monthly: monthly, yearly: yearly, trial: .unknown).savingsBadge, "Save 33%")
        XCTAssertNil(NaturalVoicePricing(monthly: nil, yearly: yearly, trial: .unknown).savingsBadge)
        let noSaving = NaturalVoicePricing.Plan(displayPrice: "60", price: 60)
        XCTAssertNil(NaturalVoicePricing(monthly: monthly, yearly: noSaving, trial: .unknown).savingsBadge)
    }

    func testFreeTrialIsClaimedOnlyWhenAppleSaysEligible() {
        XCTAssertTrue(NaturalVoicePricing(monthly: monthly, yearly: yearly, trial: .eligible).offersTrial)
        XCTAssertFalse(NaturalVoicePricing(monthly: monthly, yearly: yearly, trial: .ineligible).offersTrial)
        XCTAssertFalse(NaturalVoicePricing(monthly: monthly, yearly: yearly, trial: .unknown).offersTrial)
        XCTAssertEqual(NaturalVoicePricing.buttonTitle(offersTrial: false), "Subscribe")
        XCTAssertEqual(NaturalVoicePricing.buttonTitle(offersTrial: true), "Start Free Trial")
        XCTAssertFalse(NaturalVoicePaywallView.termsText(price: "4,99 €", period: "month", trial: false).contains("Free"))
    }
}
