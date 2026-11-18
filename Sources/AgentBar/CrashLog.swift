import AppKit

/// Writes an uncaught Objective-C exception (name, reason, stack) to
/// `~/Library/Logs/AgentBar/crash-<timestamp>.log` before the app aborts (2026-11-17). The Pro lost
/// three AgentBar SIGABRTs whose only trace was `NSGenericException: <private>` in `log show` and no
/// DiagnosticReport. `NSApplicationCrashOnExceptions` makes AppKit hand exceptions it would
/// otherwise swallow in the event loop to this handler too.
/// Proof hook: `defaults write com.trungluong.AgentBar AgentBarTestCrash -bool YES` → the next launch
/// clears the key and raises one test exception (the keep-alive relaunches it).
enum CrashLog {
    static let testCrashKey = "AgentBarTestCrash"

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/AgentBar")
    }

    static func install(defaults: UserDefaults = .standard) {
        defaults.register(defaults: ["NSApplicationCrashOnExceptions": true])
        NSSetUncaughtExceptionHandler { exception in
            CrashLog.write(CrashLog.report(name: exception.name.rawValue, reason: exception.reason,
                                           stack: exception.callStackSymbols))
        }
        if defaults.bool(forKey: testCrashKey) {
            defaults.removeObject(forKey: testCrashKey)
            defaults.synchronize()
            DispatchQueue.main.async {
                NSException(name: .genericException, reason: "AgentBarTestCrash: crash-log proof", userInfo: nil).raise()
            }
        }
    }

    static func report(name: String, reason: String?, stack: [String], date: Date = Date()) -> String {
        """
        AgentBar uncaught exception at \(ISO8601DateFormatter().string(from: date))
        name: \(name)
        reason: \(reason ?? "(none)")
        stack:
        \(stack.joined(separator: "\n"))

        """
    }

    @discardableResult
    static func write(_ text: String, to dir: URL = directory, date: Date = Date()) -> URL? {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let url = dir.appendingPathComponent("crash-\(f.string(from: date)).log")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try? Data(text.utf8).write(to: url)) != nil ? url : nil
    }
}
