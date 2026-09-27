import AppKit
import Darwin

/// One process in a parent chain: its pid and executable name (`p_comm`, ≤16 chars).
struct HostProcess: Equatable, Sendable {
    let pid: Int32
    let name: String
}

/// The OS side of the tmux switch: which app a terminal process belongs to, bringing that app
/// forward, and opening a new terminal window. Behind a protocol so tests never touch real apps.
@MainActor
protocol TerminalHosting {
    /// `pid` and its parents, nearest first, stopping before launchd.
    func ancestry(of pid: Int32) -> [HostProcess]
    /// Activates the first of `pids` that is a regular app (Ghostty, iTerm, Warp, Terminal…).
    func activateApp(owningAnyOf pids: [Int32]) -> Bool
    /// Opens a new window running `shellCommand` in the first installed terminal
    /// (Ghostty, else iTerm, else Terminal).
    func openTerminalWindow(running shellCommand: String) async -> Bool
}

@MainActor
struct TerminalAppController: TerminalHosting {
    var runner: any ShellCommandRunning = ProcessCommandRunner()

    static let ghosttyBundleIdentifier = "com.mitchellh.ghostty"
    static let iTermBundleIdentifier = "com.googlecode.iterm2"
    static let terminalBundleIdentifier = "com.apple.Terminal"
    private static let maxAncestryDepth = 32

    func ancestry(of pid: Int32) -> [HostProcess] {
        var chain: [HostProcess] = []
        var current = pid
        while current > 1, chain.count < Self.maxAncestryDepth, let entry = Self.processEntry(current) {
            chain.append(HostProcess(pid: current, name: entry.name))
            current = entry.parentPid
        }
        return chain
    }

    func activateApp(owningAnyOf pids: [Int32]) -> Bool {
        for pid in pids {
            guard let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular else { continue }
            NSApp.yieldActivation(to: app)
            return app.activate(options: [])
        }
        return false
    }

    func openTerminalWindow(running shellCommand: String) async -> Bool {
        let workspace = NSWorkspace.shared
        if let ghostty = workspace.urlForApplication(withBundleIdentifier: Self.ghosttyBundleIdentifier) {
            // A new Ghostty instance whose only window runs the command and quits with it.
            return await runner.run("/usr/bin/open", [
                "-na", ghostty.path, "--args", "--quit-after-last-window-closed=true", "-e", "/bin/zsh", "-lc", shellCommand
            ]).succeeded
        }
        let script = CommandQuoting.appleScriptString(shellCommand)
        if workspace.urlForApplication(withBundleIdentifier: Self.iTermBundleIdentifier) != nil {
            return await osascript("tell application id \"\(Self.iTermBundleIdentifier)\"\nactivate\ncreate window with default profile command \(script)\nend tell")
        }
        return await osascript("tell application id \"\(Self.terminalBundleIdentifier)\"\nactivate\ndo script \(script)\nend tell")
    }

    private func osascript(_ source: String) async -> Bool {
        await runner.run("/usr/bin/osascript", ["-e", source]).succeeded
    }

    /// Parent pid and name of one process, from the kernel (no `ps`).
    private static func processEntry(_ pid: Int32) -> (parentPid: Int32, name: String)? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let name = withUnsafeBytes(of: info.kp_proc.p_comm) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return (info.kp_eproc.e_ppid, name)
    }
}

/// Quoting for text handed to a shell or to AppleScript (a tmux target comes from the dashboard).
enum CommandQuoting {
    /// A POSIX single-quoted word.
    static func shellWord(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// An AppleScript string literal.
    static func appleScriptString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
