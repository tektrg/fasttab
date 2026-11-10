import FastTabSync
import Foundation
import GRDB
import IndieMCP
import Testing
@testable import ReadingConnector

/// Bookmarks + opt-in browser history: fixture browser folders (Chromium JSON + History
/// SQLite, Safari plist), the Settings file, and the window.
@MainActor
@Suite("Reading connector bookmarks + history")
struct ReadingBrowserToolsTests {
    struct Browsers {
        let home: URL
        var data: BrowserData {
            BrowserData(chromium: [.init(name: "Chrome", directory: home.appendingPathComponent("Chrome"))],
                        safariDirectory: home.appendingPathComponent("Safari"))
        }
    }

    func makeBrowsers(visits: [(url: String, title: String, daysAgo: Double)]) throws -> Browsers {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("browsers-\(UUID().uuidString)")
        let profile = home.appendingPathComponent("Chrome/Default")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let bookmarks: [String: Any] = ["roots": [
            "bookmark_bar": ["name": "Bookmarks Bar", "type": "folder", "children": [
                ["name": "Reading", "type": "folder", "children": [
                    ["name": "Agent design notes", "type": "url", "url": "https://notes.example.com/agents",
                     "date_added": "13300000000000000"],
                ]],
                ["name": "Mail", "type": "url", "url": "https://mail.example.com/"],
            ]],
            "other": ["name": "Other Bookmarks", "type": "folder", "children": []],
        ]]
        try JSONSerialization.data(withJSONObject: bookmarks).write(to: profile.appendingPathComponent("Bookmarks"))
        let queue = try DatabaseQueue(path: profile.appendingPathComponent("History").path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE urls (id INTEGER PRIMARY KEY, url TEXT, title TEXT, last_visit_time INTEGER, hidden INTEGER DEFAULT 0)")
            for v in visits {
                try db.execute(sql: "INSERT INTO urls (url, title, last_visit_time) VALUES (?, ?, ?)",
                               arguments: [v.url, v.title, BrowserData.chromiumMicros(ReadingConnectorFixture.daysAgo(v.daysAgo))])
            }
        }
        let safari = home.appendingPathComponent("Safari")
        try FileManager.default.createDirectory(at: safari, withIntermediateDirectories: true)
        let plist: [String: Any] = ["WebBookmarkType": "WebBookmarkTypeList", "Children": [
            ["WebBookmarkType": "WebBookmarkTypeList", "Title": "BookmarksBar", "Children": [
                ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://safari.example.com/essay",
                 "URIDictionary": ["title": "Safari essay"]],
            ]],
        ]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            .write(to: safari.appendingPathComponent("Bookmarks.plist"))
        return Browsers(home: home)
    }

    let visits: [(url: String, title: String, daysAgo: Double)] = [
        ("https://today.example.com/a", "Visited today", 0.1),
        ("https://week.example.com/b", "Visited five days ago", 5),
        ("https://month.example.com/c", "Visited twenty days ago", 20),
        ("https://old.example.com/d", "Visited sixty days ago", 60),
    ]

    func tools(_ f: ReadingConnectorFixture, _ browsers: Browsers, index: Bool = false) throws -> ReadingTools {
        ReadingTools(connector: f.connector, format: ReadingFormat(timeZone: TimeZone(identifier: "UTC")!),
                     index: index ? try ReadingIndex(fileURL: ReadingIndex.fileURL(supportDirectory: f.sources.supportDirectory)) : nil,
                     browser: browsers.data)
    }

    func call(_ t: ReadingTools, _ name: String, _ arguments: [String: JSONValue] = [:]) async -> MCPToolResult {
        guard let tool = t.tools.first(where: { $0.name == name }) else {
            return .failure("absent", outcome: .error, summary: "absent")
        }
        return await tool.handler(arguments)
    }

    @Test func settingsDefaultToHistoryOffAndThirtyDays() throws {
        let f = try ReadingConnectorFixture()
        let settings = ReadingConnectorSettings.load(supportDirectory: f.sources.supportDirectory)
        #expect(settings == ReadingConnectorSettings(historyEnabled: false, historyWindowDays: 30))
        let file = ReadingConnectorSettings.fileURL(supportDirectory: f.sources.supportDirectory)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"historyEnabled":true,"historyWindowDays":365}"#.utf8).write(to: file)
        #expect(ReadingConnectorSettings.load(supportDirectory: f.sources.supportDirectory).historyWindowDays == 30)
    }

    @Test func historyOffMeansToolRefusesAndNoSearchSource() async throws {
        let f = try ReadingConnectorFixture()
        let t = try tools(f, try makeBrowsers(visits: visits), index: true)
        // Always listed: a running agent built its tool list before the user may turn history on.
        #expect(t.tools.contains { $0.name == "history" })
        #expect(t.tools.contains { $0.name == "bookmarks" })
        #expect(!t.indexSources.contains { $0.name == "history" })
        let refused = await call(t, "history")
        #expect(refused.isError && refused.outcome == .refused)
        #expect(refused.text == ReadingTools.historyOffMessage)
        #expect(refused.text == "Browser history is off. Turn it on in FastTab Settings › Highlights › AI agent access.")
        #expect(await call(t, "search", ["query": "visited", "sources": ["history"]]).outcome == .refused)
        let everything = await call(t, "search", ["query": "visited", "format": "json"])
        #expect(!everything.text.contains("\"history\""))
    }

    @Test func historyWindowIsEnforcedInTheQuery() async throws {
        let f = try ReadingConnectorFixture()
        try ReadingConnectorSettings(historyEnabled: true, historyWindowDays: 7).save(supportDirectory: f.sources.supportDirectory)
        let t = try tools(f, try makeBrowsers(visits: visits), index: true)
        #expect(t.tools.contains { $0.name == "history" })
        let json = await call(t, "history", ["since": "90d", "format": "json"])
        guard case .array(let rows)? = json.structuredContent?["visits"] else { Issue.record("no visits"); return }
        #expect(rows.compactMap { $0["title"]?.stringValue } == ["Visited today", "Visited five days ago"],
                "asking for 90 days still stops at the 7-day setting")
        #expect(json.structuredContent?["window_days"] == 7)
        let narrow = await call(t, "history", ["since": "1d", "format": "json"])
        #expect(narrow.structuredContent?["count"] == 1)
        let md = try #require(await call(t, "history").structuredContent?["markdown"]?.stringValue)
        #expect(md.contains("_Window: last 7 days (set by the user)._"))

        // Search sees history inside the window only.
        let found = await call(t, "search", ["query": "visited", "sources": ["history"], "format": "json"])
        guard case .array(let hits)? = found.structuredContent?["hits"] else { Issue.record("no hits"); return }
        #expect(Set(hits.compactMap { $0["title"]?.stringValue }) == ["Visited today", "Visited five days ago"])

        // Turning history off removes it from search at once.
        try ReadingConnectorSettings(historyEnabled: false, historyWindowDays: 7).save(supportDirectory: f.sources.supportDirectory)
        let afterOff = await call(t, "search", ["query": "visited", "format": "json"])
        #expect(!afterOff.text.contains("\"history\""))
        #expect(await t.history.handler([:]).outcome == .refused, "the handler re-checks the setting")
    }

    @Test func turningHistoryOnReachesToolsListedEarlier() async throws {
        let f = try ReadingConnectorFixture()
        let t = try tools(f, try makeBrowsers(visits: visits))
        let listedAtStartup = try #require(t.tools.first { $0.name == "history" })
        #expect(await listedAtStartup.handler([:]).outcome == .refused)
        try ReadingConnectorSettings(historyEnabled: true, historyWindowDays: 7).save(supportDirectory: f.sources.supportDirectory)
        let on = await listedAtStartup.handler(["format": "json"])
        #expect(!on.isError)
        #expect(on.text.contains("today.example.com") && !on.text.contains("month.example.com"))
    }

    @Test func bookmarksFromChromiumAndSafari() async throws {
        let f = try ReadingConnectorFixture()
        let t = try tools(f, try makeBrowsers(visits: []), index: true)
        let all = await call(t, "bookmarks", ["format": "json"])
        guard case .array(let rows)? = all.structuredContent?["bookmarks"] else { Issue.record("none"); return }
        #expect(Set(rows.compactMap { $0["title"]?.stringValue }) == ["Agent design notes", "Mail", "Safari essay"])
        let agents = try #require(rows.first { $0["title"] == "Agent design notes" })
        #expect(agents["folder"] == "Bookmarks Bar/Reading")
        #expect(agents["browser"] == "Chrome")
        #expect(rows.first { $0["title"] == "Safari essay" }?["folder"] == "Favorites")
        #expect(await call(t, "bookmarks", ["folder": "reading", "format": "json"]).structuredContent?["count"] == 1)
        let md = try #require(await call(t, "bookmarks", ["query": "agent"]).structuredContent?["markdown"]?.stringValue)
        #expect(md.contains("- **Agent design notes** · Chrome · Bookmarks Bar/Reading · <https://notes.example.com/agents>"))
        let hit = await call(t, "search", ["query": "design", "format": "json"])
        #expect(hit.structuredContent?["hits"]?[0]?["source"] == "bookmarks")
        let cli = await ReadingCLI(tools: t.tools).run(["bookmarks", "agent"])
        #expect(cli.text == md)
    }
}
