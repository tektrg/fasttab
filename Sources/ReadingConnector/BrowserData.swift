import Foundation
import GRDB

/// The user's choices for agent access, set in FastTab Settings › Highlights › AI agent access
/// and read by the helper on every call. A small JSON file beside the connector's other data,
/// so the app and the helper (another process) never disagree about the defaults.
public struct ReadingConnectorSettings: Codable, Equatable, Sendable {
    public static let historyWindowChoices = [1, 7, 30]
    public static let defaultHistoryWindowDays = 30

    /// Browser history is off until the user turns it on.
    public var historyEnabled: Bool = false
    /// How far back agents may see history (1, 7 or 30 days). Enforced in the query.
    public var historyWindowDays: Int = ReadingConnectorSettings.defaultHistoryWindowDays

    public init(historyEnabled: Bool = false, historyWindowDays: Int = ReadingConnectorSettings.defaultHistoryWindowDays) {
        self.historyEnabled = historyEnabled
        self.historyWindowDays = historyWindowDays
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        historyEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .historyEnabled)) ?? false
        let days = (try? c.decodeIfPresent(Int.self, forKey: .historyWindowDays)) ?? Self.defaultHistoryWindowDays
        historyWindowDays = Self.historyWindowChoices.contains(days) ? days : Self.defaultHistoryWindowDays
    }

    public static func fileURL(supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent("ReadingConnector", isDirectory: true).appendingPathComponent("settings.json")
    }

    /// Defaults (history off) when the file is missing or unreadable.
    public static func load(supportDirectory: URL) -> ReadingConnectorSettings {
        (try? Data(contentsOf: fileURL(supportDirectory: supportDirectory)))
            .flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? ReadingConnectorSettings()
    }

    public func save(supportDirectory: URL) throws {
        let url = Self.fileURL(supportDirectory: supportDirectory)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    /// The oldest visit agents may see.
    public func historyCutoff(now: Date) -> Date {
        now.addingTimeInterval(-Double(historyWindowDays) * 86_400)
    }

    /// Where every agent call is logged (IndieMCP `AgentAccessLog`), shown in the same section.
    public static func accessLogURL(supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent("ReadingConnector", isDirectory: true).appendingPathComponent("agent-access.sqlite")
    }

    /// Darwin notification the helper posts after logging a call.
    public static let accessLogNotification = "app.theindie.FastTab.agentAccessLogChanged"
}

public struct BrowserBookmark: Hashable, Sendable {
    public let title: String
    public let url: String
    /// Folder trail, e.g. "Bookmarks Bar/Reading".
    public let folder: String
    /// "Chrome", "Chrome (Profile 1)", "Safari", ...
    public let browser: String
    public let addedAt: Date?
}

public struct BrowserVisit: Hashable, Sendable {
    public let title: String
    public let url: String
    public let visitedAt: Date
    public let browser: String
}

/// Reads browser bookmarks and history straight from the browsers' own files (read-only;
/// history databases are copied first, as Chrome keeps them locked). Safari needs Full Disk
/// Access for the process; without it Safari is skipped and listed in `unavailable`.
public struct BrowserData: Sendable {
    public struct ChromiumBrowser: Sendable {
        public let name: String
        public let directory: URL
        public init(name: String, directory: URL) {
            self.name = name
            self.directory = directory
        }
    }

    public let chromium: [ChromiumBrowser]
    public let safariDirectory: URL?

    public init(chromium: [ChromiumBrowser], safariDirectory: URL?) {
        self.chromium = chromium
        self.safariDirectory = safariDirectory
    }

    /// Chrome, Edge, Brave and Safari in the user's Library (same browsers the app reads).
    public static func standard(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> BrowserData {
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        return BrowserData(
            chromium: [
                ChromiumBrowser(name: "Chrome", directory: support.appendingPathComponent("Google/Chrome")),
                ChromiumBrowser(name: "Edge", directory: support.appendingPathComponent("Microsoft Edge")),
                ChromiumBrowser(name: "Brave", directory: support.appendingPathComponent("BraveSoftware/Brave-Browser")),
            ],
            safariDirectory: home.appendingPathComponent("Library/Safari", isDirectory: true))
    }

    /// (label, profile folder) for every Chromium profile that has the file.
    func profiles(containing file: String) -> [(label: String, directory: URL)] {
        chromium.flatMap { browser -> [(label: String, directory: URL)] in
            let children = (try? FileManager.default.contentsOfDirectory(
                at: browser.directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            return children
                .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent(file).path) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .map { (label: $0.lastPathComponent == "Default" ? browser.name : "\(browser.name) (\($0.lastPathComponent))",
                        directory: $0) }
        }
    }

    /// Files whose change means bookmarks changed (for the search index).
    public var bookmarkFiles: [URL] {
        profiles(containing: "Bookmarks").map { $0.directory.appendingPathComponent("Bookmarks") }
            + (safariDirectory.map { [$0.appendingPathComponent("Bookmarks.plist")] } ?? [])
    }

    public var historyFiles: [URL] {
        profiles(containing: "History").map { $0.directory.appendingPathComponent("History") }
            + (safariDirectory.map { [$0.appendingPathComponent("History.db")] } ?? [])
    }

    // MARK: - Bookmarks

    public func bookmarks() -> (bookmarks: [BrowserBookmark], unavailable: [String]) {
        var result: [BrowserBookmark] = []
        var unavailable: [String] = []
        for profile in profiles(containing: "Bookmarks") {
            guard let data = try? Data(contentsOf: profile.directory.appendingPathComponent("Bookmarks")),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let roots = json["roots"] as? [String: Any] else {
                unavailable.append(profile.label)
                continue
            }
            for key in ["bookmark_bar", "other", "synced"] {
                guard let root = roots[key] as? [String: Any] else { continue }
                Self.collectChromium(root, trail: [], browser: profile.label, into: &result)
            }
        }
        if let safari = safariDirectory?.appendingPathComponent("Bookmarks.plist"),
           FileManager.default.fileExists(atPath: safari.path) {
            if let data = try? Data(contentsOf: safari),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                Self.collectSafari(plist, trail: [], into: &result)
            } else {
                unavailable.append("Safari (needs Full Disk Access)")
            }
        }
        return (result, unavailable)
    }

    static func collectChromium(_ node: [String: Any], trail: [String], browser: String, into result: inout [BrowserBookmark]) {
        let name = node["name"] as? String ?? ""
        if node["type"] as? String == "url", let url = node["url"] as? String {
            result.append(BrowserBookmark(title: name.isEmpty ? url : name, url: url, folder: trail.joined(separator: "/"),
                                          browser: browser, addedAt: (node["date_added"] as? String).flatMap(chromiumDate)))
            return
        }
        for child in node["children"] as? [[String: Any]] ?? [] {
            collectChromium(child, trail: name.isEmpty ? trail : trail + [name], browser: browser, into: &result)
        }
    }

    static func collectSafari(_ node: [String: Any], trail: [String], into result: inout [BrowserBookmark]) {
        let type = node["WebBookmarkType"] as? String
        if type == "WebBookmarkTypeLeaf", let url = node["URLString"] as? String {
            let title = (node["URIDictionary"] as? [String: Any])?["title"] as? String ?? url
            result.append(BrowserBookmark(title: title, url: url, folder: trail.joined(separator: "/"), browser: "Safari", addedAt: nil))
            return
        }
        let names = ["BookmarksBar": "Favorites", "BookmarksMenu": "Bookmarks Menu", "com.apple.ReadingList": "Reading List"]
        let title = node["Title"] as? String ?? ""
        let nextTrail = title.isEmpty ? trail : trail + [names[title] ?? title]
        for child in node["Children"] as? [[String: Any]] ?? [] {
            collectSafari(child, trail: nextTrail, into: &result)
        }
    }

    // MARK: - History

    /// Visits at or after `since`, newest first, one row per page (its latest visit).
    public func history(since: Date, limit: Int) -> (visits: [BrowserVisit], unavailable: [String]) {
        var visits: [BrowserVisit] = []
        var unavailable: [String] = []
        for profile in profiles(containing: "History") {
            let rows = Self.copiedQuery(profile.directory.appendingPathComponent("History"), sql: """
                SELECT url, title, last_visit_time AS t FROM urls
                WHERE last_visit_time >= ? AND hidden = 0 ORDER BY last_visit_time DESC LIMIT ?
                """, arguments: [Self.chromiumMicros(since), limit])
            guard let rows else { unavailable.append(profile.label); continue }
            visits += rows.compactMap { row in
                guard let url = Self.string(row, "url"), let micros = Int64.fromDatabaseValue(row["t"] as DatabaseValue)
                else { return nil }
                let title = Self.string(row, "title") ?? ""
                return BrowserVisit(title: title.isEmpty ? url : title, url: url,
                                    visitedAt: Self.chromiumDate(micros: micros), browser: profile.label)
            }
        }
        if let safari = safariDirectory?.appendingPathComponent("History.db"), FileManager.default.fileExists(atPath: safari.path) {
            let rows = Self.copiedQuery(safari, sql: """
                SELECT hi.url AS url, COALESCE(hv.title, hi.url) AS title, MAX(hv.visit_time) AS t
                FROM history_items hi JOIN history_visits hv ON hv.history_item = hi.id
                WHERE hv.visit_time >= ? GROUP BY hi.id ORDER BY t DESC LIMIT ?
                """, arguments: [since.timeIntervalSinceReferenceDate, limit])
            if let rows {
                visits += rows.compactMap { row in
                    guard let url = Self.string(row, "url"), let t = Double.fromDatabaseValue(row["t"] as DatabaseValue)
                    else { return nil }
                    return BrowserVisit(title: Self.string(row, "title") ?? url, url: url,
                                        visitedAt: Date(timeIntervalSinceReferenceDate: t), browser: "Safari")
                }
            } else {
                unavailable.append("Safari (needs Full Disk Access)")
            }
        }
        // The window again, on the merged rows: never trust a browser's clock column alone.
        let inWindow = visits.filter { $0.visitedAt >= since }.sorted { $0.visitedAt > $1.visitedAt }
        return (Array(inWindow.prefix(max(1, limit))), unavailable)
    }

    /// A text column, or nil for NULL / another type (a malformed row is skipped, never a crash).
    static func string(_ row: Row, _ column: String) -> String? {
        String.fromDatabaseValue(row[column] as DatabaseValue)
    }

    /// Copies the database (and its -wal / -journal) to a temp folder and queries the copy.
    static func copiedQuery(_ database: URL, sql: String, arguments: StatementArguments) -> [Row]? {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("fasttab-history-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: folder) }
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let copy = folder.appendingPathComponent(database.lastPathComponent)
            try fm.copyItem(at: database, to: copy)
            for suffix in ["-wal", "-journal"] {
                let side = URL(fileURLWithPath: database.path + suffix)
                if fm.fileExists(atPath: side.path) { try? fm.copyItem(at: side, to: URL(fileURLWithPath: copy.path + suffix)) }
            }
            let queue = try DatabaseQueue(path: copy.path)
            return try queue.read { db in try Row.fetchAll(db, sql: sql, arguments: arguments) }
        } catch {
            return nil
        }
    }

    /// Chromium times: microseconds since 1601-01-01 UTC.
    static let chromiumEpochOffset: Double = 11_644_473_600

    static func chromiumMicros(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 + chromiumEpochOffset) * 1_000_000)
    }

    static func chromiumDate(micros: Int64) -> Date {
        Date(timeIntervalSince1970: Double(micros) / 1_000_000 - chromiumEpochOffset)
    }

    static func chromiumDate(_ text: String) -> Date? {
        Int64(text).flatMap { $0 > 0 ? chromiumDate(micros: $0) : nil }
    }
}
