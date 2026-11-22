import Foundation
@testable import AgentBar

/// A status source for the `/compact` tests. Compact starts stay pending until the test replies;
/// reads answer from a script (by row: `rowRead`; by id: `idReads` in order, then `idReadAfter`).
/// Plain messages are recorded and answered `.sent` at once; the pane always shows an idle prompt.
final class CompactFakeSource: AgentStatusSource, @unchecked Sendable {
    struct Start: Equatable {
        let rowId: String
        let actor: String
        let instructions: String?
        let followUp: String?
    }

    let updates = AsyncStream<StatusSnapshot> { _ in }
    private let lock = NSLock()
    private var recordedStarts: [Start] = []
    private var pendingStarts: [CheckedContinuation<CompactStartOutcome, Never>] = []
    private var recordedMessages: [String] = []
    private var recordedRowReads: [String] = []
    private var recordedIdReads: [String] = []
    private var scriptedRowRead: CompactJobRead = .none
    private var scriptedIdReads: [CompactJobRead] = []
    private var scriptedIdReadAfter: CompactJobRead = .none

    var starts: [Start] { lock.withLock { recordedStarts } }
    var pendingStartCount: Int { lock.withLock { pendingStarts.count } }
    var messages: [String] { lock.withLock { recordedMessages } }
    var rowReads: [String] { lock.withLock { recordedRowReads } }
    var idReads: [String] { lock.withLock { recordedIdReads } }

    var rowRead: CompactJobRead {
        get { lock.withLock { scriptedRowRead } }
        set { lock.withLock { scriptedRowRead = newValue } }
    }

    /// Replies to the next polls, in order; once used up, every poll gets `idReadAfter`.
    func script(idReads: [CompactJobRead], then after: CompactJobRead = .none) {
        lock.withLock {
            scriptedIdReads = idReads
            scriptedIdReadAfter = after
        }
    }

    func focus(paneId: String) async -> FocusResult { .success }
    func paneScreen(paneId: String) async -> PaneScreenResult {
        .screen(lines: ["⏺ Done.", "", "❯ "], readAt: Date(timeIntervalSince1970: 0))
    }
    func answer(paneId: String, choice: AnswerChoice, question: QuestionIdentity) async -> AnswerResult { .failed("unused") }
    func perform(_ kind: SessionActionKind, rowId: String, confirmed: Bool) async -> SessionActionOutcome { .failed("unused") }

    private var scriptedMessageOutcome: MessageSendOutcome = .sent(queued: false)
    /// The reply every plain message gets (default `.sent`).
    var messageOutcome: MessageSendOutcome {
        get { lock.withLock { scriptedMessageOutcome } }
        set { lock.withLock { scriptedMessageOutcome = newValue } }
    }

    func sendMessage(rowId: String, text: String, confirmed: Bool) async -> MessageSendOutcome {
        lock.withLock {
            recordedMessages.append(text)
            return scriptedMessageOutcome
        }
    }

    func startCompact(rowId: String, actor: String, instructions: String?, followUp: String?) async -> CompactStartOutcome {
        await withCheckedContinuation { continuation in
            lock.withLock {
                recordedStarts.append(Start(rowId: rowId, actor: actor, instructions: instructions, followUp: followUp))
                pendingStarts.append(continuation)
            }
        }
    }

    func replyStart(_ outcome: CompactStartOutcome) {
        let continuation = lock.withLock { pendingStarts.isEmpty ? nil : pendingStarts.removeFirst() }
        continuation?.resume(returning: outcome)
    }

    func compactJob(rowId: String) async -> CompactJobRead {
        lock.withLock {
            recordedRowReads.append(rowId)
            return scriptedRowRead
        }
    }

    func compactJob(id: String) async -> CompactJobRead {
        lock.withLock {
            recordedIdReads.append(id)
            return scriptedIdReads.isEmpty ? scriptedIdReadAfter : scriptedIdReads.removeFirst()
        }
    }
}

/// Stands in for the poll interval: every `sleep` waits until the test calls `tick()`, so a test
/// decides exactly when each poll happens.
final class ManualTicker: @unchecked Sendable {
    private let lock = NSLock()
    private var sleepers: [CheckedContinuation<Void, Never>] = []
    private var slept = 0

    var waiting: Int { lock.withLock { sleepers.count } }
    /// Sleeps started so far (one per poll).
    var sleepCount: Int { lock.withLock { slept } }

    var sleep: @Sendable (Duration) async -> Void {
        { [self] _ in
            await withCheckedContinuation { continuation in
                lock.withLock {
                    slept += 1
                    sleepers.append(continuation)
                }
            }
        }
    }

    func tick() {
        let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            let all = sleepers
            sleepers = []
            return all
        }
        ready.forEach { $0.resume() }
    }
}

enum CompactFixtures {
    static func job(
        _ state: CompactJob.State, id: String = "job-1", rowId: String = "row-a", originalModel: String? = "Opus 5.5",
        switchSkipped: Bool = false, skipReason: String? = nil, modelRestored: Bool? = nil, followUpSent: Bool? = nil,
        error: String? = nil, createdAt: Double = 0, inPicker: Bool = false
    ) -> CompactJob {
        CompactJob(id: id, rowId: rowId, state: state, originalModel: originalModel, switchSkipped: switchSkipped,
                   skipReason: skipReason, modelRestored: modelRestored, followUpSent: followUpSent, error: error,
                   createdAt: createdAt, updatedAt: createdAt, inPicker: inPicker)
    }
}
