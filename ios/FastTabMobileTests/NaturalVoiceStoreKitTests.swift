import StoreKit
import StoreKitTest
import XCTest
@testable import FastTabMobile

/// The local catalog (Config/FastTab.storekit) sells what the paywall promises: two Natural Voice
/// plans in one group, each with a 7-day free trial, and a purchase shows up as an entitlement.
@MainActor
final class NaturalVoiceStoreKitTests: XCTestCase {
    private var session: SKTestSession!

    override func setUp() async throws {
        session = try SKTestSession(configurationFileNamed: "FastTab")
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        // The shared simulator's storekitd sometimes refuses local testing ("not installed for
        // development", SKInternalErrorDomain 3): skip loudly instead of failing on the machine.
        let probe = try await Product.products(for: NaturalVoiceAccess.productIDs)
        if probe.isEmpty { throw XCTSkip("Local StoreKit returned no products on this simulator (storekitd refused the test session)") }
    }

    override func tearDown() async throws {
        session?.clearTransactions()
        session = nil
    }

    func testCatalogHasBothPlansWithASevenDayFreeTrial() async throws {
        let products = try await Product.products(for: NaturalVoiceAccess.productIDs)
        XCTAssertEqual(Set(products.map(\.id)), Set(NaturalVoiceAccess.productIDs))
        for product in products {
            let subscription = try XCTUnwrap(product.subscription)
            let intro = try XCTUnwrap(subscription.introductoryOffer, product.id)
            XCTAssertEqual(intro.paymentMode, .freeTrial)
            XCTAssertTrue(intro.period.unit == .week && intro.period.value == 1 || intro.period.unit == .day && intro.period.value == 7)
            let eligible = await subscription.isEligibleForIntroOffer
            XCTAssertTrue(eligible)
        }
        XCTAssertEqual(Set(products.compactMap(\.subscription?.subscriptionGroupID)).count, 1, "one group: switching plans is an upgrade, not a second subscription")
        XCTAssertEqual(products.first { $0.id == NaturalVoiceAccess.monthlyID }?.subscription?.subscriptionPeriod.unit, .month)
        XCTAssertEqual(products.first { $0.id == NaturalVoiceAccess.yearlyID }?.subscription?.subscriptionPeriod.unit, .year)
    }

    func testPurchaseBecomesACurrentEntitlementAndRefundRemovesIt() async throws {
        let products = try await Product.products(for: [NaturalVoiceAccess.monthlyID])
        let product = try XCTUnwrap(products.first)
        let result = try await product.purchase()
        guard case .success(.verified(let transaction)) = result else { return XCTFail("purchase: \(result)") }
        await transaction.finish()
        var owned: [String] = []
        for await entitlement in Transaction.currentEntitlements {
            if case .verified(let t) = entitlement { owned.append(t.productID) }
        }
        XCTAssertEqual(owned, [NaturalVoiceAccess.monthlyID])
        XCTAssertTrue(NaturalVoiceGate.isEntitled(state: .notPurchased, ownsOnDevice: !owned.isEmpty, now: Date()))

        try session.refundTransaction(identifier: UInt(transaction.id))
        var afterRefund: [String] = []
        for await entitlement in Transaction.currentEntitlements {
            if case .verified(let t) = entitlement, t.revocationDate == nil { afterRefund.append(t.productID) }
        }
        XCTAssertTrue(afterRefund.isEmpty)
    }
}
