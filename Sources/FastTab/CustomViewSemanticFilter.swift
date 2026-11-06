import Foundation
import OSLog

/// Where a run of the AI filter stands, for the page.
struct CustomViewSemanticProgress: Equatable {
    /// Matching items so far, in input order (so grouping/sort never jumps).
    var included: [CustomViewItem]
    /// Candidates with a verdict (match, no match, or couldn't check).
    var checked: Int
    /// Candidates the AI looks at (≤ `candidateCap`).
    var total: Int
    /// Candidates the model failed on: excluded, retried next run.
    var unknown: Int
    /// More items matched the structured filters than the cap.
    var isCapped: Bool
    var isFinished: Bool
    /// Apple Intelligence went away mid-run; the rest were not checked.
    var becameUnavailable: Bool
}

/// The AI ("semantic") stage of a custom view: which of the structurally
/// matching items fit the view's natural-language prompt.
///
/// - **Cap**: only the `candidateCap` first items (the input is sorted newest
///   first) are checked; the rest are excluded.
/// - **Batches** of `batchSize` numbered items per model request
///   (`CustomViewSemanticPrompt`).
/// - **Serial, app-wide**: one request at a time (on-device model measured
///   slower and rate-limited with concurrent requests — transcript clean-up).
/// - **Cancellation**: only the active prompt's batches start
///   (`setActive(prompt:)`, driven by the page model). Queued batches of a
///   view that is no longer shown, or whose prompt changed, are skipped; a
///   batch already talking to the model finishes and is cached.
/// - **Cache** (`CustomViewSemanticCache`): verdicts persist per prompt +
///   page + title; a run only asks about items not cached yet, and reuses
///   batches already queued by an earlier run of the same prompt.
/// - **Errors**: a failed batch is retried once as two smaller halves; items
///   that still fail are "unknown" (excluded, not cached).
@MainActor
final class CustomViewSemanticFilter {
    static let shared = CustomViewSemanticFilter(
        classifier: FoundationModelsSemanticClassifier(),
        cache: .shared
    )

    nonisolated static let defaultCandidateCap = 300
    nonisolated static let defaultBatchSize = 15

    let classifier: any CustomViewSemanticClassifying
    let cache: CustomViewSemanticCache
    let candidateCap: Int
    let batchSize: Int
    private let retryDelayNanoseconds: UInt64

    /// Hash of the prompt whose queued batches may start; nil = none.
    private(set) var activePromptHash: String?

    private enum Verdict: Equatable { case match, noMatch, unknown }

    private struct BatchOutcome {
        var verdicts: [String: Verdict] = [:]
        /// Not run: its prompt was no longer active when its turn came.
        var skipped = false
        var becameUnavailable = false
    }

    private typealias BatchItem = (key: String, candidate: CustomViewSemanticCandidate)
    private typealias QueuedBatch = (id: Int, task: Task<BatchOutcome, Never>)

    private var lastQueued: Task<Void, Never>?
    private var nextBatchID = 0
    private var batchTasks: [Int: Task<BatchOutcome, Never>] = [:]
    private var inFlightBatchByKey: [String: Int] = [:]
    private let logger = Logger(subsystem: "com.trungluong.FastTab", category: "CustomViewAI")

    init(
        classifier: any CustomViewSemanticClassifying,
        cache: CustomViewSemanticCache,
        candidateCap: Int = CustomViewSemanticFilter.defaultCandidateCap,
        batchSize: Int = CustomViewSemanticFilter.defaultBatchSize,
        retryDelayNanoseconds: UInt64 = 500_000_000
    ) {
        self.classifier = classifier
        self.cache = cache
        self.candidateCap = max(1, candidateCap)
        self.batchSize = max(1, batchSize)
        self.retryDelayNanoseconds = retryDelayNanoseconds
    }

    var isAvailable: Bool { classifier.isAvailable }

    /// The prompt of the view now on screen, or nil when no AI-filtered view
    /// is showing. Queued work for any other prompt is dropped.
    func setActive(prompt: String?) {
        activePromptHash = prompt.map(CustomViewSemanticCache.promptHash)
    }

    /// Keeps only the cache entries of these prompts (the views' current ones).
    func pruneCache(keepingPrompts prompts: [String]) {
        cache.prune(keepingPromptHashes: Set(prompts.map(CustomViewSemanticCache.promptHash)))
    }

    /// Classifies `items` (sorted, newest first) against `prompt`, calling
    /// `update` first with what the cache already knows, then after every
    /// batch, and a last time with `isFinished`. Returns early (without a
    /// finished update) when the calling task is cancelled.
    func run(prompt: String, items: [CustomViewItem], update: (CustomViewSemanticProgress) -> Void) async {
        let promptHash = CustomViewSemanticCache.promptHash(prompt)
        let candidates = Array(items.prefix(candidateCap))
        let isCapped = items.count > candidateCap
        let keys = candidates.map { CustomViewSemanticCache.key(promptHash: promptHash, item: $0) }

        var known: [String: Bool] = [:]
        var unknown = Set<String>()
        var becameUnavailable = false
        for key in keys where known[key] == nil {
            if let verdict = cache.verdict(forKey: key) { known[key] = verdict }
        }

        func emit(finished: Bool) {
            var included: [CustomViewItem] = []
            var checked = 0
            var unknownCount = 0
            for (index, key) in keys.enumerated() {
                if let match = known[key] {
                    checked += 1
                    if match { included.append(candidates[index]) }
                } else if unknown.contains(key) {
                    checked += 1
                    unknownCount += 1
                }
            }
            update(CustomViewSemanticProgress(
                included: included,
                checked: checked,
                total: candidates.count,
                unknown: unknownCount,
                isCapped: isCapped,
                isFinished: finished,
                becameUnavailable: becameUnavailable
            ))
        }

        // Pending: one entry per distinct uncached key, in display order.
        var seen = Set<String>()
        var pending: [BatchItem] = []
        for (index, key) in keys.enumerated() where known[key] == nil && seen.insert(key).inserted {
            pending.append((key, CustomViewSemanticCandidate(item: candidates[index])))
        }
        emit(finished: pending.isEmpty)
        guard !pending.isEmpty else { return }

        // Task references are held here: a batch may finish (and leave
        // `batchTasks`) while this run is still awaiting an earlier one.
        var batches = schedule(pending, prompt: prompt, promptHash: promptHash)

        var cursor = 0
        while cursor < batches.count {
            let task = batches[cursor].task
            cursor += 1
            let outcome = await task.value
            if Task.isCancelled { return }
            if outcome.skipped {
                // Queued by an earlier run and dropped while this prompt was
                // briefly inactive: ask again if it's ours now.
                guard activePromptHash == promptHash else { return }
                let retry = pending.filter { known[$0.key] == nil && !unknown.contains($0.key) && outcome.verdicts[$0.key] != nil }
                for batch in schedule(retry, prompt: prompt, promptHash: promptHash)
                where !batches.contains(where: { $0.id == batch.id }) {
                    batches.append(batch)
                }
                continue
            }
            for (key, verdict) in outcome.verdicts {
                switch verdict {
                case .match: known[key] = true
                case .noMatch: known[key] = false
                case .unknown: unknown.insert(key)
                }
            }
            if outcome.becameUnavailable {
                becameUnavailable = true
                for item in pending where known[item.key] == nil { unknown.insert(item.key) }
                emit(finished: true)
                return
            }
            emit(finished: false)
        }
        // Anything a reused batch didn't cover (shouldn't happen) is unknown.
        for item in pending where known[item.key] == nil { unknown.insert(item.key) }
        emit(finished: true)
    }

    // MARK: Queue

    /// Batch ids covering `items`: batches already queued for them (by an
    /// earlier run of the same prompt) are reused; the rest are queued.
    private func schedule(_ items: [BatchItem], prompt: String, promptHash: String) -> [QueuedBatch] {
        var batches: [QueuedBatch] = []
        var fresh: [BatchItem] = []
        for item in items {
            if let id = inFlightBatchByKey[item.key], let task = batchTasks[id] {
                if !batches.contains(where: { $0.id == id }) { batches.append((id, task)) }
            } else {
                fresh.append(item)
            }
        }
        return batches + enqueue(fresh, prompt: prompt, promptHash: promptHash)
    }

    private func enqueue(_ items: [BatchItem], prompt: String, promptHash: String) -> [QueuedBatch] {
        guard !items.isEmpty else { return [] }
        var queued: [QueuedBatch] = []
        var start = 0
        while start < items.count {
            let batch = Array(items[start..<min(start + batchSize, items.count)])
            start += batchSize
            nextBatchID += 1
            let id = nextBatchID
            let previous = lastQueued
            let task = Task { [weak self] () -> BatchOutcome in
                await previous?.value
                guard let self else { return BatchOutcome(skipped: true) }
                let outcome = await self.perform(batch, prompt: prompt, promptHash: promptHash)
                self.finish(batchID: id, keys: batch.map(\.key))
                return outcome
            }
            lastQueued = Task { _ = await task.value }
            batchTasks[id] = task
            for item in batch { inFlightBatchByKey[item.key] = id }
            queued.append((id, task))
        }
        return queued
    }

    private func finish(batchID: Int, keys: [String]) {
        batchTasks[batchID] = nil
        for key in keys where inFlightBatchByKey[key] == batchID {
            inFlightBatchByKey[key] = nil
        }
    }

    /// Runs one batch (its turn in the serial queue has come).
    private func perform(_ batch: [BatchItem], prompt: String, promptHash: String) async -> BatchOutcome {
        guard activePromptHash == promptHash else {
            var skipped = BatchOutcome(skipped: true)
            for item in batch { skipped.verdicts[item.key] = .unknown }
            return skipped
        }
        var outcome = BatchOutcome()
        do {
            let matches = try await classifier.matchingIndices(prompt: prompt, batch: batch.map(\.candidate))
            record(matches, of: batch, into: &outcome)
        } catch CustomViewSemanticError.unavailable {
            markUnknown(batch, in: &outcome, unavailable: true)
        } catch {
            logger.warning("AI filter batch of \(batch.count) failed, retrying smaller: \(String(describing: error), privacy: .public)")
            // Retry once, as two halves (a single item is retried as is).
            // A short pause first helps when the model is rate limiting.
            try? await Task.sleep(nanoseconds: retryDelayNanoseconds)
            let half = max(1, (batch.count + 1) / 2)
            let parts = batch.count > 1 ? [Array(batch[..<half]), Array(batch[half...])] : [batch]
            for part in parts {
                guard !outcome.becameUnavailable, activePromptHash == promptHash else {
                    markUnknown(part, in: &outcome, unavailable: false)
                    continue
                }
                do {
                    let matches = try await classifier.matchingIndices(prompt: prompt, batch: part.map(\.candidate))
                    record(matches, of: part, into: &outcome)
                } catch CustomViewSemanticError.unavailable {
                    markUnknown(part, in: &outcome, unavailable: true)
                } catch {
                    logger.warning("AI filter retry of \(part.count) failed; leaving unchecked: \(String(describing: error), privacy: .public)")
                    markUnknown(part, in: &outcome, unavailable: false)
                }
            }
        }
        var toCache: [String: Bool] = [:]
        for (key, verdict) in outcome.verdicts {
            switch verdict {
            case .match: toCache[key] = true
            case .noMatch: toCache[key] = false
            case .unknown: break
            }
        }
        cache.store(toCache)
        return outcome
    }

    private func record(_ matches: Set<Int>, of batch: [BatchItem], into outcome: inout BatchOutcome) {
        for (index, item) in batch.enumerated() {
            outcome.verdicts[item.key] = matches.contains(index) ? .match : .noMatch
        }
    }

    private func markUnknown(_ batch: [BatchItem], in outcome: inout BatchOutcome, unavailable: Bool) {
        for item in batch { outcome.verdicts[item.key] = .unknown }
        if unavailable { outcome.becameUnavailable = true }
    }
}
