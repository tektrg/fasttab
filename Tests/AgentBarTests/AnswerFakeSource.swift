import Foundation
@testable import AgentBar

/// A status source whose answers stay pending until the test replies, and that
/// records every answer request (what was sent, for which question).
final class AnswerFakeSource: AgentStatusSource, @unchecked Sendable {
    struct Sent: Equatable {
        let paneId: String
        let choice: AnswerChoice
        let question: QuestionIdentity
    }

    let updates = AsyncStream<StatusSnapshot> { _ in }
    private let lock = NSLock()
    private var sentRequests: [Sent] = []
    private var pending: [CheckedContinuation<AnswerResult, Never>] = []

    var sent: [Sent] { lock.withLock { sentRequests } }
    var pendingCount: Int { lock.withLock { pending.count } }

    func focus(paneId: String) async -> FocusResult { .success }
    /// What reading the pane returns (the answer path reads it before sending).
    var screen: PaneScreenResult {
        get { lock.withLock { screenReply } }
        set { lock.withLock { screenReply = newValue } }
    }
    private var screenReply: PaneScreenResult = .failure("unused")

    func paneScreen(paneId: String) async -> PaneScreenResult { screen }
    func perform(_ kind: SessionActionKind, rowId: String, confirmed: Bool) async -> SessionActionOutcome { .failed("unused") }

    func answer(paneId: String, choice: AnswerChoice, question: QuestionIdentity) async -> AnswerResult {
        await withCheckedContinuation { continuation in
            lock.withLock {
                sentRequests.append(Sent(paneId: paneId, choice: choice, question: question))
                pending.append(continuation)
            }
        }
    }

    /// Replies to the oldest waiting request.
    func reply(_ result: AnswerResult) {
        let continuation = lock.withLock { pending.isEmpty ? nil : pending.removeFirst() }
        continuation?.resume(returning: result)
    }

    /// Lets the model's answer task run until it has issued `count` requests.
    func waitForRequests(_ count: Int) async {
        await waitUntil { self.pendingCount >= count }
    }
}

/// Polls until `condition` holds (up to a few seconds, then gives up and lets
/// the caller's expectation fail): the model's tasks are scheduled by the
/// runtime, and under a busy parallel test run a fixed number of yields is not enough.
@MainActor
func waitUntil(_ condition: @MainActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(3)
    while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(2)) }
}

/// Lets tasks the model started run, for expectations that something did NOT happen.
@MainActor
func settleTasks() async {
    for _ in 0..<80 { await Task.yield() }
    try? await Task.sleep(for: .milliseconds(20))
}
