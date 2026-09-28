import SwiftUI
import FastTabSync

/// When a screen other than More should carry the sync banner.
///
/// More always shows `DataFreshnessBanner`. Read and Tabs show it only when the
/// problem changes what the screen can show: sync cannot run at all, no Mac is
/// connected, or the Mac has been silent for a day. A Mac that is merely asleep
/// stays quiet here, because that is the normal state of a closed laptop.
enum SyncWarningPolicy {
    static func shouldWarn(health: SyncHealth, mac: SyncedDevice?, now: Date = Date()) -> Bool {
        if SyncStatusCopy.healthBadge(for: health)?.severity == .blocked { return true }
        return SyncStatusCopy.macFreshness(device: mac, now: now).isOffline
    }
}

/// `DataFreshnessBanner` at the top of Read and Tabs, shown only when
/// `SyncWarningPolicy` says so. Tapping it opens "Connect your Mac".
struct SyncWarningBanner: View {
    @ObservedObject private var syncConsumer = SyncConsumer.shared
    @ObservedObject private var localCache = LocalCache.shared

    private var mac: SyncedDevice? {
        SyncedMacs.mostRecentMac(in: localCache.state.devices)
    }

    var body: some View {
        if SyncWarningPolicy.shouldWarn(health: syncConsumer.syncHealth, mac: mac) {
            Button {
                OnboardingPresenter.shared.present(.singleStep(.connectMac))
            } label: {
                DataFreshnessBanner(device: mac, lastSyncedAt: localCache.state.lastSyncedAt)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                    .dsShadow(.card)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens Connect your Mac")
            .padding(.horizontal, DS.Space.gutter)
            .padding(.vertical, DS.Space.xs)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
