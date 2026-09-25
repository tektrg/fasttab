import Foundation
@testable import AgentBar

/// Hand-built permission boxes, blocked agents and a scripted dashboard for the permission tests.
enum PermissionFixtures {
    static let bash = PermissionPrompt(
        tool: "Bash",
        detail: "rm -rf /tmp/aptusfit-maestro-sim.lock",
        title: "Do you want to proceed?",
        options: [
            .init(index: 1, label: "Yes"),
            .init(index: 2, label: "Yes, and don't ask again for rm commands in /tmp"),
            .init(index: 3, label: "No, tell Claude what to do differently (esc)"),
        ],
        cursorIndex: 1
    )

    /// A box with no "don't ask again" row (a one-off).
    static let oneOff = PermissionPrompt(
        tool: "Write",
        detail: "notes.md",
        title: "Do you want to proceed?",
        options: [.init(index: 1, label: "Yes"), .init(index: 2, label: "No")],
        cursorIndex: 1
    )

    static let longCommand = "cd /Users/trungluong/01_Project/AptusFit && find . -name '*.py' -not -path './node_modules/*' | xargs grep -l 'permission' | head -50 && echo done-with-a-very-long-command-line-that-wraps"

    /// The pane's screen for `prompt`, as a fresh unwrapped read shows it.
    static func screen(for prompt: PermissionPrompt) -> [String] {
        let border = String(repeating: "─", count: 90)
        var lines = ["⏺ Bash(ls)", "  ⎿  done", "", "⏺ \(prompt.tool)(\(prompt.detail))", "  ⎿  Running…", "", border, " \(prompt.tool) command", "", prompt.title]
        for option in prompt.options {
            lines.append((option.index == prompt.cursorIndex ? "❯ " : "  ") + "\(option.index). \(option.label)")
        }
        return lines
    }

    static func agent(_ id: String, _ prompt: PermissionPrompt?, sessionId: String? = "session-1", paneId: String? = nil) -> AgentSnapshot {
        AnswerFixtures.blockedAgent(id, blocker: prompt.map(AgentBlocker.permissionReview) ?? .permission, sessionId: sessionId, paneId: paneId)
    }

    /// The dashboard's JSON for a prompt (what `computed.needsYou[].permission` carries).
    static func json(_ prompt: PermissionPrompt) -> String {
        let options = prompt.options.map { #"{"index": \#($0.index), "label": \#(quoted($0.label))}"# }.joined(separator: ", ")
        let cursor = prompt.cursorIndex.map(String.init) ?? "null"
        return #"{"tool": \#(quoted(prompt.tool)), "detail": \#(quoted(prompt.detail)), "title": \#(quoted(prompt.title)), "options": [\#(options)], "cursorIndex": \#(cursor)}"#
    }

    private static func quoted(_ text: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes])
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }
}

/// A status source whose permission requests stay pending until the test replies, and that
/// records what it was asked. It cannot answer questions: any such call is a test failure to notice.
final class PermissionFakeSource: AgentStatusSource, @unchecked Sendable {
    struct Sent: Equatable {
        let paneId: String
        let choice: PermissionChoice
        let permission: PermissionPrompt
    }

    /// A row picked on a plan card (`choice: "select"`).
    struct PlanSent: Equatable {
        let paneId: String
        let index: Int
        let text: String?
        let permission: PermissionPrompt
    }

    let updates = AsyncStream<StatusSnapshot> { _ in }
    private let lock = NSLock()
    private var sentRequests: [Sent] = []
    private var pending: [CheckedContinuation<PermissionResult, Never>] = []
    private var planRequests: [PlanSent] = []
    private var planPending: [CheckedContinuation<PermissionResult, Never>] = []
    private var screenReply: PaneScreenResult = .failure("unused")
    private var reads = 0
    private var answerCalls = 0

    var sent: [Sent] { lock.withLock { sentRequests } }
    var pendingCount: Int { lock.withLock { pending.count } }
    var planSent: [PlanSent] { lock.withLock { planRequests } }
    var planPendingCount: Int { lock.withLock { planPending.count } }
    var screenReads: Int { lock.withLock { reads } }
    var answersAttempted: Int { lock.withLock { answerCalls } }

    /// What reading the pane returns.
    var screen: PaneScreenResult {
        get { lock.withLock { screenReply } }
        set { lock.withLock { screenReply = newValue } }
    }

    func focus(paneId: String) async -> FocusResult { .success }

    func paneScreen(paneId: String) async -> PaneScreenResult {
        lock.withLock { reads += 1 }
        return screen
    }

    func answer(paneId: String, choice: AnswerChoice, question: QuestionIdentity) async -> AnswerResult {
        lock.withLock { answerCalls += 1 }
        return .failed("unused")
    }

    func perform(_ kind: SessionActionKind, rowId: String, confirmed: Bool) async -> SessionActionOutcome { .failed("unused") }

    func permission(paneId: String, choice: PermissionChoice, permission: PermissionPrompt) async -> PermissionResult {
        await withCheckedContinuation { continuation in
            lock.withLock {
                sentRequests.append(Sent(paneId: paneId, choice: choice, permission: permission))
                pending.append(continuation)
            }
        }
    }

    /// Replies to the oldest waiting request.
    func reply(_ result: PermissionResult) {
        let continuation = lock.withLock { pending.isEmpty ? nil : pending.removeFirst() }
        continuation?.resume(returning: result)
    }

    func selectPlanOption(paneId: String, index: Int, text: String?, permission: PermissionPrompt) async -> PermissionResult {
        await withCheckedContinuation { continuation in
            lock.withLock {
                planRequests.append(PlanSent(paneId: paneId, index: index, text: text, permission: permission))
                planPending.append(continuation)
            }
        }
    }

    /// Replies to the oldest waiting plan request.
    func replyPlan(_ result: PermissionResult) {
        let continuation = lock.withLock { planPending.isEmpty ? nil : planPending.removeFirst() }
        continuation?.resume(returning: result)
    }

    func waitForPlanRequests(_ count: Int) async {
        await waitUntil { self.planPendingCount >= count }
    }

    func waitForRequests(_ count: Int) async {
        await waitUntil { self.pendingCount >= count }
    }
}
