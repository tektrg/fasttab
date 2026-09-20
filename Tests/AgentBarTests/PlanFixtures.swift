import Foundation
@testable import AgentBar

/// Hand-built plan-approval boxes (Claude's plan mode) for the plan card tests.
enum PlanFixtures {
    static let title = "Claude has written up a plan and is ready to execute. Would you like to proceed?"
    static let planPath = "~/.claude/plans/dapper-strolling-sprout.md"

    /// The real capture's box.
    static let box = PermissionPrompt(
        tool: "ExitPlanMode", detail: "", title: title,
        options: [
            .init(index: 1, label: "Yes, and use auto mode"),
            .init(index: 2, label: "Yes, manually approve edits"),
            .init(index: 3, label: "Tell Claude what to change"),
        ],
        cursorIndex: 1, kind: .plan, planPath: planPath
    )

    /// Another plan: same words, other file.
    static let otherPlan = PermissionPrompt(
        tool: "ExitPlanMode", detail: "", title: title, options: box.options, cursorIndex: 1,
        kind: .plan, planPath: "~/.claude/plans/other-plan.md"
    )

    /// The "bypass permissions" wording some Claude versions draw.
    static let bypassBox = PermissionPrompt(
        tool: "ExitPlanMode", detail: "", title: title,
        options: [
            .init(index: 1, label: "Yes, and bypass permissions"),
            .init(index: 2, label: "Yes, manually approve edits"),
            .init(index: 3, label: "Tell Claude what to change"),
        ],
        cursorIndex: 1, kind: .plan, planPath: planPath
    )

    /// A box whose rows are worded nothing like today's: nothing special is recognised in it, except that the last row takes feedback.
    static let unknownWording = PermissionPrompt(
        tool: "ExitPlanMode", detail: "", title: title,
        options: [.init(index: 1, label: "Go ahead"), .init(index: 2, label: "Ask me each time"), .init(index: 3, label: "Revise the plan")],
        cursorIndex: 1, kind: .plan, planPath: nil
    )

    /// The pane's screen for `prompt`, as the real capture draws it.
    static func screen(for prompt: PermissionPrompt) -> [String] {
        var lines = ["some earlier output", "", prompt.title, ""]
        for option in prompt.options {
            lines.append((option.index == prompt.cursorIndex ? "❯ " : "  ") + "\(option.index). \(option.label)")
        }
        if prompt.feedbackOption != nil { lines.append("     shift+tab to approve with this feedback") }
        if let path = prompt.planPath { lines += ["", "ctrl+g to edit in Vim · \(path)"] }
        return lines
    }

    static func agent(_ id: String, _ prompt: PermissionPrompt? = box, sessionId: String? = "session-1") -> AgentSnapshot {
        PermissionFixtures.agent(id, prompt, sessionId: sessionId)
    }

    /// The dashboard's JSON for a plan box (what `computed.needsYou[].permission` carries).
    static func json(_ prompt: PermissionPrompt) -> String {
        let options = prompt.options.map { #"{"index": \#($0.index), "label": "\#($0.label)"}"# }.joined(separator: ", ")
        let path = prompt.planPath.map { "\"\($0)\"" } ?? "null"
        return #"{"tool": "ExitPlanMode", "kind": "plan", "detail": null, "title": "\#(prompt.title)", "options": [\#(options)], "cursorIndex": \#(prompt.cursorIndex ?? 1), "planPath": \#(path)}"#
    }
}
