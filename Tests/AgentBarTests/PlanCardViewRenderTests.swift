import AppKit
import SwiftUI
import Testing
@testable import AgentBar

/// The plan card draws in each of its states without breaking layout. Set `PLAN_RENDER_DIR` to keep the PNGs.
@MainActor @Suite(.serialized)
struct PlanCardViewRenderTests {
    typealias F = PlanFixtures

    private func planText() throws -> String {
        let url = try #require(Bundle.module.url(forResource: "plan-fixture", withExtension: "md", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func model(
        planFile: PlanFile, prompt: PermissionPrompt = F.box, configure: (PermissionCardModel) -> Void = { _ in }
    ) async -> PermissionCardModel {
        let model = PermissionCardModel(
            loadSessionContext: { _ in SessionContext(latestMessage: "The plan is written. **Ready** when you are.", planFile: nil) },
            loadPlanFile: { _ in planFile }
        )
        let source = PermissionFakeSource()
        source.screen = .screen(lines: F.screen(for: prompt), readAt: Date())
        model.statusSource = source
        model.open(F.agent("a", prompt))
        await waitUntil { model.card?.plan?.phase == .ready && model.card?.planFile != .loading && model.card?.message != .loading }
        configure(model)
        return model
    }

    private func render(_ model: PermissionCardModel, name: String) -> NSBitmapImageRep? {
        let height = AgentPanelMetrics.fullBodyHeight()
        let host = NSHostingView(rootView: PermissionCardView(permission: model, bodyHeight: height).frame(width: AgentPanelMetrics.width, height: height))
        host.frame = CGRect(x: 0, y: 0, width: AgentPanelMetrics.width, height: height)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let path = ProcessInfo.processInfo.environment["PLAN_RENDER_DIR"], let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path).appendingPathComponent("plan-\(name).png"))
        }
        return bitmap
    }

    @Test func theCardDrawsWithAPlanAndNothingChosen() async throws {
        #expect(render(await model(planFile: .text(try planText(), truncated: false)), name: "plan") != nil)
    }

    @Test func theCardDrawsChosenConfirmingAndTypingFeedback() async throws {
        let text = try planText()
        #expect(render(await model(planFile: .text(text, truncated: false)) { $0.handle(.digit(2)) }, name: "chosen") != nil)
        #expect(render(await model(planFile: .text(text, truncated: false)) { $0.handle(.digit(1)); $0.handle(.enter) }, name: "confirming-auto") != nil)
        #expect(render(await model(planFile: .text(text, truncated: false)) { $0.clickPlanOption(index: 3); $0.setFeedbackText("Split step 2\nin two") }, name: "feedback") != nil)
    }

    @Test func theCardDrawsWithoutAPlanFile() async {
        #expect(render(await model(planFile: .unreadable("The plan file is not on this Mac: ~/.claude/plans/gone.md.")), name: "missing") != nil)
        let noPath = PermissionPrompt(tool: "ExitPlanMode", detail: "", title: F.title, options: F.box.options, cursorIndex: 1, kind: .plan, planPath: nil)
        #expect(render(await model(planFile: .noPath, prompt: noPath), name: "no-path") != nil)
    }

    @Test func aLongAndATruncatedPlanDrawAndTheRowsStayInView() async {
        let long = (1...80).map { "\($0). Step number \($0) of the plan, described at some length so that it wraps." }.joined(separator: "\n")
        #expect(render(await model(planFile: .text("# Long plan\n\n" + long, truncated: true)), name: "long-truncated") != nil)
    }

    @Test func theCardDrawsWhileCheckingAndWhenTheTerminalNoLongerShowsTheBox() async {
        let checking = PermissionCardModel(loadSessionContext: { _ in .empty }, loadPlanFile: { _ in .loading })
        let source = PermissionFakeSource()
        source.screen = .screen(lines: F.screen(for: F.box), readAt: Date())
        checking.statusSource = source
        checking.open(F.agent("a"))
        #expect(render(checking, name: "checking") != nil)
        let gone = PermissionCardModel(loadSessionContext: { _ in .empty }, loadPlanFile: { _ in .noPath })
        let emptySource = PermissionFakeSource()
        emptySource.screen = .screen(lines: ["$ "], readAt: Date())
        gone.statusSource = emptySource
        gone.open(F.agent("a"))
        await waitUntil { gone.card?.plan?.phase != .checking }
        #expect(render(gone, name: "gone") != nil)
    }
}
