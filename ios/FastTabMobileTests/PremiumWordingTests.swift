import XCTest
@testable import FastTabMobile

/// The More tab Premium card and the last onboarding step: states and wording.
final class PremiumWordingTests: XCTestCase {
    private let us = NaturalVoicePricing(monthly: .init(displayPrice: "$4.99", price: 4.99),
                                         yearly: .init(displayPrice: "$39.99", price: 39.99), trial: .eligible)
    private func noTrial() -> NaturalVoicePricing { var p = us; p.trial = .ineligible; return p }

    func testStates() {
        XCTAssertEqual(PremiumWording.state(entitled: false, awaitingConfirmation: false, pricing: .loading), .loadingPrice)
        XCTAssertEqual(PremiumWording.state(entitled: false, awaitingConfirmation: false, pricing: noTrial()), .notSubscribed)
        XCTAssertEqual(PremiumWording.state(entitled: false, awaitingConfirmation: false, pricing: us), .trialAvailable)
        XCTAssertEqual(PremiumWording.state(entitled: true, awaitingConfirmation: false, pricing: us), .subscribed)
        XCTAssertEqual(PremiumWording.state(entitled: true, awaitingConfirmation: true, pricing: us), .confirming)
    }

    func testLoadingPriceCannotSubscribeYet() {
        let card = PremiumWording.card(.loadingPrice, pricing: .loading)
        XCTAssertFalse(card.canSubscribe)
        XCTAssertNil(card.priceLine)
        XCTAssertEqual(card.subtitle, "Loading price…")
    }

    func testTrialShowsAppleMonthlyAndYearlyPrices() {
        let card = PremiumWording.card(.trialAvailable, pricing: us)
        XCTAssertEqual(card.priceLine, "7-day free trial, then $4.99 / month · $39.99 / year")
        XCTAssertEqual(card.subscribeTitle, "Start Free Trial")
        XCTAssertTrue(card.canSubscribe)
    }

    func testNotSubscribedWithoutTrialMakesNoTrialClaim() {
        let card = PremiumWording.card(.notSubscribed, pricing: noTrial())
        XCTAssertEqual(card.priceLine, "$4.99 / month · $39.99 / year")
        XCTAssertEqual(card.subscribeTitle, "Subscribe")
    }

    func testSubscribedShowsActiveAndNoSubscribeButton() {
        let card = PremiumWording.card(.subscribed, pricing: us)
        XCTAssertEqual(card.badge, "Active")
        XCTAssertNil(card.subscribeTitle)
    }

    func testConfirmingHasNoSubscribeButton() {
        XCTAssertNil(PremiumWording.card(.confirming, pricing: us).subscribeTitle)
    }

    func testOnboardingOfferUsesLoadedPriceAndTrial() {
        XCTAssertEqual(PremiumWording.onboardingOffer(pricing: us),
                       "Premium ($4.99/month, 7-day free trial) adds Natural Voice, listen to articles in natural voices in languages other than English, and AI Summary.")
        XCTAssertTrue(PremiumWording.onboardingOffer(pricing: .loading).hasPrefix("Premium adds Natural Voice"))
        XCTAssertEqual(PremiumWording.onboardingStartTitle(pricing: us), "Start free trial")
        XCTAssertEqual(PremiumWording.onboardingStartTitle(pricing: noTrial()), "See Premium")
    }
}
