import Foundation

/// Starts and follows the `/compact` job of ONE message card's row. Holds the card's
/// `CompactProgress` (the single owner of that status) and drives it with dashboard calls:
/// a GET by row when the card opens (a job started earlier or from the web shows its progress),
/// a POST on a `/compact` send, then one GET by id every `pollInterval` until the job ends.
///
/// One poll loop at a time; `stop()` (card closed) ends it and drops every late reply. Closing is
/// safe: the job runs in the dashboard, the card only watches it.
@MainActor
final class CompactJobFollower {
    static let pollInterval: Duration = .milliseconds(1500)

    private(set) var progress: CompactProgress = .idle {
        didSet { if progress != oldValue { onChange() } }
    }

    /// Every progress change (the card redraws).
    var onChange: () -> Void = {}

    let rowId: String
    private let source: any AgentStatusSource
    private let pollInterval: Duration
    private let sleep: @Sendable (Duration) async -> Void
    private var pollLoop: Task<Void, Never>?
    private var stopped = false

    init(
        rowId: String,
        source: any AgentStatusSource,
        pollInterval: Duration = CompactJobFollower.pollInterval,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.rowId = rowId
        self.source = source
        self.pollInterval = pollInterval
        self.sleep = sleep
    }

    var isPolling: Bool { pollLoop != nil }

    /// The card opened: show this row's running (or recently finished) job, if any.
    func resume() {
        let source = source
        let rowId = rowId
        Task { [weak self] in
            let read = await source.compactJob(rowId: rowId)
            self?.handle(.resumed(read))
        }
    }

    /// A `/compact` send. False when one is already starting or running (single-flight) or the
    /// follower has stopped. `onReply` hears the dashboard's answer (the card clears its draft on `.started`).
    @discardableResult
    func start(_ draft: CompactDraft, onReply: @escaping @MainActor (CompactStartOutcome) -> Void = { _ in }) -> Bool {
        guard !stopped, progress.apply(.startPressed) else { return false }
        let source = source
        let rowId = rowId
        Task { [weak self] in
            let outcome = await source.startCompact(
                rowId: rowId, actor: DashboardEndpoint.sessionActionActor,
                instructions: draft.instructions, followUp: draft.followUp
            )
            guard let self, !self.stopped else { return }
            self.handle(.startReplied(outcome))
            onReply(outcome)
            // A start with no reply may still have made a job: look it up instead of posting again.
            if case .uncertain = outcome { self.resume() }
        }
        return true
    }

    /// The card closed (or its dashboard changed): no more reads, late replies are dropped.
    func stop() {
        stopped = true
        pollLoop?.cancel()
        pollLoop = nil
    }

    private func handle(_ event: CompactProgress.Event) {
        guard !stopped else { return }
        progress.apply(event)
        pollIfRunning()
    }

    /// Starts the one poll loop while a job runs; it ends itself once the job is terminal or lost.
    private func pollIfRunning() {
        guard pollLoop == nil, !stopped, progress.runningJobId != nil else { return }
        let source = source
        let interval = pollInterval
        let sleep = sleep
        pollLoop = Task { [weak self] in
            while let id = self?.progress.runningJobId, self?.stopped == false {
                await sleep(interval)
                if Task.isCancelled { return }
                let read = await source.compactJob(id: id)
                guard let self, !Task.isCancelled, !self.stopped else { return }
                self.progress.apply(.polled(read))
            }
            self?.pollLoop = nil
        }
    }
}
