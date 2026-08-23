import SwiftUI
import FastTabSync

@main
public struct FastTabMobileApp: App {
    @StateObject private var syncConsumer = SyncConsumer.shared
    @StateObject private var localCache = LocalCache.shared
    @Environment(\.scenePhase) private var scenePhase

    public init() {}

    public var body: some Scene {
        WindowGroup {
            TabView {
                NavigationStack {
                    TabListView()
                        .navigationTitle("Tabs")
                }
                .tabItem {
                    Label("Tabs", systemImage: "macwindow.on.rectangle")
                }

                NavigationStack {
                    DeskQueueView()
                        .navigationTitle("Desk Queue")
                }
                .tabItem {
                    Label("Desk Queue", systemImage: "paperplane")
                }

                NavigationStack {
                    BookmarkTreeView(device: nil)
                        .navigationTitle("Bookmarks")
                }
                .tabItem {
                    Label("Bookmarks", systemImage: "bookmark")
                }
            }
            .onAppear {
                syncConsumer.start()
            }
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .active:
                    // A full refresh, not just a fetch: coming back to the app
                    // is also the moment to re-try anything the outbox still
                    // holds from the last time the phone was offline.
                    Task { await syncConsumer.refreshNow() }
                    syncConsumer.startForegroundRefresh()
                case .background:
                    syncConsumer.stopForegroundRefresh()
                    localCache.flushPendingSave()
                default:
                    // Off screen (app switcher, Control Center, a call): stop
                    // polling. Nothing is being looked at, so a pull can only
                    // cost battery.
                    syncConsumer.stopForegroundRefresh()
                }
            }
        }
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

