import SwiftUI
import TipKit
import FastTabSync
import IndieAccount

public struct MoreView: View {
    @ObservedObject private var localCache = LocalCache.shared
    @ObservedObject private var syncConsumer = SyncConsumer.shared
    @ObservedObject private var appMode = AppModeModel.shared
    @StateObject private var statsViewModel = StatsViewModel()
    @Environment(AccountSession.self) private var accountSession
    private let intelligenceTip = IntelligenceTip()
    @AppStorage(TranscriptCleanupPreference.defaultsKey) private var transcriptCleanupEnabled = false
    @AppStorage(ReadingGoal.defaultsKey) private var dailyWordGoal = ReadingGoal.defaultDailyWords

    public init() {}

    private var queueCount: Int {
        localCache.state.sentCommands.filter { cmd in
            cmd.kind == .openOnMac && cmd.status == .pending
        }.count
    }

    private var bookmarksCount: Int {
        localCache.state.bookmarkBlobs.reduce(0) { $0 + $1.bookmarks.count }
    }

    private var devicesCount: Int {
        localCache.state.devices.count
    }

    /// On: Mac companion (Tabs tab, Send to Mac). Off: reader only. Turning it on opens Connect your Mac.
    private var usesMacBinding: Binding<Bool> {
        Binding(
            get: { !appMode.isStandalone },
            set: { usesMac in
                appMode.set(usesMac ? .mac : .standalone)
                if usesMac && localCache.state.connectedMac == nil {
                    OnboardingPresenter.shared.present(.singleStep(.connectMac))
                }
            }
        )
    }

    public var body: some View {
        List {
            // Level-1 stats: visible the moment the tab opens, no tap-through.
            Section {
                ReadingStatsCard(summary: statsViewModel.reading, isLoaded: statsViewModel.hasLoadedReading)
            }
            .listRowInsets(EdgeInsets())
            .dsListRow()

            // Mac-only rows (Tab stats, Desk Queue, synced bookmarks/history, Macs) are hidden on reader-only phones.
            if !appMode.isStandalone {
                Section {
                    TabStatsCard(summary: statsViewModel.tabs)
                }
                .listRowInsets(EdgeInsets())
                .dsListRow()
            }

            Section(footer: Text("Closes the Reading ring widget on your home screen.")) {
                Stepper(value: $dailyWordGoal, in: ReadingGoal.range, step: ReadingGoal.step) {
                    HStack {
                        Text("Daily reading goal")
                        Spacer()
                        Text("\(dailyWordGoal.formatted()) words")
                            .font(DS.Font.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .dsListRow()

            Section(footer: Text(appMode.isStandalone
                ? "Reader only: save links from the share sheet and read them here."
                : "Use with a Mac: see your Mac's tabs and send links to it.")) {
                Toggle(isOn: usesMacBinding) {
                    Label("Use with a Mac", systemImage: "macbook.and.iphone")
                }
            }
            .dsListRow()

            if !appMode.isStandalone {
                Section {
                    DataFreshnessBanner(
                        device: localCache.state.connectedMac,
                        lastSyncedAt: localCache.state.lastSyncedAt
                    )
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }

            if !appMode.isStandalone {
                Section("Utilities") {
                    NavigationLink {
                        DeskQueueView()
                            .navigationTitle("Desk Queue")
                    } label: {
                        MoreRowLabel(
                            systemImage: "paperplane.fill",
                            tint: DS.Tint.action,
                            title: "Desk Queue",
                            subtitle: "Links staged to open on your Mac"
                        ) {
                            if queueCount > 0 {
                                // Solid badge: pending sends are waiting on the Mac.
                                Text("\(queueCount)")
                                    .font(DS.Font.tag.monospacedDigit())
                                    .padding(.horizontal, DS.Space.sm)
                                    .padding(.vertical, 3)
                                    .foregroundColor(.white)
                                    .background(DS.Tint.action, in: Capsule())
                            }
                        }
                    }
                }
                .dsListRow()
            }

            Section(appMode.isStandalone ? "Highlights" : "Bookmarks & History") {
                if !appMode.isStandalone {
                    NavigationLink {
                        BookmarkTreeView(device: nil)
                            .navigationTitle("Bookmarks")
                    } label: {
                        MoreRowLabel(
                            systemImage: "bookmark.fill",
                            tint: DS.Tint.bookmark,
                            title: "Bookmarks",
                            subtitle: "All synced browser bookmarks & folders"
                        ) {
                            if bookmarksCount > 0 {
                                DSCountPill(bookmarksCount)
                            }
                        }
                    }

                    NavigationLink {
                        HistoryListView(device: nil)
                            .navigationTitle("History")
                    } label: {
                        MoreRowLabel(
                            systemImage: "clock.arrow.circlepath",
                            tint: .secondary,
                            title: "Synced History",
                            subtitle: "Recent browsing history from your Mac"
                        )
                    }
                }

                NavigationLink {
                    HighlightsListView()
                } label: {
                    MoreRowLabel(
                        systemImage: "highlighter",
                        tint: DS.Tint.warning,
                        title: "Highlights",
                        subtitle: "Text you've highlighted while reading"
                    )
                }
            }
            .dsListRow()

            Section("Account") {
                NavigationLink {
                    AccountSettingsView()
                } label: {
                    MoreRowLabel(
                        systemImage: "person.crop.circle",
                        tint: DS.Tint.action,
                        title: "theindie account",
                        subtitle: accountSession.moreRowSubtitle
                    )
                }
            }
            .dsListRow()

            if !appMode.isStandalone {
                Section("Devices") {
                    NavigationLink {
                        DeviceListView()
                            .navigationTitle("Devices")
                    } label: {
                        MoreRowLabel(
                            systemImage: "laptopcomputer",
                            tint: DS.Tint.action,
                            title: "Connected Macs",
                            subtitle: "\(devicesCount) device\(devicesCount == 1 ? "" : "s") synced"
                        )
                    }
                }
                .dsListRow()
            }

            Section(
                header: Text("Experimental"),
                footer: Text("Early features that may change or go away. Clean-up rewrites YouTube transcripts into readable text on this iPhone (needs Apple Intelligence). Also in the reader's ⋯ menu.")
            ) {
                TipView(IntelligenceTip(isStandalone: appMode.isStandalone))
                    .fastTabTipStyle()
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)

                NavigationLink {
                    IntelligenceView()
                        .navigationTitle("Intelligence")
                        .onAppear { intelligenceTip.invalidate(reason: .actionPerformed) }
                } label: {
                    MoreRowLabel(
                        systemImage: "sparkles",
                        tint: DS.Tint.emerging,
                        title: "Intelligence",
                        subtitle: appMode.isStandalone
                            ? "Topic clusters from your reading"
                            : "Topic clusters & bookmark suggestions"
                    )
                }

                Toggle(isOn: $transcriptCleanupEnabled) {
                    MoreRowLabel(
                        systemImage: "wand.and.sparkles",
                        tint: DS.Tint.emerging,
                        title: "Clean up YouTube transcripts",
                        subtitle: "On-device rewrite into readable text"
                    )
                }
            }
            .dsListRow()

            Section("Help") {
                Button {
                    OnboardingPresenter.shared.present(.fullGuide)
                } label: {
                    MoreRowLabel(
                        systemImage: "sparkles.rectangle.stack",
                        tint: DS.Tint.action,
                        title: "Setup Guide",
                        subtitle: "Connect your Mac, try Reader, set up sharing"
                    )
                }
                .foregroundStyle(.primary)
                #if DEBUG
                Button("Show Rating Popup (Debug)") {
                    RatingPromptCoordinator.shared.forceShow()
                }
                #endif
            }
            .dsListRow()

            Section {
                Button {
                    Task {
                        await syncConsumer.refreshNow()
                    }
                } label: {
                    HStack {
                        Spacer()
                        Label("Sync Now", systemImage: "arrow.clockwise")
                            .font(DS.Font.cardTitle)
                        Spacer()
                    }
                }
            }
            .dsListRow()
        }
        .listStyle(.insetGrouped)
        .dsListStyle()
        .navigationTitle("More")
        .task { await statsViewModel.reloadReadingLog() }
    }
}

/// Leading tinted icon, title + subtitle, optional trailing accessory — one More row.
private struct MoreRowLabel<Trailing: View>: View {
    let systemImage: String
    let tint: Color
    let title: String
    let subtitle: String
    let trailing: Trailing

    init(systemImage: String, tint: Color, title: String, subtitle: String, @ViewBuilder trailing: () -> Trailing) {
        self.systemImage = systemImage
        self.tint = tint
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: DS.Space.md) {
            Image(systemName: systemImage)
                .font(.system(size: DS.IconSize.row))
                .foregroundStyle(tint)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(title)
                    .font(DS.Font.body.weight(.medium))
                Text(subtitle)
                    .font(DS.Font.meta)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            trailing
        }
        .padding(.vertical, DS.Space.xs)
    }
}

private extension MoreRowLabel where Trailing == EmptyView {
    init(systemImage: String, tint: Color, title: String, subtitle: String) {
        self.init(systemImage: systemImage, tint: tint, title: title, subtitle: subtitle) { EmptyView() }
    }
}
