import Foundation

/// The file that tells the Pro's keep-alive (`scripts/agentbar-keepalive.sh`) "the user quit
/// AgentBar on purpose — don't relaunch it". Written on a normal quit (menu Quit, `quit app`,
/// logout), removed on every launch. A crash, `kill`, or a deploy's stop never runs
/// `applicationWillTerminate`, so it leaves no marker and the keep-alive brings the app back.
/// The path is shared with the shell script: change both together.
struct CleanQuitMarker {
    let url: URL

    static let standard = CleanQuitMarker(directory: FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AgentBar", isDirectory: true))

    init(directory: URL) { url = directory.appendingPathComponent("clean-quit") }

    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    func markLaunched() { try? FileManager.default.removeItem(at: url) }

    func markCleanQuit(at date: Date = Date()) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("\(ISO8601DateFormatter().string(from: date))\n".utf8).write(to: url)
    }
}
