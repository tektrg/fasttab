import Foundation

/// Gets the Answer / Review button onto a row as soon as the agent needs you, instead of when
/// the dashboard's screen sweep (up to ~15s behind the hook that said "needs you") has parsed
/// the question or permission box. When a row is in Needs you without a parsed blocker, it does
/// the same read-only pane read the pre-send read does (`GET /api/pane/screen`, ~2.5s), parses
/// the screen with the Swift readers, and hands what it found to `onLearned`.
///
/// Rules: one read per arrival (in-flight reads are never doubled); a row the dashboard itself
/// calls blocked (loading options, plain permission) may be read again after `retryDelays`, in
/// case its box had not been drawn yet, then it is left alone; a row the dashboard is silent
/// about is read once. A result is used only if the row is still in Needs you, on the same pane,
/// still without a parsed blocker: an agent that moved on meanwhile is ignored. Nothing here
/// ever writes to a pane.
@MainActor
final class BlockerProbe {
    /// Pauses before the 2nd, 3rd... read of a row the dashboard says is blocked.
    static let standardRetryDelays: [TimeInterval] = [2, 5]

    /// Where to read from; nil until the host has one.
    var statusSource: (any AgentStatusSource)?
    /// The row as the panel shows it now, nil when it is gone.
    var currentAgent: (String) -> AgentSnapshot? = { _ in nil }
    /// A parsed question or permission box for the agent (an `AgentBlocker.question` / `.permissionReview`).
    var onLearned: (_ agentID: String, _ blocker: AgentBlocker) -> Void = { _, _ in }

    private struct Watch {
        let paneId: String
        var reads = 0
        var isReading = false
        var retry: Task<Void, Never>?
    }

    /// Waits out a retry delay; tests inject one that returns at once instead of using the real clock.
    typealias Pause = @Sendable (TimeInterval) async -> Void
    static let realPause: Pause = { seconds in try? await Task.sleep(for: .seconds(seconds)) }

    private let retryDelays: [TimeInterval]
    private let pause: Pause
    private var watches: [String: Watch] = [:]

    init(retryDelays: [TimeInterval] = BlockerProbe.standardRetryDelays, pause: @escaping Pause = BlockerProbe.realPause) {
        self.retryDelays = retryDelays
        self.pause = pause
    }

    /// Every status update: starts a read for rows that just came to need the user, and stops
    /// watching rows that are parsed, gone or no longer waiting.
    func observe(_ agents: [AgentSnapshot]) {
        guard statusSource != nil else { return }
        var stillWatched: Set<String> = []
        for agent in agents where Self.wantsRead(agent) {
            guard let paneId = agent.paneId else { continue }
            stillWatched.insert(agent.id)
            if let watch = watches[agent.id], watch.paneId == paneId { continue }   // already read, reading or given up on
            watches[agent.id]?.retry?.cancel()
            watches[agent.id] = Watch(paneId: paneId)
            read(agentID: agent.id)
        }
        for id in watches.keys where !stillWatched.contains(id) {
            watches[id]?.retry?.cancel()
            watches[id] = nil
        }
    }

    func reset() {
        watches.values.forEach { $0.retry?.cancel() }
        watches = [:]
    }

    /// In Needs you, with a pane, and no parsed question or box yet.
    private static func wantsRead(_ agent: AgentSnapshot) -> Bool {
        guard agent.section == .needsYou, let paneId = agent.paneId, !paneId.isEmpty else { return false }
        switch agent.blocker {
        case nil, .questionLoading?, .permission?: return true
        case .question?, .permissionReview?, .questionNotAnswerable?: return false
        }
    }

    /// The dashboard has said "blocked" (options loading, plain permission): worth more than one read.
    private func maxReads(for agent: AgentSnapshot) -> Int {
        agent.blocker == nil ? 1 : 1 + retryDelays.count
    }

    private func read(agentID: String) {
        guard let statusSource, var watch = watches[agentID], !watch.isReading else { return }
        watch.isReading = true
        watch.reads += 1
        watches[agentID] = watch
        let paneId = watch.paneId
        Task { [weak self] in
            let result = await statusSource.paneScreen(paneId: paneId)
            self?.finishRead(result, agentID: agentID, paneId: paneId)
        }
    }

    private func finishRead(_ result: PaneScreenResult, agentID: String, paneId: String) {
        guard var watch = watches[agentID], watch.paneId == paneId else { return }
        watch.isReading = false
        watches[agentID] = watch
        // The agent may have moved on (answered in its terminal, gone, or the dashboard caught up) while we read.
        guard let agent = currentAgent(agentID), agent.paneId == paneId, Self.wantsRead(agent) else {
            watches[agentID] = nil
            return
        }
        if case .screen(let lines, _) = result, let blocker = Self.blocker(in: lines) {
            onLearned(agentID, blocker)
            return
        }
        guard watch.reads < maxReads(for: agent) else { return }
        let delay = retryDelays[watch.reads - 1]
        watch.retry = Task { [weak self, pause] in
            await pause(delay)
            guard !Task.isCancelled else { return }
            self?.read(agentID: agentID)
        }
        watches[agentID] = watch
    }

    /// The two boxes cannot both parse: a picker has a ballot-box title, a permission box does not.
    private static func blocker(in lines: [String]) -> AgentBlocker? {
        if let question = PaneQuestionReader.question(in: lines) { return .question(question) }
        if let prompt = PanePermissionReader.prompt(in: lines) { return .permissionReview(prompt) }
        return nil
    }
}
