import Foundation
import Combine
import FastTabSync
import IndieMetrics

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
    private var subscriptions = Set<AnyCancellable>()

    init(
        recorder: ReadingStatsRecorder = .shared,
        topicResolver: ReadingTopicResolver = .shared,
        localCache: LocalCache = .shared,
        calendar: Calendar = .current
    ) {
        self.recorder = recorder
        self.topicResolver = topicResolver
        self.localCache = localCache
        self.calendar = calendar

        localCache.$state
            .map(\.tabStats)
            .removeDuplicates()
            .sink { [weak self] _ in self?.recomputeTabs() }
            .store(in: &subscriptions)
        topicResolver.$inferredFolderByArticle
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.recomputeReading() }
            .store(in: &subscriptions)
    }

    /// Reloads the reading log from disk. Call when the More tab appears.
    func reloadReadingLog() async {
        await recorder.waitForPendingWrites()
        readingEvents = (try? await recorder.log.loadEvents()) ?? []
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
            bookmarkBlobs: localCache.state.bookmarkBlobs
        )
        reading = ReadingStatsSummary.make(from: readingEvents, topicsByArticle: topics, now: Date(), calendar: calendar)
    }

    private func recomputeTabs() {
        var digests = Array(localCache.state.tabStats.values)
        #if DEBUG
        if StatsDemoFixture.isEnabled { digests = StatsDemoFixture.tabDigests(now: Date(), calendar: calendar) }
        #endif
        tabs = TabStatsSummary.make(from: digests, now: Date(), calendar: calendar)
    }
}
