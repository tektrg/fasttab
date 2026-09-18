import SwiftUI
import FastTabSync

@main
public struct FastTabMobileApp: App {
    @UIApplicationDelegateAdaptor(PushNotificationAppDelegate.self) private var pushDelegate
    @StateObject private var syncConsumer = SyncConsumer.shared
    @StateObject private var localCache = LocalCache.shared
    @Environment(\.scenePhase) private var scenePhase

    public init() {}

    public var body: some Scene {
        WindowGroup {
            TabView {
                NavigationStack {
                    ReadingFeedView()
                }
                .tabItem {
                    Label("Read", systemImage: "newspaper")
                }

                NavigationStack {
                    TabListView()
                        .navigationTitle("Tabs")
                }
                .tabItem {
                    Label("Tabs", systemImage: "macwindow.on.rectangle")
                }

                NavigationStack {
                    RandomLinksView()
                }
                .tabItem {
                    Label("Random", systemImage: "shuffle")
                }

                NavigationStack {
                    MoreView()
                }
                .tabItem {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }

            .onAppear {
                syncConsumer.start()
                RecentAddedProvider.shared.drainPendingShares()
                RecentAddedProvider.shared.refresh()
                EmergingContentProvider.shared.refresh()
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

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

