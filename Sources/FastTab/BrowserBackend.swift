import Foundation
import OSLog

// ASCII control characters guaranteed not to appear in URLs or page titles.
let kFieldSep = "\u{1F}" // unit separator
let kRowSep   = "\u{1C}" // file separator

func appleScriptQuoted(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Protocol implemented by each browser backend (Chromium, Safari, ...).
///
/// Conformers must be `Sendable` and have only value semantics / nonisolated
/// methods so they can be invoked from `Task.detached` contexts the same way
/// the original Chromium static helpers were.
protocol BrowserBackend: Sendable {
    var appName: String { get }
    var bundleIdentifier: String { get }

    func fetchLiveTabs(
        fetchStart: Date,
        activeTimes: inout [String: Date],
        currentFlowSourceAppBundleIdentifier: String?
    ) -> [BrowserSearchResult]

    /// Lightweight poll: returns the recency key for the active tab of each window.
    /// Used by the 10s background poll to keep `lastActiveTimes` fresh without
    /// running the full per-tab AppleScript scan. No-op when the browser isn't running.
    func pollActiveTabKeys() -> [String]

    func fetchAllBookmarks() -> [BrowserSearchResult]
    func fetchRecentHistory(perBrowserLimit: Int) -> [BrowserSearchResult]
    func searchHistory(query: String, limit: Int) -> [BrowserSearchResult]
    /// Same as `searchHistory(query:limit:)` but bounded by `[since, before)`
    /// in the SQL itself. Either bound may be nil for open-ended.
    func searchHistory(query: String, limit: Int, since: Date?, before: Date?) -> [BrowserSearchResult]
    func fetchFaviconData(pageURL: String) -> Data?
    /// Batched favicon resolution: returns `[pageURL: imageData]` for every URL
    /// that resolved. Default impl loops `fetchFaviconData`; backends that
    /// can amortize per-URL cost (DB copy + sqlite3 fork) should override.
    func fetchFaviconsBatch(pageURLs: [String]) -> [String: Data]

    func activateTab(_ result: BrowserSearchResult)
    func closeTab(_ result: BrowserSearchResult)
    func openURL(_ result: BrowserSearchResult)
    func deleteBookmark(_ result: BrowserSearchResult)
    func deleteHistoryItem(_ result: BrowserSearchResult)
}

extension BrowserBackend {
    /// Default forwards to the time-unbounded variant; concrete backends that
    /// can push time predicates into SQL should override.
    func searchHistory(query: String, limit: Int, since: Date?, before: Date?) -> [BrowserSearchResult] {
        let raw = searchHistory(query: query, limit: limit)
        guard since != nil || before != nil else { return raw }
        return raw.filter { result in
            if let since, result.timestamp < since { return false }
            if let before, result.timestamp >= before { return false }
            return true
        }
    }

    func fetchFaviconsBatch(pageURLs: [String]) -> [String: Data] {
        var out: [String: Data] = [:]
        for url in pageURLs {
            if let data = fetchFaviconData(pageURL: url) {
                out[url] = data
            }
        }
        return out
    }
}

// MARK: - Shared helpers

func runAppleScript(_ script: String, logger: Logger, action: String) {
    let task = Process()
    task.launchPath = "/usr/bin/osascript"
    task.arguments = ["-e", script]
    do {
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            logger.error("\(action, privacy: .public): osascript exited with status \(task.terminationStatus)")
        }
    } catch {
        logger.error("\(action, privacy: .public): failed to run osascript: \(String(describing: error), privacy: .public)")
    }
}

func runProcess(launchPath: String, arguments: [String], timeoutSeconds: TimeInterval = 4) -> String? {
    let logger = Logger(subsystem: "com.trungluong.FastTab", category: "BrowserBackend")
    let task = Process()
    task.launchPath = launchPath
    task.arguments = arguments

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    task.standardOutput = stdoutPipe
    task.standardError = stderrPipe

    do {
        try task.run()

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while task.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if task.isRunning {
            task.terminate()
            logger.error("runProcess timeout. launchPath='\(launchPath, privacy: .public)' timeoutSeconds=\(timeoutSeconds)")
            return nil
        }

        guard task.terminationStatus == 0 else {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
            logger.error("runProcess failed. launchPath='\(launchPath, privacy: .public)' status=\(task.terminationStatus) stderr='\(stderrText, privacy: .public)'")
            return nil
        }

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
        logger.error("runProcess threw. launchPath='\(launchPath, privacy: .public)' error='\(String(describing: error), privacy: .public)'")
        return nil
    }
}

func dataFromHex(_ hex: String) -> Data? {
    let compact = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !compact.isEmpty, compact.count.isMultiple(of: 2) else { return nil }

    var data = Data(capacity: compact.count / 2)
    var index = compact.startIndex

    while index < compact.endIndex {
        let next = compact.index(index, offsetBy: 2)
        let byteString = compact[index..<next]
        guard let byte = UInt8(byteString, radix: 16) else { return nil }
        data.append(byte)
        index = next
    }

    return data
}
