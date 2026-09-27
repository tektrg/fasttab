import Foundation

/// The few `herdr` CLI calls the tmux switch needs, typed. Every call goes through the injected
/// runner (a fake in tests). A nil / false return = herdr refused or is not running.
struct HerdrCommandLine: Sendable {
    struct Pane: Decodable, Equatable, Sendable {
        let paneId: String
        let tabId: String
        let workspaceId: String
        enum CodingKeys: String, CodingKey { case paneId = "pane_id", tabId = "tab_id", workspaceId = "workspace_id" }
    }

    struct Tab: Decodable, Equatable, Sendable {
        let tabId: String
        let label: String?
        enum CodingKeys: String, CodingKey { case tabId = "tab_id", label }
    }

    /// The pane's shell and whether it sits at its prompt (nothing else in the foreground).
    struct ShellState: Equatable, Sendable {
        let shellPid: Int32
        let isAtPrompt: Bool
    }

    let executablePath: String
    let runner: any ShellCommandRunning

    func panes() async -> [Pane]? {
        await decoded(PaneListReply.self, ["pane", "list"])?.result.panes
    }

    func tabs() async -> [Tab]? {
        await decoded(TabListReply.self, ["tab", "list"])?.result.tabs
    }

    func shellState(paneId: String) async -> ShellState? {
        guard let info = await decoded(ProcessInfoReply.self, ["pane", "process-info", "--pane", paneId])?.result.processInfo,
              let shellPid = info.shellPid else { return nil }
        return ShellState(shellPid: shellPid, isAtPrompt: info.foregroundProcessGroupId == shellPid)
    }

    /// A new focused tab; its root pane, or nil.
    func createTab(cwd: String, label: String) async -> Pane? {
        await decoded(TabCreateReply.self, ["tab", "create", "--cwd", cwd, "--label", label, "--focus"])?.result.rootPane
    }

    /// Types `shellCommand` + Enter into the pane.
    func run(paneId: String, shellCommand: String) async -> Bool {
        await runner.run(executablePath, ["pane", "run", paneId, shellCommand]).succeeded
    }

    /// Brings the pane's workspace and tab to the front inside herdr (not the OS window).
    func focus(_ pane: Pane) async -> Bool {
        guard await runner.run(executablePath, ["workspace", "focus", pane.workspaceId]).succeeded else { return false }
        return await runner.run(executablePath, ["tab", "focus", pane.tabId]).succeeded
    }

    private func decoded<Reply: Decodable>(_ type: Reply.Type, _ arguments: [String]) async -> Reply? {
        let output = await runner.run(executablePath, arguments)
        guard output.succeeded else { return nil }
        return try? JSONDecoder().decode(Reply.self, from: Data(output.stdout.utf8))
    }

    // MARK: - Wire shapes (`{"id":…, "result":{…}}`)

    private struct PaneListReply: Decodable {
        struct Result: Decodable { let panes: [Pane] }
        let result: Result
    }

    private struct TabListReply: Decodable {
        struct Result: Decodable { let tabs: [Tab] }
        let result: Result
    }

    private struct TabCreateReply: Decodable {
        struct Result: Decodable {
            let rootPane: Pane
            enum CodingKeys: String, CodingKey { case rootPane = "root_pane" }
        }
        let result: Result
    }

    private struct ProcessInfoReply: Decodable {
        struct ProcessInfo: Decodable {
            let shellPid: Int32?
            let foregroundProcessGroupId: Int32?
            enum CodingKeys: String, CodingKey {
                case shellPid = "shell_pid", foregroundProcessGroupId = "foreground_process_group_id"
            }
        }
        struct Result: Decodable {
            let processInfo: ProcessInfo
            enum CodingKeys: String, CodingKey { case processInfo = "process_info" }
        }
        let result: Result
    }
}
