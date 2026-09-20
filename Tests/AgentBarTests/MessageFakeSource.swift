import Foundation
@testable import AgentBar

/// A status source for the message tests: reads of the pane return what the test set, and message
/// sends stay pending until the test replies. It records every send, and refuses to be posted to
/// for anything else (a test failure to notice).
final class MessageFakeSource: AgentStatusSource, @unchecked Sendable {
    struct Sent: Equatable {
        let rowId: String
        let text: String
        let confirmed: Bool
    }

    let updates = AsyncStream<StatusSnapshot> { _ in }
    private let lock = NSLock()
    private var sentRequests: [Sent] = []
    private var pending: [CheckedContinuation<MessageSendOutcome, Never>] = []
    private var screenReply: PaneScreenResult = .screen(lines: ["⏺ Done.", "", "❯ "], readAt: Date(timeIntervalSince1970: 0))
    private var reads = 0

    var sent: [Sent] { lock.withLock { sentRequests } }
    var pendingCount: Int { lock.withLock { pending.count } }
    var screenReads: Int { lock.withLock { reads } }

    var screen: PaneScreenResult {
        get { lock.withLock { screenReply } }
        set { lock.withLock { screenReply = newValue } }
    }

    func focus(paneId: String) async -> FocusResult { .success }

    func paneScreen(paneId: String) async -> PaneScreenResult {
        lock.withLock { reads += 1 }
        return screen
    }

    func answer(paneId: String, choice: AnswerChoice, question: QuestionIdentity) async -> AnswerResult { .failed("unused") }
    func perform(_ kind: SessionActionKind, rowId: String, confirmed: Bool) async -> SessionActionOutcome { .failed("unused") }

    func sendMessage(rowId: String, text: String, confirmed: Bool) async -> MessageSendOutcome {
        await withCheckedContinuation { continuation in
            lock.withLock {
                sentRequests.append(Sent(rowId: rowId, text: text, confirmed: confirmed))
                pending.append(continuation)
            }
        }
    }

    func reply(_ outcome: MessageSendOutcome) {
        let continuation = lock.withLock { pending.isEmpty ? nil : pending.removeFirst() }
        continuation?.resume(returning: outcome)
    }

    func waitForRequests(_ count: Int) async {
        await waitUntil { self.pendingCount >= count }
    }
}
