import SwiftUI
import FastTabSync
import IndieAccount

@main
public struct FastTabMobileApp: App {
    @UIApplicationDelegateAdaptor(PushNotificationAppDelegate.self) private var pushDelegate
    @StateObject private var syncConsumer = SyncConsumer.shared
    @StateObject private var localCache = LocalCache.shared
    @StateObject private var onboardingPresenter = OnboardingPresenter.shared
    @StateObject private var appMode = AppModeModel.shared
    @Environment(\.scenePhase) private var scenePhase
    /// The one theindie account session (Sign in with Apple); YouTube transcripts need it.
    /// Its keychain slot is the one `YouTubeTranscriptLoader` reads the token from.
    @State private var accountSession = AccountSession.live(configuration: .fastTab, deviceName: UIDevice.current.name)
    @State private var selectedTab = AppTab.read
    /// An article a widget tap asked to open (`WidgetDeepLink.read`).
    @State private var widgetReaderItem: ReaderNavigationItem?
    #if DEBUG
    @State private var showsDemoPaywall = false
    #endif
    /// A widget article that arrived while the guide was up. SwiftUI shows one
    /// modal per host view, so it waits for the guide's dismissal to finish.
    @State private var deferredWidgetReaderItem: ReaderNavigationItem?
    /// App-wide notices, e.g. "Mac found — Tabs added".
    @State private var rootToast: String?

    public init() {
        #if DEBUG
        if AppStoreDemo.isEnabled { AppStoreDemo.hideTips() }
        #endif
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

                if visibleTabs.contains(.tabs) {
                    NavigationStack {
                        TabListView()
                            .navigationTitle("Tabs")
                    }
                    .tabItem {
                        Label("Tabs", systemImage: "macwindow.on.rectangle")
                    }
                    .tag(AppTab.tabs)
                }

                NavigationStack {
                    RandomLinksView()
                }
                .tabItem {
                    Label("Shuffle", systemImage: "shuffle")
                }
                .tag(AppTab.shuffle)

                NavigationStack {
                    #if DEBUG
                    if AppStoreDemo.isEnabled && AppStoreDemo.screen == .highlights {
                        HighlightsListView()
                    } else if AppStoreDemo.isEnabled && AppStoreDemo.screen == .bookmarks {
                        BookmarkTreeView(device: nil)
                            .navigationTitle("Bookmarks")
                    } else {
                        MoreView()
                    }
                    #else
                    MoreView()
                    #endif
                }
                .tabItem {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .tag(AppTab.more)
            }
            .environment(accountSession)
            .dsToast($rootToast)
            .onChange(of: appMode.mode) { _, newMode in
                selectedTab = AppTab.resolved(selectedTab, for: newMode)
            }
            // One way only: a reader-only phone that starts seeing a Mac becomes a companion.
            .onChange(of: localCache.state.connectedMac?.id) { oldMacID, newMacID in
                guard oldMacID == nil, newMacID != nil, appMode.macAppeared() else { return }
                rootToast = "Mac found — Tabs added"
            }
            .ratingPrompt()
            .task { await accountSession.restoreIfNeeded() }
            // Natural Voice subscription: the one StoreKit listener, started at launch.
            .task { NaturalVoiceAccess.shared.start() }
            .onChange(of: accountSession.state) { _, state in
                if case .signedIn = state { Task { await NaturalVoiceAccess.shared.accountDidSignIn() } }
            }
            #if DEBUG
            .task { await TranscriptCleanupSpeedTest.runIfRequested() }
            #endif
            #if DEBUG
            .sheet(isPresented: $showsDemoPaywall) { NaturalVoicePaywallView() }
            #endif
            .fullScreenCover(item: $widgetReaderItem) { item in
                ReaderView(url: item.url, title: item.title, focusHighlightID: item.focusHighlightID)
            }
            .onOpenURL { url in
                guard let link = WidgetDeepLink(url: url) else { return }
                open(link)
            }
            .fullScreenCover(item: $onboardingPresenter.fullScreen, onDismiss: presentDeferredWidgetReaderItem) { presentation in
                OnboardingFlowView(route: presentation.route) { exit in
                    OnboardingCompletionStore().markCompleted()
                    FastTabTips.isOnboardingCompleted = true
                    onboardingPresenter.fullScreen = nil
                    if exit == .finished { selectedTab = .read }
                }
            }
            .sheet(item: $onboardingPresenter.sheet, onDismiss: presentDeferredWidgetReaderItem) { presentation in
                OnboardingFlowView(route: presentation.route) { _ in
                    onboardingPresenter.sheet = nil
                }
                .presentationDragIndicator(.visible)
            }
            .onAppear {
                #if DEBUG
                if AppStoreDemo.isEnabled {
                    startAppStoreDemo()
                    return
                }
                #endif
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
                    RecentAddedProvider.shared.refresh() // drains pending shares first
                    EmergingContentProvider.shared.refresh()
                    LastOpenedStore.shared.loadFromDisk()
                    WidgetSnapshotPublisher.shared.reloadReading()

                    Task { await syncConsumer.refreshNow() }
                    Task { await accountSession.restoreIfNeeded() }
                    syncConsumer.startForegroundRefresh()
                case .background:
                    syncConsumer.stopForegroundRefresh()
                    localCache.flushPendingSave()
                    WidgetSnapshotPublisher.shared.flushPendingWrite()
                    SavedOnIPhoneStore.shared.flushPendingWrite()
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
            let item = ReaderNavigationItem(url: url, title: title, focusHighlightID: highlightID)
            // The widget tap is the user's latest intent: close the guide, then open.
            if onboardingPresenter.isPresenting {
                deferredWidgetReaderItem = item
                onboardingPresenter.dismissAll()
            } else {
                widgetReaderItem = item
            }
        case .stats:
            selectedTab = .more
        case .tabs:
            selectedTab = AppTab.resolved(.tabs, for: appMode.mode)
        }
    }
}

private extension FastTabMobileApp {
    func presentDeferredWidgetReaderItem() {
        guard let item = deferredWidgetReaderItem else { return }
        deferredWidgetReaderItem = nil
        widgetReaderItem = item
    }

    var visibleTabs: [AppTab] { AppTab.visible(for: appMode.mode) }

    #if DEBUG
    /// App Store screenshots (`AppStoreDemo`): demo library, no sync, no guide.
    private func startAppStoreDemo() {
        AppStoreDemo.seed()
        if !appMode.isStandalone { AppStoreDemo.seedMac() }
        RecentAddedProvider.shared.refresh()
        EmergingContentProvider.shared.refresh()
        switch AppStoreDemo.screen {
        case .read: selectedTab = .read
        case .shuffle, .swipe: selectedTab = .shuffle
        case .paywall:
            selectedTab = .read
            showsDemoPaywall = true
        case .more, .highlights, .bookmarks: selectedTab = .more
        case .tabs: selectedTab = .tabs
        case .reader, .listen:
            selectedTab = .read
            let article = AppStoreDemo.screen == .listen ? AppStoreDemo.listenArticle : AppStoreDemo.featured
            if let url = URL(string: article.url) {
                widgetReaderItem = ReaderNavigationItem(url: url, title: article.title, focusHighlightID: nil)
            }
        case .transcript:
            selectedTab = .read
            widgetReaderItem = ReaderNavigationItem(url: AppStoreDemo.transcriptURL,
                                                    title: AppStoreDemo.transcriptTitle, focusHighlightID: nil)
        }
    }
    #endif

    func presentOnboardingOnFirstLaunch() {
        #if DEBUG
        // Screenshots/QA: `-FastTabShowGuide YES` opens the guide even on a set-up device.
        if UserDefaults.standard.bool(forKey: "FastTabShowGuide") {
            onboardingPresenter.present(.fullGuide)
            return
        }
        #endif
        let hasCachedMac = localCache.state.connectedMac != nil
        let completionStore = OnboardingCompletionStore()
        // Before the guide's own check below marks Mac users done: either signal means `mac`.
        appMode.resolveOnLaunch(onboardingCompleted: completionStore.isCompleted, hasCachedMac: hasCachedMac)
        let shouldPresentGuide = completionStore.resolveLaunchPresentation(hasCachedMac: hasCachedMac)
        // An upgrading user was just marked done: let their tips show.
        FastTabTips.isOnboardingCompleted = completionStore.isCompleted
        // A cold launch from a widget already has the reader up; the guide
        // waits for the next launch rather than fight it for the screen.
        guard shouldPresentGuide, widgetReaderItem == nil else { return }
        onboardingPresenter.present(.fullGuide)
    }
}

/// The root tab bar's tabs, so a widget deep link or the finished guide can switch between them.
enum AppTab: Hashable, CaseIterable {
    case read, tabs, shuffle, more

    /// Reader-only phones have no Mac tabs to show. Undecided users see everything.
    static func visible(for mode: AppMode?) -> [AppTab] {
        mode == .standalone ? allCases.filter { $0 != .tabs } : allCases
    }

    /// `tab` if this mode shows it, else Read.
    static func resolved(_ tab: AppTab, for mode: AppMode?) -> AppTab {
        visible(for: mode).contains(tab) ? tab : .read
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

