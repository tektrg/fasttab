import Foundation

/// What one finished command printed. `exitCode` -1 = it never ran or timed out.
struct ShellCommandResult: Equatable, Sendable {
    var exitCode: Int32
    var stdout: String
    var stderr: String

    var succeeded: Bool { exitCode == 0 }
    /// The first non-empty stderr line, for a footer message.
    var errorLine: String? {
        stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }
}

/// Runs one program with arguments (no shell). Behind a protocol so the tmux/herdr switch is
/// tested with a scripted fake — tests must never run real tmux or herdr.
protocol ShellCommandRunning: Sendable {
    func run(_ executablePath: String, _ arguments: [String]) async -> ShellCommandResult
}

/// The real one: `Process` off the main thread, killed after `timeoutSeconds`.
struct ProcessCommandRunner: ShellCommandRunning {
    var timeoutSeconds: Double = 5

    func run(_ executablePath: String, _ arguments: [String]) async -> ShellCommandResult {
        let timeout = timeoutSeconds
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.runBlocking(executablePath, arguments, timeoutSeconds: timeout))
            }
        }
    }

    private static func runBlocking(_ executablePath: String, _ arguments: [String], timeoutSeconds: Double) -> ShellCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ShellCommandResult(exitCode: -1, stdout: "", stderr: error.localizedDescription)
        }
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: deadline)
        // Read one pipe then the other: the commands run here print little on stderr, and a
        // child stuck on a full pipe is still bounded by the deadline above.
        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        let timedOut = process.terminationReason == .uncaughtSignal
        return ShellCommandResult(
            exitCode: timedOut ? -1 : process.terminationStatus,
            stdout: String(decoding: outputData, as: UTF8.self),
            stderr: timedOut ? "timed out after \(Int(timeoutSeconds))s" : String(decoding: errorData, as: UTF8.self)
        )
    }
}

/// GUI apps start without the login shell's PATH, so command-line tools are looked up in
/// the usual install folders explicitly.
enum ExecutableLocator {
    static let searchDirectories = [
        "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
        NSHomeDirectory() + "/.local/bin", NSHomeDirectory() + "/.cargo/bin"
    ]

    static func locate(
        _ name: String,
        in directories: [String] = searchDirectories,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        directories.map { "\($0)/\(name)" }.first(where: isExecutable)
    }
}
