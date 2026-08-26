import Foundation
import OSLog

// ASCII control characters guaranteed not to appear in URLs or page titles.
let kFieldSep = "\u{1F}" // unit separator
let kRowSep   = "\u{1C}" // file separator

/// SQLite `busy_timeout` (ms) for read-only queries against a browser's *live*
/// History DB. Kept deliberately small so a query that hits a write lock (the
/// browser is actively writing) fails fast and falls back to a copy instead of
/// holding a thread for seconds. A multi-second wait here starves the shared
/// task pool and delays the live-tab fetch the user is actually waiting on —
/// history must never block tabs. See `runProcess` cancellation handling.
let kSQLiteLiveReadBusyTimeoutMs = 200

func appleScriptQuoted(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Percent-encodes a value for use as a single query-string parameter (e.g.
/// the `q=` in a search URL). `.urlQueryAllowed` alone isn't safe here — it
/// leaves structural characters like `&`, `+`, and `=` unescaped, so a query
/// containing one of those would be truncated or split into extra params by
/// the receiving server. Only RFC 3986 "unreserved" characters pass through.
func webSearchQueryEncoded(_ value: String) -> String {
    let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
}

/// Percent-encodes an absolute filesystem path for embedding in a SQLite
/// `file:` URI (e.g. `file:<encoded>?mode=ro`). `?` and `#` must be encoded
/// because SQLite splits the URI on them; spaces and other path characters are
/// handled by `urlPathAllowed`. Used by the read-only DB open paths in both the
/// Chromium and Safari backends.
func sqliteFileURIPath(_ dbPath: String) -> String {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "?#")
    return dbPath.addingPercentEncoding(withAllowedCharacters: allowed) ?? dbPath
}

public enum TabCloseResult: Sendable, Equatable {
    case closed
    case notFound
    case refused(String)
}

/// What a successful `removeBookmarkForMove` recovers from the node it just
/// deleted — enough to recreate it elsewhere, or to put it back verbatim if
/// the destination write fails.
struct RemovedBookmarkNode: Sendable, Equatable {
    let title: String
    let url: String
    let dateAdded: Date?
    /// Ordered folder display names the node was removed from, e.g.
    /// ["Bookmark Bar", "Work"]. Empty means it was at the profile's top level.
    let originalFolderPath: [String]
}

/// Builds `sqlite3` arguments for a read-only query against a *live* Chromium
/// profile database (History, Web Data, ...), using SQLite's `immutable=1` URI
/// flag.
///
/// Chromium opens these with `PRAGMA locking_mode=EXCLUSIVE`, so a plain
/// `-readonly` open is rejected with `SQLITE_BUSY (database is locked)` even
/// though the file is on disk. `immutable=1` tells SQLite to assume the file
/// won't change and skip all locking, which lets us read the latest
/// checkpointed state while the browser keeps writing. We never open for
/// write, so there's no risk of corrupting the browser's DB.
///
/// Earlier attempts that did not work: (a) byte-level `copyItem` + query —
/// captured stale pages because the `-journal` sidecar wasn't copied
/// alongside, and (b) `-readonly` direct open — failed with `SQLITE_BUSY`
/// against Chromium's exclusive lock. `immutable=1` is the approach Chrome's
/// own history-export tooling uses.
func immutableReadSQLiteArgs(dbPath: String, sql: String) -> [String] {
    [
        "-cmd", ".timeout \(kSQLiteLiveReadBusyTimeoutMs)",
        "-separator", kFieldSep,
        "file:\(sqliteFileURIPath(dbPath))?immutable=1",
        sql
    ]
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
    /// Budget-aware history search. Callers use this when a user-visible search
    /// should stop widening quickly instead of waiting on the backend default.
    func searchHistory(
        query: String,
        limit: Int,
        since: Date?,
        before: Date?,
        timeoutSeconds: TimeInterval
    ) -> [BrowserSearchResult]
    func fetchFaviconData(pageURL: String) -> Data?
    /// Batched favicon resolution: returns `[pageURL: imageData]` for every URL
    /// that resolved. Default impl loops `fetchFaviconData`; backends that
    /// can amortize per-URL cost (DB copy + sqlite3 fork) should override.
    func fetchFaviconsBatch(pageURLs: [String]) -> [String: Data]

    func activateTab(_ result: BrowserSearchResult)
    func closeTab(_ result: BrowserSearchResult)
    func closeTabWithResult(_ result: BrowserSearchResult, allowPositionalFallback: Bool) -> TabCloseResult
    /// Sets the tab's muted state. Only `ExtensionBackedBackend` can act on
    /// this (Chrome exposes no scriptable mute via AppleScript); every other
    /// backend keeps the default no-op below.
    func toggleMuteTab(_ result: BrowserSearchResult, muted: Bool)
    func openURL(_ result: BrowserSearchResult)
    /// Opens `result` inside `app`'s installed-web-app window, reusing it if
    /// already open. Only meaningful for Chromium-family backends — other
    /// backends fall back to `openURL` via the default implementation below.
    func openInInstalledWebApp(_ result: BrowserSearchResult, app: InstalledWebApp)
    func deleteBookmark(_ result: BrowserSearchResult)
    func deleteHistoryItem(_ result: BrowserSearchResult)
    /// Removes a bookmark and hands back what it takes to recreate it
    /// elsewhere. Only `ChromiumBackend` can actually write bookmarks — every
    /// other backend keeps the default no-op below.
    func removeBookmarkForMove(_ result: BrowserSearchResult) -> RemovedBookmarkNode?
    /// Writes a brand-new bookmark into `profileName` at `folderPath` (see
    /// `RemovedBookmarkNode.originalFolderPath` for the path convention).
    /// Returns whether it actually landed.
    func insertBookmark(title: String, url: String, dateAdded: Date?, profileName: String, folderPath: [String]) -> Bool
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

    func searchHistory(
        query: String,
        limit: Int,
        since: Date?,
        before: Date?,
        timeoutSeconds: TimeInterval
    ) -> [BrowserSearchResult] {
        searchHistory(query: query, limit: limit, since: since, before: before)
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

    func openInInstalledWebApp(_ result: BrowserSearchResult, app: InstalledWebApp) {
        openURL(result)
    }

    func closeTab(_ result: BrowserSearchResult) {
        _ = closeTabWithResult(result, allowPositionalFallback: true)
    }

    func closeTabWithResult(_ result: BrowserSearchResult, allowPositionalFallback: Bool) -> TabCloseResult {
        return .notFound
    }

    func toggleMuteTab(_ result: BrowserSearchResult, muted: Bool) {}

    func removeBookmarkForMove(_ result: BrowserSearchResult) -> RemovedBookmarkNode? { nil }
    func insertBookmark(title: String, url: String, dateAdded: Date?, profileName: String, folderPath: [String]) -> Bool { false }
}

// MARK: - Shared helpers

/// Runs an AppleScript via `osascript` with a bounded wait. Without a timeout,
/// a stuck `tell application "Finder"` (TCC prompt, sleeping NAS alias, modal
/// save dialog) would park the calling thread forever. Callers should also
/// dispatch this off the main thread — see `BrowserTabService.remove/activate`.
func runAppleScript(_ script: String, logger: Logger, action: String, timeoutSeconds: TimeInterval = 8) {
    let task = Process()
    task.launchPath = "/usr/bin/osascript"
    task.arguments = ["-e", script]
    do {
        try task.run()

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while task.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if task.isRunning {
            task.terminate()
            logger.error("\(action, privacy: .public): osascript timeout after \(timeoutSeconds)s")
            return
        }

        if task.terminationStatus != 0 {
            logger.error("\(action, privacy: .public): osascript exited with status \(task.terminationStatus)")
        }
    } catch {
        logger.error("\(action, privacy: .public): failed to run osascript: \(String(describing: error), privacy: .public)")
    }
}

/// Drains one end of a `Pipe` on a background thread so the child process never
/// blocks writing into a full (64KB) pipe buffer. `data` is valid only after
/// `waitUntilDrained()` returns — which happens once the child exits and closes
/// its write end (EOF). Reading with the process still running, or reading the
/// pipe only *after* the child exits (the naive pattern), deadlocks any child
/// that emits more than one buffer's worth of output — e.g. a browser with a
/// few hundred open tabs.
private final class PipeDrain: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let finished = DispatchSemaphore(value: 0)

    init(_ handle: FileHandle, on queue: DispatchQueue) {
        queue.async { [self] in
            // `defer` guarantees the semaphore is always signalled — even if the
            // read bails out — so `waitUntilDrained()` can never block forever.
            defer { finished.signal() }
            let drained = handle.readDataToEndOfFile()
            lock.lock()
            buffer = drained
            lock.unlock()
        }
    }

    func waitUntilDrained() {
        finished.wait()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}

/// Shared background queue for concurrent pipe draining across all `runProcess`
/// calls. Concurrent so several subprocesses (parallel browser fan-out) can each
/// drain both of their pipes without serializing behind one another.
private let pipeDrainQueue = DispatchQueue(label: "com.trungluong.FastTab.pipe-drain", attributes: .concurrent)

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

        // Drain both pipes concurrently while the child runs so it never blocks
        // on a full pipe buffer. Without this a browser with a few hundred tabs
        // overflows the 64KB buffer, the child stalls on write(), we time out,
        // and the user gets an empty result.
        let stdoutDrain = PipeDrain(stdoutPipe.fileHandleForReading, on: pipeDrainQueue)
        let stderrDrain = PipeDrain(stderrPipe.fileHandleForReading, on: pipeDrainQueue)

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while task.isRunning && Date() < deadline {
            // Abandon the moment the owning task is cancelled (e.g. the user
            // typed another character, superseding this search). Without this
            // the busy-wait would pin a cooperative-pool thread until the
            // process exits on its own, starving the live-tab fetch behind it.
            if Task.isCancelled {
                task.terminate()
                return nil
            }
            Thread.sleep(forTimeInterval: 0.02)
        }

        if task.isRunning {
            task.terminate()
            logger.error("runProcess timeout. launchPath='\(launchPath, privacy: .public)' timeoutSeconds=\(timeoutSeconds)")
            return nil
        }

        // The child has exited and closed its write ends, so both drains reach
        // EOF and complete promptly.
        stdoutDrain.waitUntilDrained()
        stderrDrain.waitUntilDrained()

        guard task.terminationStatus == 0 else {
            let stderrText = String(data: stderrDrain.data, encoding: .utf8) ?? ""
            logger.error("runProcess failed. launchPath='\(launchPath, privacy: .public)' status=\(task.terminationStatus) stderr='\(stderrText, privacy: .public)'")
            return nil
        }

        return String(data: stdoutDrain.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
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
