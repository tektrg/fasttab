import Foundation
@testable import AgentBar

/// A 3-question AskUserQuestion form (the real example from an agent session, 2026-09-19:
/// `Fixtures/ask-user-question-3-questions.jsonl`) and the screens a terminal draws for it, one tab at a time.
enum FormFixtures {
    static let rule = String(repeating: "─", count: 90)

    static func loadJSONL(_ name: String) -> [String] {
        let url = Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures")!
        return try! String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    /// The transcript line with the real 3-question call.
    static var realCallLine: String { loadJSONL("ask-user-question-3-questions")[0] }
    static let realToolUseId = "toolu_012ni7vHyXZinLrTSGpQm1Fy"

    static func form(multiSelect: Set<Int> = []) -> PendingQuestionForm {
        let questions = [
            ("Done means", "What should \"Done\" do to an agent?", ["Just clear it (Recommended)", "Close the worker too"]),
            ("Comes back", "After you press Done or Park, the agent later starts working again and finishes. What should happen?",
             ["Back to Needs you (Recommended)", "Done returns, Parked stays"]),
            ("Alerts", "Should the orange menu-bar count and macOS notification be built in this round too?",
             ["Yes, for Needs you (Recommended)", "No, panel only for now"])
        ]
        return PendingQuestionForm(toolUseId: realToolUseId, questions: questions.enumerated().map { position, entry in
            FormQuestion(header: entry.0, question: entry.1, isMultiSelect: multiSelect.contains(position),
                         options: entry.2.map { .init(label: $0, description: "About \($0)") })
        })
    }

    /// What the terminal draws while it is on tab `tab` (0-based) of `form`, the cursor on the first option.
    static func screen(_ form: PendingQuestionForm, tab: Int) -> [String] {
        let question = form.questions[tab]
        let tabs = form.questions.map { "☐ \($0.header)" }.joined(separator: "  ")
        var lines = [rule, "  ←  \(tabs)  ✔ Submit  →", QuestionDisplayText.clean(question.question), ""]
        for (position, option) in question.options.enumerated() {
            let box = question.isMultiSelect ? "[ ] " : ""
            lines.append("  \(position == 0 ? "❯ " : "  ")\(position + 1). \(box)\(option.label)")
            lines.append("       \(option.description)")
        }
        lines.append("    \(question.options.count + 1). Type something.")
        lines.append(tab == form.questions.count - 1 ? "    Submit" : "    Next")
        lines += [rule, "  Enter to select · ↑/↓ to navigate · Esc to cancel"]
        return lines
    }

    /// The last screen of the form: every tab answered, waiting for the final Submit.
    static func reviewScreen(_ form: PendingQuestionForm) -> [String] {
        [rule, "  ←  ✔ Submit  →", "  Review your answers", "", "  Ready to submit your answers?", "  ❯ 1. Submit answers", "    2. Cancel", rule]
    }

    /// The prompt again once the form is gone.
    static let goneScreen = ["⏺ Thanks, carrying on.", "", "❯ "]
}

/// A terminal that behaves like Claude Code's tabbed form behind the dashboard: it shows one tab, answers only the
/// question on screen, then moves to the next tab, the review screen, and, after the last answer, the prompt.
final class FakeFormTerminal: AgentStatusSource, @unchecked Sendable {
    struct Sent: Equatable {
        let choice: AnswerChoice
        let question: QuestionIdentity
    }

    let updates = AsyncStream<StatusSnapshot> { _ in }
    let form: PendingQuestionForm
    private let lock = NSLock()
    private var currentTab: Int
    private var sentAnswers: [Sent] = []
    private var readCount = 0
    private var refusedTab: Int?
    private var gone = false
    private var screenFailure: String?
    /// Runs before each pane read (a test moves the terminal on, or breaks it).
    var beforeRead: (@Sendable (FakeFormTerminal) -> Void)?
    /// Extra reads that still show the tab before the one just answered (the terminal is slow to redraw).
    private var staleReadsLeft = 0
    /// Runs before each answer request is handled, with how many were made before it (a test holds the batch here).
    var beforeAnswer: (@Sendable (Int) async -> Void)?

    init(form: PendingQuestionForm, startTab: Int = 0) {
        self.form = form
        currentTab = startTab
    }

    var sent: [Sent] { lock.withLock { sentAnswers } }
    var reads: Int { lock.withLock { readCount } }
    var tab: Int { lock.withLock { currentTab } }
    func refuse(atTab tab: Int) { lock.withLock { refusedTab = tab } }
    func moveTo(tab: Int) { lock.withLock { currentTab = tab } }
    func failReads(_ message: String?) { lock.withLock { screenFailure = message } }
    func stayStale(reads: Int) { lock.withLock { staleReadsLeft = reads } }

    func focus(paneId: String) async -> FocusResult { .success }
    func perform(_ kind: SessionActionKind, rowId: String, confirmed: Bool) async -> SessionActionOutcome { .failed("unused") }

    private var currentLines: [String] {
        if gone { return FormFixtures.goneScreen }
        return currentTab >= form.questions.count ? FormFixtures.reviewScreen(form) : FormFixtures.screen(form, tab: currentTab)
    }

    func paneScreen(paneId: String) async -> PaneScreenResult {
        beforeRead?(self)
        return lock.withLock {
            readCount += 1
            if let screenFailure { return .failure(screenFailure) }
            if staleReadsLeft > 0, currentTab > 0 {
                staleReadsLeft -= 1
                return .screen(lines: FormFixtures.screen(form, tab: currentTab - 1), readAt: Date())
            }
            return .screen(lines: currentLines, readAt: Date())
        }
    }

    func answer(paneId: String, choice: AnswerChoice, question: QuestionIdentity) async -> AnswerResult {
        await beforeAnswer?(sent.count)
        return lock.withLock {
            sentAnswers.append(Sent(choice: choice, question: question))
            if refusedTab == currentTab { return .failed("dashboard: the answer was not accepted") }
            guard currentTab < form.questions.count,
                  let shown = PaneQuestionReader.identity(in: FormFixtures.screen(form, tab: currentTab)),
                  shown.isSameQuestion(as: question) else { return .failed("question is gone") }
            currentTab += 1
            if currentTab >= form.questions.count { gone = true }   // the dashboard presses Submit answers itself
            return .sent(next: currentTab < form.questions.count
                ? PaneQuestionReader.question(in: FormFixtures.screen(form, tab: currentTab)) : nil)
        }
    }
}

/// Holds a task until a test lets it go.
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                if !isOpen { waiters.append(continuation) }
                return isOpen
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let toResume = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        toResume.forEach { $0.resume() }
    }
}
