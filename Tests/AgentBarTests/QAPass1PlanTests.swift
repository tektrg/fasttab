import Foundation
import Testing
@testable import AgentBar

/// QA pass 1: the plan card's privilege second-press, and the plan file it reads from a path the pane printed.
struct QAPass1PlanTests {
    private func option(_ label: String) -> PermissionPrompt.Option { .init(index: 1, label: label) }

    /// Rows that widen what the agent may do, however the box words or spaces them, need the second press.
    @Test(arguments: [
        "Yes, and use auto mode", "Yes, and use Auto Mode", "Yes, and use auto-mode", "Yes, and use auto   mode",
        "Yes, and bypass permissions", "Yes, and Bypass  Permissions",
        "Yes, and auto-accept edits", "Yes, clear context and auto accept edits",
    ])
    func widerPermissionRowsNeedASecondPress(label: String) {
        #expect(PermissionPrompt.isPrivilegeChange(option(label)), "\(label)")
    }

    @Test(arguments: ["Yes, manually approve edits", "Tell Claude what to change", "No, keep planning", "Yes"])
    func ordinaryRowsDoNot(label: String) {
        #expect(!PermissionPrompt.isPrivilegeChange(option(label)), "\(label)")
    }

    // MARK: - The plan file

    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("qa-plan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude/plans"), withIntermediateDirectories: true)
        return home
    }

    /// A relative or `..`-laden path never reaches outside what it names, and only Markdown is ever read.
    @Test func onlyMarkdownAtAnAbsoluteOrTildePathIsRead() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Data("secret".utf8).write(to: home.appendingPathComponent("secret.txt"))
        for path in ["relative/plan.md", "../plan.md", "~other/plan.md", "~/.claude/plans/../secret.txt", "/etc/hosts", "file:///etc/hosts.md"] {
            if case .text = PlanFileReader.read(path: path, home: home) { Issue.record("read \(path)") }
        }
    }

    /// A symlink is not "a plain file": one that points at anything else on the disk is not followed.
    @Test func aSymlinkNamedLikeAPlanIsNotFollowed() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let target = home.appendingPathComponent("private-notes.md")
        try Data("do not show".utf8).write(to: target)
        let link = home.appendingPathComponent(".claude/plans/sneaky.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        if case .text = PlanFileReader.read(path: "~/.claude/plans/sneaky.md", home: home) { Issue.record("followed the symlink") }
    }

    /// A pipe or device named *.md must not block the reader.
    @Test func aNamedPipeIsNotReadAndDoesNotBlock() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let path = home.appendingPathComponent(".claude/plans/pipe.md").path
        #expect(mkfifo(path, 0o600) == 0)
        if case .text = PlanFileReader.read(path: path, home: home) { Issue.record("read a pipe") }
    }
}

/// Holding Return must never do the second press of a two-press action for the user.
@MainActor
struct QAPass1KeyRepeatTests {
    typealias F = AgentListFixtures

    @Test func aHeldReturnDoesNotConfirmAnAutoModeRowTheFirstPressJustArmed() async {
        let defaults = makeScratchDefaults("qa-pass1-repeat")
        let model = AgentPanelModel(
            store: FrecencyStore(defaults: defaults),
            triageStore: TriageStore(defaults: defaults),
            answer: AnswerCardModel(loadSessionContext: { _ in .empty }, openFile: { _ in }),
            permission: PermissionCardModel(loadSessionContext: { _ in .empty }, loadPlanFile: { _ in .noPath }),
            now: { F.now }
        )
        let source = PermissionFakeSource()
        source.screen = .screen(lines: PlanFixtures.screen(for: PlanFixtures.box), readAt: F.now)
        model.statusSource = source
        model.receive(F.snapshot([PlanFixtures.agent("a")]))
        model.press(.review, on: "a")
        await waitUntil { model.permission.card?.plan?.phase == .ready }

        model.permission.handle(.digit(1))     // "Yes, and use auto mode"
        model.activateSelected()                // first press: arms
        #expect(model.permission.card?.plan?.isConfirmingPrivilege == true)
        model.activateSelected(isKeyRepeat: true)   // the key is still held down
        model.activateSelected(isKeyRepeat: true)
        await settleTasks()
        #expect(source.planSent.isEmpty)
        #expect(model.permission.card?.plan?.isConfirmingPrivilege == true)
        model.activateSelected()                // a new, deliberate press confirms
        await source.waitForPlanRequests(1)
        #expect(source.planSent.map(\.index) == [1])
    }
}
