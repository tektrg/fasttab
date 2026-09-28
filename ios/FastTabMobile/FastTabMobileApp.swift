import SwiftUI
import FastTabSync

@main
public struct FastTabMobileApp: App {
    @UIApplicationDelegateAdaptor(PushNotificationAppDelegate.self) private var pushDelegate
    @StateObject private var syncConsumer = SyncConsumer.shared
    @StateObject private var localCache = LocalCache.shared
    @StateObject private var onboardingPresenter = OnboardingPresenter.shared
    @State private var selectedTab: AppTab = .read
    @Environment(\.scenePhase) private var scenePhase

    public init() {}

    public var body: some Scene {
        WindowGroup {
            TabView(selection: $selectedTab) {
                NavigationStack {
                    ReadingFeedView()
                }
                .tabItem {
                    Label("Read", systemImage: "newspaper")
                }
                .tag(AppTab.read)

                NavigationStack {
                    TabListView()
                        .navigationTitle("Tabs")
                }
                .tabItem {
                    Label("Tabs", systemImage: "macwindow.on.rectangle")
                }
                .tag(AppTab.tabs)

                NavigationStack {
                    RandomLinksView()
                }
                .tabItem {
                    Label("Shuffle", systemImage: "shuffle")
                }
                .tag(AppTab.shuffle)

                NavigationStack {
                    MoreView()
                }
                .tabItem {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .tag(AppTab.more)
            }
            .fullScreenCover(item: $onboardingPresenter.fullScreen) { presentation in
                OnboardingFlowView(route: presentation.route) { exit in
                    OnboardingCompletionStore().markCompleted()
                    onboardingPresenter.fullScreen = nil
                    if exit == .finished { selectedTab = .read }
                }
            }
            .sheet(item: $onboardingPresenter.sheet) { presentation in
                OnboardingFlowView(route: presentation.route) { _ in
                    onboardingPresenter.sheet = nil
                }
                .presentationDragIndicator(.visible)
            }
            .onAppear {
                presentOnboardingOnFirstLaunch()
                syncConsumer.start()
                RecentAddedProvider.shared.drainPendingShares()
                RecentAddedProvider.shared.refresh()
                EmergingContentProvider.shared.refresh()
                ReadingStatsRecorder.shared.pruneExpiredEvents()
            }
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .active:
                    RecentAddedProvider.shared.drainPendingShares()
                    RecentAddedProvider.shared.refresh()
                    EmergingContentProvider.shared.refresh()
                    LastOpenedStore.shared.loadFromDisk()

                    Task { await syncConsumer.refreshNow() }
                    syncConsumer.startForegroundRefresh()
                case .background:
                    syncConsumer.stopForegroundRefresh()
                    localCache.flushPendingSave()
                default:
                    syncConsumer.stopForegroundRefresh()
                }
            }
        }
    }
}

private extension FastTabMobileApp {
    func presentOnboardingOnFirstLaunch() {
        let hasCachedMac = localCache.state.connectedMac != nil
        guard OnboardingCompletionStore().resolveLaunchPresentation(hasCachedMac: hasCachedMac) else { return }
        onboardingPresenter.present(.fullGuide)
    }
}

/// The four root tabs, so the guide can land on Read when it finishes.
enum AppTab: Hashable {
    case read, tabs, shuffle, more
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

