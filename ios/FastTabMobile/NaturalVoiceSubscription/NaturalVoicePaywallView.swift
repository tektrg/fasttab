import IndieAccount
import IndieStore
import StoreKit
import SwiftUI

/// Shown when someone turns on "Natural voice" without a subscription. Apple's required terms
/// (price, period, trial, auto-renewal, how to cancel) and the Terms of Use + Privacy links sit
/// above the buy button. Built-in voices stay free: closing this changes nothing.
struct NaturalVoicePaywallView: View {
    /// Called after a purchase or restore that unlocked the voice.
    var onUnlocked: () -> Void = {}

    @Environment(AccountSession.self) private var accountSession
    @Environment(\.dismiss) private var dismiss
    @State private var selected = NaturalVoiceAccess.yearlyID
    @State private var pricing = NaturalVoicePricing.loading
    @State private var isWorking = false
    @State private var message: String?
    /// Paid at Apple, waiting for the server to confirm it.
    @State private var isConfirming = false
    private let access = NaturalVoiceAccess.shared

    static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let privacyURL = URL(string: "https://fasttab.theindie.app/privacy")!

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.lg) {
                    header
                    benefits
                    plans
                    terms
                    action
                    footerLinks
                }
                .padding(DS.Space.gutter)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Not Now") { dismiss() } }
            }
        }
        .task {
            pricing = await Self.loadPricing()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Natural Voice")
                .font(.largeTitle.bold())
            Text("Listen to articles and transcripts in a human-sounding voice.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var benefits: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Label("Lifelike voices streamed from the cloud", systemImage: "sparkles")
            Label("Keeps playing with the screen locked", systemImage: "lock.fill")
            Label("Built-in iPhone voices stay free", systemImage: "checkmark.circle")
        }
        .font(.body)
    }

    private var plans: some View {
        VStack(spacing: DS.Space.sm) {
            planRow(NaturalVoiceAccess.yearlyID, title: "Yearly", period: "year", badge: pricing.savingsBadge)
            planRow(NaturalVoiceAccess.monthlyID, title: "Monthly", period: "month", badge: nil)
        }
    }

    private func planRow(_ id: String, title: String, period: String, badge: String?) -> some View {
        let priceLine = pricing.priceText(id).map { "\($0) / \(period)" } ?? "Loading price…"
        let isSelected = selected == id
        return Button { selected = id } label: {
            HStack {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: DS.Space.sm) {
                        Text(title).font(.headline)
                        if let badge {
                            Text(badge).font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.tint.opacity(0.15), in: Capsule())
                        }
                    }
                    Text(priceLine).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(DS.Space.md)
            .background(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                .stroke(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), lineWidth: isSelected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var selectedPeriod: String { selected == NaturalVoiceAccess.yearlyID ? "year" : "month" }

    @ViewBuilder
    private var terms: some View {
        if let price = pricing.priceText(selected) {
            Text(Self.termsText(price: price, period: selectedPeriod, trial: pricing.offersTrial))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// Apple guideline 3.1.2: price per period, trial, auto-renewal and how to cancel, before buying.
    static func termsText(price: String, period: String, trial: Bool) -> String {
        let start = trial ? "Free for 7 days, then \(price) per \(period)." : "\(price) per \(period)."
        return start + " Renews automatically until cancelled. Cancel anytime in Settings › Apple Account › Subscriptions at least 24 hours before the period ends. Natural voice includes a fair-use monthly allowance; Read Aloud switches to the built-in voice if it runs out. Purchases are linked to your Sign in with Apple account."
    }

    @ViewBuilder
    private var action: some View {
        if isConfirming {
            HStack(spacing: DS.Space.sm) {
                ProgressView()
                Text("Confirming your purchase…").font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.Space.sm)
            .accessibilityElement(children: .combine)
        } else if accountSession.hasStoredSession || Self.demoSignedIn {
            Button {
                Task { await buy() }
            } label: {
                Text(NaturalVoicePricing.buttonTitle(offersTrial: pricing.offersTrial))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DS.Space.sm)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isWorking || !pricing.canBuy(selected))
        } else {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                Text("Sign in first so your subscription works on all your devices.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                AppleSignInButton {
                    Task { await access.accountDidSignIn() }
                }
            }
        }
        if let message {
            Text(message).font(.footnote).foregroundStyle(.red)
        }
    }

    private var footerLinks: some View {
        HStack {
            Button("Restore Purchases") { Task { await restore() } }
                .disabled(isWorking)
            Spacer()
            Link("Terms of Use", destination: Self.termsURL)
            Text("·").foregroundStyle(.secondary)
            Link("Privacy", destination: Self.privacyURL)
        }
        .font(.footnote)
    }

    private func buy() async {
        isWorking = true
        defer { isWorking = false }
        message = nil
        let result = await access.purchase(selected)
        switch NaturalVoiceGate.afterPurchase(result, confirmed: access.isConfirmedByServer) {
        case .unlocked:
            onUnlocked()
            dismiss()
        case .confirming:
            await confirm()
        case .waitingForApproval:
            message = "Waiting for approval. Natural voice turns on once it's approved."
        case .cancelled:
            break
        case .failed(let error):
            message = Self.message(for: error)
        }
    }

    /// Apple charged; keep retrying the server instead of closing as if it already worked.
    private func confirm() async {
        isConfirming = true
        defer { isConfirming = false }
        if await access.confirmPurchase() {
            onUnlocked()
            dismiss()
        } else {
            message = Self.stillConfirmingMessage
        }
    }

    static let stillConfirmingMessage = "Payment received. We're still confirming it with our server; natural voice turns on automatically, no need to buy again."

    private func restore() async {
        isWorking = true
        defer { isWorking = false }
        message = nil
        switch await access.restore() {
        case .restored:
            if access.isConfirmedByServer { onUnlocked(); dismiss() }
            else if access.isAwaitingConfirmation { await confirm() }
            else { message = "No active Natural Voice subscription found." }
        case .nothingToRestore:
            message = "No Natural Voice subscription to restore."
        case .failed(let error):
            message = Self.message(for: error)
        }
    }

    static func message(for error: SubscriptionError) -> String {
        switch error {
        case .notSignedIn: return "Sign in with Apple first."
        case .boundElsewhere: return "This subscription belongs to another account. Sign in with that account."
        case .accountMismatch: return "This purchase was made with another account."
        case .productUnavailable: return "Subscriptions aren't available right now. Try again later."
        case .unavailableRetryLater: return "Payment went through, but we couldn't confirm it yet. It will finish automatically."
        case .rejectedByServer, .storeFailed: return "Something went wrong. Try again, or restore purchases."
        }
    }

    private static var demoSignedIn: Bool {
        #if DEBUG
        return AppStoreDemo.isEnabled
        #else
        return false
        #endif
    }

    private static func loadPricing() async -> NaturalVoicePricing {
        #if DEBUG
        // App Store screenshots run without a StoreKit session: show the US catalog.
        if AppStoreDemo.isEnabled {
            return NaturalVoicePricing(monthly: .init(displayPrice: "$4.99", price: Decimal(string: "4.99")!),
                                       yearly: .init(displayPrice: "$39.99", price: Decimal(string: "39.99")!),
                                       trial: .eligible)
        }
        #endif
        return await NaturalVoicePricing.load()
    }
}
