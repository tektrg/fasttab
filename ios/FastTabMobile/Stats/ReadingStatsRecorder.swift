import Foundation
import NaturalLanguage
import OSLog
import IndieMetrics

/// Metric names and label keys of the reading log. The only place these strings are spelled.
enum ReadingMetric {
    /// Words read for the first time (article words × newly covered share).
    static let words = "read.words"
    /// Article scrolled past `ReadingProgressLedger.finishedThreshold`, once per article.
    static let finished = "read.finished"
    /// One new highlight. Removing a highlight later does not subtract.
    static let highlight = "read.highlight"

    static let hostLabel = "host"
    static let titleLabel = "title"
}

/// Turns reader activity into `MetricEvent`s in an append-only log for the More tab's charts.
///
/// Every event's `subject` is the article's `readerCanonicalKey`, and carries its host (and
/// title) as labels so topics can be resolved at chart time (`ReadingTopicResolver`).
/// Only read-later content counts: tools, apps and pages the on-device model called a tool are
/// skipped (see `isTrackableRead`).
@MainActor
final class ReadingStatsRecorder {
    static let shared = ReadingStatsRecorder(
        log: FileMetricEventLog(fileURL: AppGroupContainer.fileURL(forFileNamed: logFileName)),
        defaults: .standard
    )

    static let logFileName = "reading_metrics.jsonl"
    /// Events older than this are pruned from the log.
    static let retention: TimeInterval = 2 * 365 * 24 * 3600
    /// Hard cap on stored events, whatever their age (a few MB of JSON lines).
    static let maxStoredEvents = 50_000
    private static let ledgerDefaultsKey = "FastTabMobile.readingStatsLedgerV1"

    let log: any MetricEventStoring
    private let defaults: UserDefaults
    private let isTrackable: @MainActor (URL) -> Bool
    private let now: () -> Date
    private var ledger: ReadingProgressLedger
    /// Writes run one after another so the log keeps event order.
    private var lastWrite: Task<Void, Never>?
    private let logger = Logger(subsystem: "app.theindie.FastTabMobile", category: "ReadingStats")

    init(
        log: any MetricEventStoring,
        defaults: UserDefaults,
        isTrackable: @escaping @MainActor (URL) -> Bool = ReadingStatsRecorder.isTrackableRead,
        now: @escaping () -> Date = Date.init
    ) {
        self.log = log
        self.defaults = defaults
        self.isTrackable = isTrackable
        self.now = now
        self.ledger = defaults.data(forKey: Self.ledgerDefaultsKey)
            .flatMap { try? JSONDecoder().decode(ReadingProgressLedger.self, from: $0) }
            ?? ReadingProgressLedger()
    }

    /// Read-later content (not a tool, app, search or sign-in page) that the on-device model has
    /// not called a tool. "Not classified yet" counts as a read.
    static func isTrackableRead(_ url: URL) -> Bool {
        TabBookmarkEligibility.isReadLaterContent(urlString: url.absoluteString)
            && EmergingLinkClassifier.shared.cachedIsRead(url: url) != false
    }

    // MARK: - Recording

    /// Whether activity on `url` counts at all. Check before doing work to feed the recorder.
    func isTracked(_ url: URL) -> Bool { isTrackable(url) }

    /// Call when an article opens, with the progress saved before this session.
    func beginReading(url: URL, savedProgress: Double) {
        guard isTrackable(url) else { return }
        ledger.seedIfUnknown(articleKey: url.readerCanonicalKey, progress: savedProgress, now: now())
        persistLedger()
    }

    /// Call as the reader scrolls (debounced) and with `isFlush` when the reader closes.
    func recordProgress(url: URL, title: String, progress: Double, wordCount: Int, isFlush: Bool) {
        guard isTrackable(url) else { return }
        let outcome = ledger.advance(articleKey: url.readerCanonicalKey, to: progress, isFlush: isFlush, now: now())
        guard outcome != .nothing else { return }

        var events: [MetricEvent] = []
        let wordsRead = (Double(wordCount) * outcome.newlyReadFraction).rounded()
        if wordsRead > 0 {
            events.append(event(ReadingMetric.words, url: url, title: title, value: wordsRead))
        }
        if outcome.didFinish {
            events.append(event(ReadingMetric.finished, url: url, title: title, value: 1))
        }
        // The high water is saved only after its events land, so a kill or a failed write
        // leaves the ground uncounted and the next session credits it again.
        let eventsToWrite = events
        let ledgerData = try? JSONEncoder().encode(ledger)
        enqueueWrite({ log in try await log.append(eventsToWrite) }, onSuccess: { [weak self] in
            self?.saveLedger(ledgerData)
        })
    }

    func recordHighlight(url: URL, title: String) {
        guard isTrackable(url) else { return }
        append([event(ReadingMetric.highlight, url: url, title: title, value: 1)])
    }

    /// Drops events past `retention`. Cheap enough to run once per launch.
    func pruneExpiredEvents() {
        let cutoff = now().addingTimeInterval(-Self.retention)
        enqueueWrite { log in try await log.prune(olderThan: cutoff, maxEvents: Self.maxStoredEvents) }
    }

    /// Resolves once every write queued so far has landed. For tests and chart refreshes.
    func waitForPendingWrites() async {
        await lastWrite?.value
    }

    // MARK: - Helpers

    private func event(_ metric: String, url: URL, title: String, value: Double) -> MetricEvent {
        var labels: [String: String] = [:]
        if let host = Self.displayHost(of: url) { labels[ReadingMetric.hostLabel] = host }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty { labels[ReadingMetric.titleLabel] = trimmedTitle }
        return MetricEvent(timestamp: now(), subject: url.readerCanonicalKey, metric: metric, value: value, labels: labels)
    }

    private func append(_ events: [MetricEvent]) {
        guard !events.isEmpty else { return }
        enqueueWrite { log in try await log.append(events) }
    }

    /// `onSuccess` runs on the main actor once `write` has landed.
    private func enqueueWrite(
        _ write: @escaping @Sendable (any MetricEventStoring) async throws -> Void,
        onSuccess: @escaping @MainActor () -> Void = {}
    ) {
        let previous = lastWrite
        let log = log
        let logger = logger
        lastWrite = Task { @MainActor in
            await previous?.value
            do {
                try await write(log)
                onSuccess()
            } catch {
                logger.error("Reading stats write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Queued behind pending writes, so a seed never saves ground whose events are still in flight.
    private func persistLedger() {
        let data = try? JSONEncoder().encode(ledger)
        enqueueWrite({ _ in }, onSuccess: { [weak self] in self?.saveLedger(data) })
    }

    private func saveLedger(_ data: Data?) {
        guard let data else { return }
        defaults.set(data, forKey: Self.ledgerDefaultsKey)
    }

    /// Lowercased host without `www.`, the label topics fall back to.
    static func displayHost(of url: URL) -> String? {
        guard let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

// MARK: - Word count

extension ReaderArticle {
    /// Words in the article body, HTML stripped. Word-boundary aware for languages written
    /// without spaces. Compute once per article: it walks the whole text.
    var readingWordCount: Int {
        let plainText = content
            .replacingOccurrences(of: "<(script|style)[^>]*>[\\s\\S]*?</\\1>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&#?[a-zA-Z0-9]+;", with: " ", options: .regularExpression)
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = plainText
        var count = 0
        tokenizer.enumerateTokens(in: plainText.startIndex..<plainText.endIndex) { _, _ in
            count += 1
            return true
        }
        return count
    }
}
