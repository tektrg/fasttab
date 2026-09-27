import Foundation
import Testing
@testable import AgentBar

/// Enter on a "CLI · tmux" row. Every tmux / herdr / terminal call is scripted: these tests
/// never run a real command or touch a real session.
@MainActor
struct TmuxSessionSwitcherTests {
    private static let tmux = "/fake/tmux"
    private static let herdr = "/fake/herdr"
    private static let target = "work:@3.%7"
    private static let listClients = "\(tmux) list-clients -t work -F #{client_activity}\t#{client_tty}\t#{client_pid}"
    private static let attachCommand = "'/fake/tmux' attach -t 'work:@3.%7'"

    /// Replies keyed by "executable arg1 arg2…"; anything unscripted fails like a refusing tool.
    private final class ScriptedRunner: ShellCommandRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [String: ShellCommandResult] = [:]
        private var recorded: [String] = []

        var calls: [String] { lock.withLock { recorded } }

        func reply(_ command: String, stdout: String = "", exitCode: Int32 = 0, stderr: String = "") {
            lock.withLock { replies[command] = ShellCommandResult(exitCode: exitCode, stdout: stdout, stderr: stderr) }
        }

        func run(_ executablePath: String, _ arguments: [String]) async -> ShellCommandResult {
            let command = ([executablePath] + arguments).joined(separator: " ")
            return lock.withLock {
                recorded.append(command)
                return replies[command] ?? ShellCommandResult(exitCode: 1, stdout: "", stderr: "unscripted: \(command)")
            }
        }
    }

    @MainActor private final class TerminalSpy: TerminalHosting {
        var ancestryByPid: [Int32: [HostProcess]] = [:]
        var opensWindow = true
        private(set) var activatedPidLists: [[Int32]] = []
        private(set) var openedCommands: [String] = []

        func ancestry(of pid: Int32) -> [HostProcess] { ancestryByPid[pid] ?? [] }
        func activateApp(owningAnyOf pids: [Int32]) -> Bool {
            activatedPidLists.append(pids)
            return true
        }
        func openTerminalWindow(running shellCommand: String) async -> Bool {
            openedCommands.append(shellCommand)
            return opensWindow
        }
    }

    @MainActor private struct Rig {
        let runner = ScriptedRunner()
        let terminal = TerminalSpy()
        var installed: Set<String> = ["tmux", "herdr"]

        var switcher: TmuxSessionSwitcher {
            let installed = installed
            return TmuxSessionSwitcher(runner: runner, terminal: terminal, locateExecutable: { name in
                installed.contains(name) ? "/fake/\(name)" : nil
            })
        }

        func switchTo(_ target: String = TmuxSessionSwitcherTests.target, cwd: String? = "/repo") async -> TmuxSwitchResult {
            await switcher.switchTo(tmuxTarget: target, cwd: cwd)
        }
    }

    private static func processInfo(shellPid: Int32, foregroundGroup: Int32) -> String {
        #"{"id":"cli:pane:process_info","result":{"process_info":{"foreground_process_group_id":\#(foregroundGroup),"foreground_processes":[],"pane_id":"x","shell_pid":\#(shellPid)},"type":"pane_process_info"}}"#
    }

    private static let twoPanes = #"""
    {"id":"cli:pane:list","result":{"panes":[
      {"pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1","cwd":"/a"},
      {"pane_id":"w2:p4","tab_id":"w2:t4","workspace_id":"w2","cwd":"/b"}]}}
    """#

    private static func tabs(label: String) -> String {
        #"{"id":"cli:tab:list","result":{"tabs":[{"tab_id":"w1:t1","label":"other"},{"tab_id":"w2:t4","label":"\#(label)"}]}}"#
    }

    // MARK: - 1. Already shown in a terminal

    @Test func anAttachedClientIsSwitchedToTheExactPaneAndItsTerminalAppComesForward() async {
        var rig = Rig()
        rig.installed = ["tmux"]
        rig.runner.reply(Self.listClients, stdout: "100\t/dev/ttys001\t501\n900\t/dev/ttys046\t37463\n")
        rig.runner.reply("\(Self.tmux) switch-client -c /dev/ttys046 -t work:@3.%7")
        rig.terminal.ancestryByPid[37463] = [
            HostProcess(pid: 37463, name: "tmux"), HostProcess(pid: 36712, name: "zsh"), HostProcess(pid: 699, name: "ghostty")
        ]
        #expect(await rig.switchTo() == .switched)
        #expect(rig.runner.calls == [Self.listClients, "\(Self.tmux) switch-client -c /dev/ttys046 -t work:@3.%7"])
        #expect(rig.terminal.activatedPidLists == [[37463, 36712, 699]])
        #expect(rig.terminal.openedCommands.isEmpty)
    }

    @Test func aClientInsideAHerdrPaneAlsoFocusesThatHerdrTab() async {
        let rig = Rig()
        rig.runner.reply(Self.listClients, stdout: "5\t/dev/ttys009\t800\n")
        rig.runner.reply("\(Self.tmux) switch-client -c /dev/ttys009 -t work:@3.%7")
        rig.terminal.ancestryByPid[800] = [
            HostProcess(pid: 800, name: "tmux"), HostProcess(pid: 40, name: "zsh"),
            HostProcess(pid: 30, name: "herdr"), HostProcess(pid: 699, name: "ghostty")
        ]
        rig.runner.reply("\(Self.herdr) pane list", stdout: Self.twoPanes)
        rig.runner.reply("\(Self.herdr) pane process-info --pane w1:p1", stdout: Self.processInfo(shellPid: 50, foregroundGroup: 50))
        rig.runner.reply("\(Self.herdr) pane process-info --pane w2:p4", stdout: Self.processInfo(shellPid: 40, foregroundGroup: 800))
        rig.runner.reply("\(Self.herdr) workspace focus w2")
        rig.runner.reply("\(Self.herdr) tab focus w2:t4")
        #expect(await rig.switchTo() == .switched)
        #expect(rig.runner.calls.suffix(2) == ["\(Self.herdr) workspace focus w2", "\(Self.herdr) tab focus w2:t4"])
        #expect(rig.terminal.activatedPidLists == [[800, 40, 30, 699]])
        #expect(!rig.runner.calls.contains { $0.contains("tab create") || $0.contains("pane run") })
    }

    @Test func aRefusedSwitchClientIsAFailureNamingTheTarget() async {
        let rig = Rig()
        rig.runner.reply(Self.listClients, stdout: "5\t/dev/ttys009\t800\n")
        rig.runner.reply("\(Self.tmux) switch-client -c /dev/ttys009 -t work:@3.%7", exitCode: 1, stderr: "can't find pane: %7\n")
        #expect(await rig.switchTo() == .failed("tmux could not switch to work:@3.%7 (can't find pane: %7)."))
        #expect(rig.terminal.activatedPidLists.isEmpty)
    }

    // MARK: - 2. herdr tab

    private func scriptNoClientWithHerdr(_ rig: Rig, labelledTab: String) {
        rig.runner.reply(Self.listClients, stdout: "")
        rig.runner.reply("\(Self.herdr) pane list", stdout: Self.twoPanes)
        rig.runner.reply("\(Self.herdr) tab list", stdout: Self.tabs(label: labelledTab))
        rig.runner.reply("\(Self.herdr) workspace focus w2")
        rig.runner.reply("\(Self.herdr) tab focus w2:t4")
    }

    @Test func withNoClientAHerdrTabLabelledForTheSessionIsOpenedAndAttached() async {
        let rig = Rig()
        scriptNoClientWithHerdr(rig, labelledTab: "something-else")
        rig.runner.reply("\(Self.herdr) tab create --cwd /repo --label tmux:work --focus", stdout: #"""
        {"id":"cli:tab:create","result":{"tab":{"tab_id":"w2:t4","label":"tmux:work"},
         "root_pane":{"pane_id":"w2:p4","tab_id":"w2:t4","workspace_id":"w2"}}}
        """#)
        rig.runner.reply("\(Self.herdr) pane run w2:p4 \(Self.attachCommand)")
        rig.runner.reply("\(Self.herdr) pane process-info --pane w2:p4", stdout: Self.processInfo(shellPid: 40, foregroundGroup: 40))
        rig.terminal.ancestryByPid[40] = [HostProcess(pid: 40, name: "zsh"), HostProcess(pid: 699, name: "ghostty")]
        #expect(await rig.switchTo() == .switched)
        #expect(rig.runner.calls.contains("\(Self.herdr) tab create --cwd /repo --label tmux:work --focus"))
        #expect(rig.runner.calls.contains("\(Self.herdr) pane run w2:p4 \(Self.attachCommand)"))
        #expect(rig.runner.calls.contains("\(Self.herdr) tab focus w2:t4"))
        #expect(rig.terminal.activatedPidLists == [[40, 699]])
        #expect(rig.terminal.openedCommands.isEmpty)
    }

    @Test func anEarlierSessionTabBackAtItsPromptIsReusedInsteadOfOpeningAnother() async {
        let rig = Rig()
        scriptNoClientWithHerdr(rig, labelledTab: "tmux:work")
        rig.runner.reply("\(Self.herdr) pane process-info --pane w2:p4", stdout: Self.processInfo(shellPid: 40, foregroundGroup: 40))
        rig.runner.reply("\(Self.herdr) pane run w2:p4 \(Self.attachCommand)")
        #expect(await rig.switchTo() == .switched)
        #expect(!rig.runner.calls.contains { $0.contains("tab create") })
        #expect(rig.runner.calls.contains("\(Self.herdr) pane run w2:p4 \(Self.attachCommand)"))
        #expect(rig.runner.calls.contains("\(Self.herdr) tab focus w2:t4"))
    }

    @Test func aSessionTabRunningSomethingIsNotTypedIntoANewTabOpensInstead() async {
        let rig = Rig()
        scriptNoClientWithHerdr(rig, labelledTab: "tmux:work")
        rig.runner.reply("\(Self.herdr) pane process-info --pane w2:p4", stdout: Self.processInfo(shellPid: 40, foregroundGroup: 77))
        rig.runner.reply("\(Self.herdr) tab create --cwd /repo --label tmux:work --focus", stdout: #"""
        {"id":"c","result":{"root_pane":{"pane_id":"w2:p9","tab_id":"w2:t9","workspace_id":"w2"}}}
        """#)
        rig.runner.reply("\(Self.herdr) pane run w2:p9 \(Self.attachCommand)")
        #expect(await rig.switchTo() == .switched)
        #expect(!rig.runner.calls.contains("\(Self.herdr) pane run w2:p4 \(Self.attachCommand)"))
        #expect(rig.runner.calls.contains("\(Self.herdr) pane run w2:p9 \(Self.attachCommand)"))
    }

    @Test func aHerdrThatCannotOpenATabIsAFailureNotASilentFallback() async {
        let rig = Rig()
        scriptNoClientWithHerdr(rig, labelledTab: "other")
        #expect(await rig.switchTo() == .failed("herdr could not open a tab for tmux session \"work\"."))
        #expect(rig.terminal.openedCommands.isEmpty)
    }

    @Test func withoutACwdTheNewTabOpensInTheHomeFolder() async {
        let rig = Rig()
        scriptNoClientWithHerdr(rig, labelledTab: "other")
        _ = await rig.switchTo(cwd: nil)
        #expect(rig.runner.calls.contains("\(Self.herdr) tab create --cwd \(NSHomeDirectory()) --label tmux:work --focus"))
    }

    // MARK: - 3. New terminal window

    @Test func withoutHerdrInstalledANewTerminalWindowAttaches() async {
        var rig = Rig()
        rig.installed = ["tmux"]
        rig.runner.reply(Self.listClients, stdout: "")
        #expect(await rig.switchTo() == .switched)
        #expect(rig.terminal.openedCommands == [Self.attachCommand])
        #expect(rig.runner.calls == [Self.listClients])
    }

    @Test func aHerdrThatIsNotRunningAlsoFallsBackToANewTerminalWindow() async {
        let rig = Rig()
        rig.runner.reply(Self.listClients, stdout: "")
        rig.runner.reply("\(Self.herdr) pane list", exitCode: 1, stderr: "server not running")
        #expect(await rig.switchTo() == .switched)
        #expect(rig.terminal.openedCommands == [Self.attachCommand])
    }

    @Test func noTerminalAppIsAFailure() async {
        var rig = Rig()
        rig.installed = ["tmux"]
        rig.runner.reply(Self.listClients, stdout: "")
        rig.terminal.opensWindow = false
        #expect(await rig.switchTo() == .failed("no terminal app could be opened to attach to tmux session \"work\"."))
    }

    @Test func aTargetWithAQuoteIsShellQuotedInTheAttachCommand() async {
        var rig = Rig()
        rig.installed = ["tmux"]
        rig.runner.reply("\(Self.tmux) list-clients -t it's -F #{client_activity}\t#{client_tty}\t#{client_pid}", stdout: "")
        _ = await rig.switchTo("it's:@1.%2; rm x")
        #expect(rig.terminal.openedCommands == [#"'/fake/tmux' attach -t 'it'\''s:@1.%2; rm x'"#])
    }

    // MARK: - Failures

    @Test func missingTmuxIsAFailureThatRunsNothing() async {
        var rig = Rig()
        rig.installed = []
        let result = await rig.switchTo()
        #expect(result == .failed("tmux is not installed (looked in \(ExecutableLocator.searchDirectories.joined(separator: ", ")))."))
        #expect(rig.runner.calls.isEmpty)
    }

    @Test func aGoneSessionIsAFailureAndOpensNothing() async {
        let rig = Rig()
        rig.runner.reply(Self.listClients, exitCode: 1, stderr: "can't find session: work\n")
        #expect(await rig.switchTo() == .failed("the tmux session \"work\" is gone (can't find session: work)."))
        #expect(rig.runner.calls == [Self.listClients])
        #expect(rig.terminal.openedCommands.isEmpty)
    }

    @Test func aTargetWithControlCharactersIsRefusedBeforeAnyCommand() async {
        let rig = Rig()
        let result = await rig.switchTo("work\n:@1.%2")
        #expect(result == .failed("the tmux target \"work\n:@1.%2\" is not valid."))
        #expect(rig.runner.calls.isEmpty)
    }

    // MARK: - Parsing

    @Test func sessionNameIsTheTextBeforeTheFirstColon() {
        #expect(TmuxSessionSwitcher.sessionName(of: "incident-home:@639.%639") == "incident-home")
        #expect(TmuxSessionSwitcher.sessionName(of: "bare") == "bare")
        #expect(!TmuxSessionSwitcher.isUsable(":@1.%2"))
        #expect(!TmuxSessionSwitcher.isUsable(""))
    }

    @Test func theMostRecentlyActiveClientWinsAndBadLinesAreSkipped() {
        let output = "10\t/dev/ttys1\t11\ngarbage\n30\t/dev/ttys3\t33\n20\t\t22\n"
        #expect(TmuxSessionSwitcher.mostRecentClient(output) == .init(tty: "/dev/ttys3", pid: 33))
        #expect(TmuxSessionSwitcher.mostRecentClient("") == nil)
    }

    @Test func executablesAreFoundInTheFirstFolderThatHasThem() {
        let found = ExecutableLocator.locate("tmux", in: ["/a", "/b", "/c"], isExecutable: { $0 != "/a/tmux" })
        #expect(found == "/b/tmux")
        #expect(ExecutableLocator.locate("tmux", in: ["/a"], isExecutable: { _ in false }) == nil)
    }

    @Test func appleScriptStringsEscapeQuotesAndBackslashes() {
        #expect(CommandQuoting.appleScriptString(#"a "b" \c"#) == #""a \"b\" \\c""#)
    }
}
