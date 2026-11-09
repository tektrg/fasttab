import Foundation
import IndieMCP

/// Bookmarks (always) and browser history (only when the user allows it) as tools and as
/// search sources.
extension ReadingTools {
    var bookmarks: MCPTool {
        MCPTool(
            name: "bookmarks", title: "Bookmarks",
            description: "The user's browser bookmarks (Chrome, Edge, Brave, Safari): title, URL, folder, browser. "
                + "Filter by folder name and/or words in the title or URL.",
            inputSchema: Self.schema([
                "folder": ["type": "string", "description": "Only bookmarks in a folder whose path contains this."],
                "query": ["type": "string", "description": "Words that must all appear in the title or URL."],
                "limit": ["type": "integer", "description": "Most bookmarks to return (default 100)."],
                "format": Self.formatProperty,
            ])
        ) { arguments in
            guard let browser else { return .failure("Bookmarks are not available.", outcome: .error, summary: "bookmarks") }
            let words = ReadingConnector.words(arguments["query"]?.stringValue)
            let folder = arguments["folder"]?.stringValue.map(ReadingConnector.fold)
            let read = browser.bookmarks()
            let matches = read.bookmarks.filter { b in
                (folder.map { ReadingConnector.fold(b.folder).contains($0) } ?? true)
                    && (words.isEmpty || ReadingConnector.contains(words, in: b.title + "\n" + b.url))
            }
            let shown = Array(matches.prefix(max(1, arguments["limit"]?.intValue ?? 100)))
            return respond(
                arguments,
                markdown: { format.bookmarksMarkdown(shown, total: matches.count, unavailable: read.unavailable) },
                json: { ["count": .int(shown.count), "total": .int(matches.count),
                         "bookmarks": .array(shown.map(format.json)),
                         "unavailable": .array(read.unavailable.map(JSONValue.string))] },
                summary: "bookmarks" + (arguments["query"]?.stringValue.map { " \"\($0)\"" } ?? ""),
                items: shown.map { .init(id: $0.url, title: String($0.title.prefix(80))) })
        }
    }

    var history: MCPTool {
        let window = settings().historyWindowDays
        return MCPTool(
            name: "history", title: "Browser history",
            description: "Pages the user visited in their browsers (one row per page, latest visit), newest first. "
                + "Only the last \(window) day\(window == 1 ? "" : "s") are available (the user's setting).",
            inputSchema: Self.schema([
                "since": Self.sinceProperty,
                "query": ["type": "string", "description": "Words that must all appear in the title or URL."],
                "limit": ["type": "integer", "description": "Most visits to return (default 100)."],
                "format": Self.formatProperty,
            ])
        ) { arguments in
            let settings = settings()
            guard let browser, settings.historyEnabled else {
                return .failure("Browser history is turned off in Fast Tab Settings › Highlights › AI agent access.",
                                outcome: .refused, summary: "history: off")
            }
            let requested: Date?
            do { requested = try parseSince(arguments) } catch { return Self.failure(error, "history") }
            let cutoff = settings.historyCutoff(now: connector.now())
            let since = max(requested ?? cutoff, cutoff)
            let words = ReadingConnector.words(arguments["query"]?.stringValue)
            let limit = max(1, arguments["limit"]?.intValue ?? 100)
            let read = browser.history(since: since, limit: words.isEmpty ? limit : 5_000)
            let visits = Array(read.visits
                .filter { words.isEmpty || ReadingConnector.contains(words, in: $0.title + "\n" + $0.url) }
                .prefix(limit))
            return respond(
                arguments,
                markdown: { format.historyMarkdown(visits, since: since, windowDays: settings.historyWindowDays,
                                                   unavailable: read.unavailable) },
                json: { ["count": .int(visits.count), "since": format.date(since),
                         "window_days": .int(settings.historyWindowDays),
                         "visits": .array(visits.map(format.json)),
                         "unavailable": .array(read.unavailable.map(JSONValue.string))] },
                summary: "history since \(format.day(since))",
                items: visits.map { .init(id: $0.url, title: String($0.title.prefix(80))) })
        }
    }

    /// Bookmarks always; history only while allowed, and only inside the window.
    func browserIndexSources(_ settings: ReadingConnectorSettings) -> [IndexSource] {
        guard let browser else { return [] }
        var sources = [IndexSource(
            name: "bookmarks",
            signature: { IndexSource.fileSignature(browser.bookmarkFiles) },
            documents: {
                browser.bookmarks().bookmarks.enumerated().map { i, b in
                    IndexDocument(source: "bookmarks", id: "\(b.browser)#\(i)", url: b.url, title: b.title,
                                  body: [b.url, b.folder].joined(separator: " "), boost: 0.25, date: b.addedAt)
                }
            })]
        if settings.historyEnabled {
            let now = connector.now()
            let cutoff = settings.historyCutoff(now: now)
            // The day is part of the signature, so the window slides even when no file changed.
            let day = Int(now.timeIntervalSince1970 / 86_400)
            sources.append(IndexSource(
                name: "history",
                signature: { "\(settings.historyWindowDays)d@\(day)|" + IndexSource.fileSignature(browser.historyFiles) },
                documents: {
                    browser.history(since: cutoff, limit: 20_000).visits.map { v in
                        IndexDocument(source: "history", id: v.url, url: v.url, title: v.title, body: v.url,
                                      boost: 0, date: v.visitedAt)
                    }
                }))
        }
        return sources
    }
}
