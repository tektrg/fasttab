import Foundation
import Combine
import FastTabSync
import IndieMetrics
import OSLog

/// Feeds the More tab's Reading and Tabs charts. Reading comes from this phone's reading log,
/// Tabs from the Macs' synced digests in `LocalCache`. Recomputes when either changes, or when
/// a background topic inference lands.
@MainActor
final class StatsViewModel: ObservableObject {
    @Published private(set) var reading: ReadingStatsSummary = .empty
    @Published private(set) var tabs: TabStatsSummary = .empty
    /// False until the reading log has been read once, so the card never flashes its empty state.
    @Published private(set) var hasLoadedReading = false

    private let recorder: ReadingStatsRecorder
    private let topicResolver: ReadingTopicResolver
    private let localCache: LocalCache
    private let calendar: Calendar
    private var readingEvents: [MetricEvent] = []
    private var bookmarkBlobs: [SyncedBookmarkBlob]
    private var subscriptions = Set<AnyCancellable>()
    private let logger = Logger(subsystem: "app.theindie.FastTabMobile", category: "StatsViewModel")

    convenience init() {
        self.init(recorder: .shared, topicResolver: .shared, localCache: .shared, calendar: .current)
    }

    init(
        recorder: ReadingStatsRecorder,
        topicResolver: ReadingTopicResolver,
        localCache: LocalCache,
        calendar: Calendar
    ) {
        self.recorder = recorder
        self.topicResolver = topicResolver
        self.localCache = localCache
        self.calendar = calendar
        self.bookmarkBlobs = localCache.state.bookmarkBlobs

        // `@Published` emits before the new value is stored: always use the emitted value,
        // never re-read `localCache.state` inside these sinks.
        localCache.$state
            .map(\.tabStats)
            .removeDuplicates()
            .sink { [weak self] tabStats in self?.recomputeTabs(from: tabStats) }
            .store(in: &subscriptions)
        // Topics move when bookmarks sync in (debounced first: a sync burst changes the cache
        // hundreds of times, and comparing every bookmark each time is not free)...
        localCache.$state
            .map(\.bookmarkBlobs)
            .dropFirst()
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] blobs in
                self?.bookmarkBlobs = blobs
                self?.recomputeReading()
            }
            .store(in: &subscriptions)
        // ...and when a background inference lands (read back after the debounce, when stored).
        topicResolver.$inferredFolderByArticle
            .dropFirst()
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.recomputeReading() }
            .store(in: &subscriptions)
    }

    /// Reloads the reading log from disk and re-dates the tab charts (a More tab left open past
    /// midnight would still end on yesterday). Call when the More tab appears.
    func reloadReadingLog() async {
        recomputeTabs(from: localCache.state.tabStats)
        await recorder.waitForPendingWrites()
        do {
            // Only the charted weeks: topics are resolved (and maybe inferred) per article.
            let windowStart = ReadingStatsSummary.windowStart(now: Date(), calendar: calendar)
            readingEvents = try await recorder.log.loadEvents().filter { $0.timestamp >= windowStart }
        } catch {
            logger.error("Reading log unreadable: \(error.localizedDescription, privacy: .public)")
            readingEvents = []
        }
        #if DEBUG
        if StatsDemoFixture.isEnabled { readingEvents = StatsDemoFixture.readingEvents(now: Date()) }
        #endif
        recomputeReading()
        hasLoadedReading = true
    }

    private func recomputeReading() {
        #if DEBUG
        if StatsDemoFixture.isEnabled {
            reading = ReadingStatsSummary.make(
                from: readingEvents, topicsByArticle: StatsDemoFixture.topicsByArticle, now: Date(), calendar: calendar
            )
            return
        }
        #endif
        let topics = topicResolver.topicsByArticle(
            for: readingEvents.filter { $0.metric == ReadingMetric.words },
            bookmarkBlobs: bookmarkBlobs
        )
        reading = ReadingStatsSummary.make(from: readingEvents, topicsByArticle: topics, now: Date(), calendar: calendar)
    }

    private func recomputeTabs(from tabStats: [String: SyncedTabStats]) {
        var digests = Array(tabStats.values)
        #if DEBUG
        if StatsDemoFixture.isEnabled { digests = StatsDemoFixture.tabDigests(now: Date(), calendar: calendar) }
        #endif
        tabs = TabStatsSummary.make(from: digests, now: Date(), calendar: calendar)
    }
}
