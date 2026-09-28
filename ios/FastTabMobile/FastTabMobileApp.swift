import SwiftUI
import FastTabSync

@main
public struct FastTabMobileApp: App {
    @UIApplicationDelegateAdaptor(PushNotificationAppDelegate.self) private var pushDelegate
    @StateObject private var syncConsumer = SyncConsumer.shared
    @StateObject private var localCache = LocalCache.shared
    @StateObject private var onboardingPresenter = OnboardingPresenter.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = AppTab.read
    /// An article a widget tap asked to open (`WidgetDeepLink.read`).
    @State private var widgetReaderItem: ReaderNavigationItem?

    public init() {
        FastTabTips.configure(onboardingCompleted: OnboardingCompletionStore().isCompleted)
    }

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
            .fullScreenCover(item: $widgetReaderItem) { item in
                ReaderView(url: item.url, title: item.title, focusHighlightID: item.focusHighlightID)
            }
            .onOpenURL { url in
                guard let link = WidgetDeepLink(url: url) else { return }
                open(link)
            }
            .fullScreenCover(item: $onboardingPresenter.fullScreen) { presentation in
                OnboardingFlowView(route: presentation.route) { exit in
                    OnboardingCompletionStore().markCompleted()
                    FastTabTips.isOnboardingCompleted = true
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
                WidgetSnapshotPublisher.shared.start()
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
                    WidgetSnapshotPublisher.shared.reloadReading()

                    Task { await syncConsumer.refreshNow() }
                    syncConsumer.startForegroundRefresh()
                case .background:
                    syncConsumer.stopForegroundRefresh()
                    localCache.flushPendingSave()
                    WidgetSnapshotPublisher.shared.flushPendingWrite()
                default:
                    syncConsumer.stopForegroundRefresh()
                }
            }
        }
    }

    private func open(_ link: WidgetDeepLink) {
        switch link {
        case .read(let url, let title, let highlightID):
            LastOpenedStore.shared.recordOpened(url: url, title: title)
            widgetReaderItem = ReaderNavigationItem(url: url, title: title, focusHighlightID: highlightID)
        case .stats:
            selectedTab = .more
        case .tabs:
            selectedTab = .tabs
        }
    }
}

private extension FastTabMobileApp {
    func presentOnboardingOnFirstLaunch() {
        let hasCachedMac = localCache.state.connectedMac != nil
        let completionStore = OnboardingCompletionStore()
        let shouldPresentGuide = completionStore.resolveLaunchPresentation(hasCachedMac: hasCachedMac)
        // An upgrading user was just marked done: let their tips show.
        FastTabTips.isOnboardingCompleted = completionStore.isCompleted
        guard shouldPresentGuide else { return }
        onboardingPresenter.present(.fullGuide)
    }
}

/// The root tab bar's tabs, so a widget deep link or the finished guide can switch between them.
enum AppTab: Hashable {
    case read, tabs, shuffle, more
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

