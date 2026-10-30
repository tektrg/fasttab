import IndieStore
import XCTest
@testable import FastTabMobile

/// The paid cloud voice is gated; built-in voices never are.
final class NaturalVoiceGateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testNotPurchasedIsLockedUnlessStoreKitHoldsIt() {
        XCTAssertFalse(NaturalVoiceGate.isEntitled(state: .notPurchased, ownsOnDevice: false, now: now))
        XCTAssertTrue(NaturalVoiceGate.isEntitled(state: .notPurchased, ownsOnDevice: true, now: now))
    }

    func testActiveAndGraceUnlockUntilTheirEnd() {
        XCTAssertTrue(NaturalVoiceGate.isEntitled(state: .active(until: now + 60, autoRenew: true), ownsOnDevice: false, now: now))
        XCTAssertFalse(NaturalVoiceGate.isEntitled(state: .active(until: now - 60, autoRenew: false), ownsOnDevice: false, now: now))
        XCTAssertTrue(NaturalVoiceGate.isEntitled(state: .grace(until: now + 60), ownsOnDevice: false, now: now))
        XCTAssertFalse(NaturalVoiceGate.isEntitled(state: .grace(until: now - 60), ownsOnDevice: false, now: now))
    }

    func testExpiredErrorAndPendingStatesLock() {
        for state: SubscriptionState in [.expired(on: now), .error(.notSignedIn), .pendingApproval, .purchasing] {
            XCTAssertFalse(NaturalVoiceGate.isEntitled(state: state, ownsOnDevice: false, now: now), "\(state)")
        }
        // Paid but the server hasn't confirmed yet: StoreKit's word unlocks the UI (server still checks).
        XCTAssertTrue(NaturalVoiceGate.isEntitled(state: .pendingServer, ownsOnDevice: true, now: now))
    }

    func testCloudVoiceNeedsBothTheSwitchAndTheSubscription() {
        XCTAssertTrue(NaturalVoiceGate.usesNaturalVoice(toggleOn: true, entitled: true))
        XCTAssertFalse(NaturalVoiceGate.usesNaturalVoice(toggleOn: true, entitled: false))
        XCTAssertFalse(NaturalVoiceGate.usesNaturalVoice(toggleOn: false, entitled: true))
    }

    func testToggleOpensThePaywallOnlyWhenTurningOnWithoutSubscription() {
        XCTAssertEqual(NaturalVoiceGate.toggleAction(wantsOn: true, entitled: false), .showPaywall)
        XCTAssertEqual(NaturalVoiceGate.toggleAction(wantsOn: true, entitled: true), .turnOn)
        XCTAssertEqual(NaturalVoiceGate.toggleAction(wantsOn: false, entitled: false), .turnOff)
    }

    func testServerSubscriptionRequiredMapsToItsOwnError() {
        let body = Data(#"{"code":"tts_subscription_required"}"#.utf8)
        XCTAssertEqual(NaturalVoiceClient.error(status: 402, body: body), .subscriptionRequired)
        let quota = Data(#"{"code":"tts_user_quota"}"#.utf8)
        XCTAssertEqual(NaturalVoiceClient.error(status: 402, body: quota), .quotaExhausted(resetsAt: nil))
    }

    func testPaywallTermsStatePriceTrialRenewalAndCancel() {
        let text = NaturalVoicePaywallView.termsText(price: "$4.99", period: "month", trial: true)
        XCTAssertTrue(text.hasPrefix("Free for 7 days, then $4.99 per month."))
        XCTAssertTrue(text.contains("Renews automatically until cancelled"))
        XCTAssertTrue(text.contains("Cancel anytime"))
        XCTAssertFalse(NaturalVoicePaywallView.termsText(price: "$39.99", period: "year", trial: false).contains("Free for 7 days"))
    }
}
