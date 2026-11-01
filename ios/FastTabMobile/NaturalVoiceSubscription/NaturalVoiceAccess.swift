import Foundation
import IndieAccount
import IndieLibKit
import IndieStore
import Observation
import StoreKit
import UIKit

/// The app's one Natural Voice subscription engine: IndieStore's `SubscriptionManager` (the only
/// StoreKit `Transaction.updates` listener) with FastTab's plan. Purchases are bound to the
/// theindie account on the server, so buying needs Sign in with Apple; built-in voices don't.
@MainActor
@Observable
final class NaturalVoiceAccess {
    static let shared = NaturalVoiceAccess()

    static let productIDs = PlusPlan.fastTabNaturalVoice.levels.map(\.productID)
    static let monthlyID = "fasttab.naturalVoice.monthly"
    static let yearlyID = "fasttab.naturalVoice.yearly"

    let manager: SubscriptionManager
    /// StoreKit on this device holds a current Natural Voice subscription.
    private(set) var ownsOnDevice = false
    @ObservationIgnored private var started = false

    var isEntitled: Bool {
        #if DEBUG
        if AppStoreDemo.isEnabled { return false } // paywall screenshots
        #endif
        return NaturalVoiceGate.isEntitled(state: manager.state, ownsOnDevice: ownsOnDevice, now: Date())
    }

    /// Paid at Apple; the server hasn't confirmed it yet (see `NaturalVoiceGate.awaitingConfirmation`).
    var isAwaitingConfirmation: Bool {
        NaturalVoiceGate.awaitingConfirmation(state: manager.state, ownsOnDevice: ownsOnDevice, now: Date())
    }

    var isConfirmedByServer: Bool { NaturalVoiceGate.isConfirmedByServer(state: manager.state, now: Date()) }

    @ObservationIgnored private var confirming: Task<Bool, Never>?

    /// Re-sends an unconfirmed purchase to the server a few times. True once the server confirms.
    /// Concurrent callers share one attempt; it also keeps retrying on every foreground.
    func confirmPurchase(attempts: Int = 5, delay: Duration = .seconds(3)) async -> Bool {
        if let confirming { return await confirming.value }
        let task = Task { @MainActor [self] in
            for attempt in 0..<attempts {
                if isConfirmedByServer { return true }
                await manager.resumePending()
                await refreshOwnership()
                if isConfirmedByServer { return true }
                if attempt < attempts - 1 { try? await Task.sleep(for: delay) }
            }
            return isConfirmedByServer
        }
        confirming = task
        defer { confirming = nil }
        return await task.value
    }

    private init() {
        let tokens = SessionTokenStore(keychain: KeychainStore(service: IndieAccountConfiguration.fastTab.keychainService))
        let api = TheIndieAPIClient(baseURL: TheIndieServerConfiguration.baseURL(configuration: .fastTab), sessionTokens: tokens)
        manager = SubscriptionManager(
            store: StoreKitClient(presentManageSubscriptions: Self.showManageSubscriptions),
            api: api, plusPlan: .fastTabNaturalVoice,
            isSignedIn: { tokens.token() != nil })
    }

    /// Call once at launch: starts the listener, retries unconfirmed purchases, loads prices.
    func start() {
        guard !started else { return }
        started = true
        manager.start()
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                               object: nil, queue: .main) { _ in
            Task { @MainActor in
                await NaturalVoiceAccess.shared.manager.resumePending()
                await NaturalVoiceAccess.shared.refreshOwnership()
            }
        }
        Task {
            await refreshOwnership()
            await manager.loadOffers()
        }
    }

    func refreshOwnership() async {
        ownsOnDevice = !(await manager.ownedProductIDs()).isEmpty
    }

    func purchase(_ productID: String) async -> SubscriptionPurchaseResult {
        let result = await manager.purchase(productID: productID)
        await refreshOwnership()
        return result
    }

    func restore() async -> RestoreOutcome {
        let outcome = await manager.restore()
        await refreshOwnership()
        return outcome
    }

    /// After sign-in: send any purchase the server hasn't confirmed yet.
    func accountDidSignIn() async {
        await manager.resumePending()
        await refreshOwnership()
    }

    @MainActor
    private static func showManageSubscriptions() async throws {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        try await AppStore.showManageSubscriptions(in: scene)
    }
}
