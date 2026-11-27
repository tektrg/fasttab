import IndieAccount
import SwiftUI

/// More tab "Premium" section: the in-app purchase made findable. Subscribe opens the existing
/// paywall; Restore and Manage call the shared subscription engine. Wording: `PremiumWording`.
struct PremiumCard: View {
    @Environment(AccountSession.self) private var accountSession
    @State private var pricing = NaturalVoicePricing.loading
    @State private var showsPaywall = false
    @State private var isWorking = false
    @State private var message: String?
    private let access = NaturalVoiceAccess.shared

    private var state: PremiumWording.State {
        PremiumWording.state(entitled: access.isEntitled, awaitingConfirmation: access.isAwaitingConfirmation, pricing: pricing)
    }

    var body: some View {
        let card = PremiumWording.card(state, pricing: pricing)
        Section("Premium") {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                HStack(spacing: DS.Space.md) {
                    Image(systemName: "sparkles")
                        .font(.system(size: DS.IconSize.row))
                        .foregroundStyle(DS.Tint.emerging)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text(PremiumWording.title).font(DS.Font.body.weight(.medium))
                        Text(card.subtitle).font(DS.Font.meta).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let badge = card.badge {
                        Text(badge).font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.tint.opacity(0.15), in: Capsule())
                    }
                }
                if let line = card.priceLine {
                    Text(line).font(DS.Font.meta).foregroundStyle(.secondary)
                }
                if card.subscribeTitle != nil {
                    Text(PremiumWording.freeNote).font(DS.Font.meta).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, DS.Space.xs)
            if let title = card.subscribeTitle {
                Button(title) { showsPaywall = true }
                    .disabled(!card.canSubscribe)
            }
            Button("Restore Purchases") { Task { await restore() } }
                .disabled(isWorking)
            Button("Manage Subscription") { Task { await access.manager.manage() } }
            if let message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .dsListRow()
        .task { pricing = await NaturalVoicePricing.load() }
        .sheet(isPresented: $showsPaywall) {
            NaturalVoicePaywallView().environment(accountSession)
        }
    }

    private func restore() async {
        isWorking = true
        defer { isWorking = false }
        message = nil
        switch await access.restore() {
        case .restored: message = access.isEntitled ? nil : "No active subscription found."
        case .nothingToRestore: message = "No subscription to restore."
        case .failed(let error): message = NaturalVoicePaywallView.message(for: error)
        }
    }
}
