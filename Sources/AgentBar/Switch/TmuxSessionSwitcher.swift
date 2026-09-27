import Foundation

enum TmuxSwitchResult: Equatable, Sendable {
    case switched
    /// Footer text after "Couldn't switch: ".
    case failed(String)
}

/// Enter on a "CLI · tmux" row. Behind a protocol so `AgentSwitchCoordinator` is tested with a fake.
@MainActor
protocol TmuxSessionSwitching {
    /// `tmuxTarget` is the dashboard's "session:@window.%pane"; `cwd` opens a new herdr tab there.
    func switchTo(tmuxTarget: String, cwd: String?) async -> TmuxSwitchResult
}

/// Brings a tmux-hosted Claude CLI session forward, in this order:
/// 1. The session already shows in a terminal (a tmux client): point that client at the
///    window+pane, then bring its terminal forward — the herdr tab when the client runs in a
///    herdr pane, and the app owning the client (Ghostty, iTerm, Warp, Terminal).
/// 2. Else herdr is running: attach in a herdr tab labelled `tmux:<session>` (reusing one sitting
///    at its prompt, else a new one) and focus it.
/// 3. Else a new terminal window (Ghostty, else iTerm, else Terminal) running `tmux attach`.
/// Only read-only tmux calls plus `switch-client` / `attach` are ever run: nothing is killed.
@MainActor
struct TmuxSessionSwitcher: TmuxSessionSwitching {
    var runner: any ShellCommandRunning = ProcessCommandRunner()
    var terminal: any TerminalHosting = TerminalAppController()
    var locateExecutable: (String) -> String? = { ExecutableLocator.locate($0) }

    static let herdrTabLabelPrefix = "tmux:"
    private static let maxTargetLength = 256

    func switchTo(tmuxTarget: String, cwd: String?) async -> TmuxSwitchResult {
        guard Self.isUsable(tmuxTarget) else { return .failed("the tmux target \"\(tmuxTarget)\" is not valid.") }
        guard let tmux = locateExecutable("tmux") else {
            return .failed("tmux is not installed (looked in \(ExecutableLocator.searchDirectories.joined(separator: ", "))).")
        }
        let session = Self.sessionName(of: tmuxTarget)
        let clients = await runner.run(tmux, ["list-clients", "-t", session, "-F", "#{client_activity}\t#{client_tty}\t#{client_pid}"])
        guard clients.succeeded else {
            return .failed("the tmux session \"\(session)\" is gone (\(clients.errorLine ?? "tmux refused")).")
        }
        if let client = Self.mostRecentClient(clients.stdout) {
            return await switchAttached(client, tmux: tmux, target: tmuxTarget)
        }
        let attachCommand = "\(CommandQuoting.shellWord(tmux)) attach -t \(CommandQuoting.shellWord(tmuxTarget))"
        if let herdr = herdrCommandLine(), let result = await attachInHerdr(herdr, session: session, cwd: cwd, attachCommand: attachCommand) {
            return result
        }
        return await terminal.openTerminalWindow(running: attachCommand)
            ? .switched
            : .failed("no terminal app could be opened to attach to tmux session \"\(session)\".")
    }

    // MARK: - 1. A terminal already shows the session

    struct TmuxClient: Equatable {
        let tty: String
        let pid: Int32
    }

    private func switchAttached(_ client: TmuxClient, tmux: String, target: String) async -> TmuxSwitchResult {
        let switched = await runner.run(tmux, ["switch-client", "-c", client.tty, "-t", target])
        guard switched.succeeded else {
            return .failed("tmux could not switch to \(target) (\(switched.errorLine ?? "tmux refused")).")
        }
        let chain = terminal.ancestry(of: client.pid)
        if chain.contains(where: { $0.name == "herdr" }), let herdr = herdrCommandLine() {
            await focusHerdrPane(hosting: chain, herdr)
        }
        _ = terminal.activateApp(owningAnyOf: chain.map(\.pid))   // best effort: tmux already switched
        return .switched
    }

    /// The herdr pane whose shell is an ancestor of the tmux client.
    private func focusHerdrPane(hosting chain: [HostProcess], _ herdr: HerdrCommandLine) async {
        let chainPids = Set(chain.map(\.pid))
        for pane in await herdr.panes() ?? [] {
            if let shell = await herdr.shellState(paneId: pane.paneId), chainPids.contains(shell.shellPid) {
                _ = await herdr.focus(pane)
                return
            }
        }
    }

    // MARK: - 2. herdr tab

    /// nil when herdr is not running (fall through to a new terminal window).
    private func attachInHerdr(_ herdr: HerdrCommandLine, session: String, cwd: String?, attachCommand: String) async -> TmuxSwitchResult? {
        guard let panes = await herdr.panes() else { return nil }
        let label = Self.herdrTabLabelPrefix + session
        var pane = await idlePane(inTabsLabelled: label, panes: panes, herdr)
        if pane == nil { pane = await herdr.createTab(cwd: cwd ?? NSHomeDirectory(), label: label) }
        guard let pane else {
            return .failed("herdr could not open a tab for tmux session \"\(session)\".")
        }
        guard await herdr.run(paneId: pane.paneId, shellCommand: attachCommand) else {
            return .failed("herdr could not run tmux attach for session \"\(session)\".")
        }
        _ = await herdr.focus(pane)
        if let shell = await herdr.shellState(paneId: pane.paneId) {
            _ = terminal.activateApp(owningAnyOf: terminal.ancestry(of: shell.shellPid).map(\.pid))
        }
        return .switched
    }

    /// A pane of an earlier `tmux:<session>` tab whose shell is back at its prompt (the user detached).
    private func idlePane(inTabsLabelled label: String, panes: [HerdrCommandLine.Pane], _ herdr: HerdrCommandLine) async -> HerdrCommandLine.Pane? {
        let labelledTabIds = Set((await herdr.tabs() ?? []).filter { $0.label == label }.map(\.tabId))
        for pane in panes where labelledTabIds.contains(pane.tabId) {
            if await herdr.shellState(paneId: pane.paneId)?.isAtPrompt == true { return pane }
        }
        return nil
    }

    private func herdrCommandLine() -> HerdrCommandLine? {
        locateExecutable("herdr").map { HerdrCommandLine(executablePath: $0, runner: runner) }
    }

    // MARK: - Parsing

    /// "work:@3.%7" -> "work" (tmux never allows ':' in a session name).
    static func sessionName(of target: String) -> String {
        String(target.prefix { $0 != ":" })
    }

    static func isUsable(_ target: String) -> Bool {
        !target.isEmpty && target.count <= maxTargetLength && !sessionName(of: target).isEmpty
            && !target.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// `list-clients -F "#{client_activity}\t#{client_tty}\t#{client_pid}"` -> the most recently used client.
    static func mostRecentClient(_ output: String) -> TmuxClient? {
        output.split(whereSeparator: \.isNewline).compactMap { line -> (activity: Int, client: TmuxClient)? in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3, let pid = Int32(fields[2]), !fields[1].isEmpty else { return nil }
            return (Int(fields[0]) ?? 0, TmuxClient(tty: String(fields[1]), pid: pid))
        }.max { $0.activity < $1.activity }?.client
    }
}
