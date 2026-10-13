import Foundation
import IndieTable

/// The saved views of the Highlights table. The Settings page and the MCP tools both run
/// them through `HighlightsTable`, so "Open threads" means the same list to a person and an
/// agent.
public enum HighlightView: String, CaseIterable, Identifiable, Sendable {
    case all
    case openThreads = "open-threads"
    case byPage = "by-page"
    case byDate = "by-date"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: "All"
        case .openThreads: "Open threads"
        case .byPage: "By page"
        case .byDate: "By date"
        }
    }

    public var summary: String {
        switch self {
        case .all: "Every highlight, newest first."
        case .openThreads: "Highlights whose comment thread is open (not resolved), newest first."
        case .byPage: "Every highlight grouped by site, then by page."
        case .byDate: "Every highlight grouped by the day it was made, newest day first."
        }
    }
}

/// A run of a view: sections in order (one untitled section when the view does not group).
public struct HighlightSection: Hashable, Sendable {
    /// Site and page for By page; the day (`yyyy-MM-dd`) for By date; nil when ungrouped.
    public let title: String?
    public let entries: [HighlightEntry]
}

/// The Highlights table on IndieTable: one row per highlight, and the views as table-core
/// specs. Search is a `contains` on quote, comments, page and URL, ANDed with the view.
public enum HighlightsTable {
    public static let fields: [TableFieldDefinition] = [
        TableFieldDefinition(id: "quote", label: "Quote", type: "text"),
        TableFieldDefinition(id: "comments", label: "Comments", type: "text"),
        TableFieldDefinition(id: "latestComment", label: "Latest comment", type: "text"),
        TableFieldDefinition(id: "commentCount", label: "Comments", type: "number"),
        TableFieldDefinition(id: "page", label: "Page", type: "text"),
        TableFieldDefinition(id: "site", label: "Site", type: "text"),
        TableFieldDefinition(id: "url", label: "URL", type: "text"),
        TableFieldDefinition(id: "color", label: "Color", type: "select", options: ["yellow", "green", "blue", "pink"]),
        TableFieldDefinition(id: "status", label: "Thread", type: "select", options: ["none", "open", "resolved"]),
        TableFieldDefinition(id: "created", label: "Date", type: "date"),
        // The local day, precomputed: table-core groups by value and has no date buckets.
        TableFieldDefinition(id: "day", label: "Day", type: "text"),
    ]

    static let source = TableSource(name: "highlights", fields: fields)

    /// Runs `view` (plus `search`) over `entries`.
    public static func run(
        _ view: HighlightView, search: String = "", entries: [HighlightEntry], calendar: Calendar = .current
    ) throws -> [HighlightSection] {
        let store = try TableStore.inMemory()
        try store.replaceRows(of: source, with: entries.map { row($0, calendar: calendar) })
        let result = try store.run(specJSON: spec(view, search: search), on: source)
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func resolve(_ rows: [TableRow]) -> [HighlightEntry] {
            rows.compactMap { row in
                guard case .text(let id) = row["id"] else { return nil }
                return byID[id]
            }
        }
        guard !result.groups.isEmpty else { return [HighlightSection(title: nil, entries: resolve(result.rows))] }
        return result.groups.flatMap { group -> [HighlightSection] in
            let title = Self.title(of: group.key)
            guard !group.children.isEmpty else { return [HighlightSection(title: title, entries: resolve(group.rows))] }
            return group.children.map { child in
                HighlightSection(title: "\(title) · \(Self.title(of: child.key))", entries: resolve(child.rows))
            }
        }
    }

    static func row(_ entry: HighlightEntry, calendar: Calendar) -> TableRow {
        let h = entry.highlight
        let comments = entry.comments.compactMap(\.text)
        let day = calendar.dateComponents([.year, .month, .day], from: h.createdAt)
        return [
            "id": .text(h.id),
            "quote": .text(h.selectedText),
            "comments": .text(comments.joined(separator: "\n")),
            "latestComment": comments.last.map(TableCellValue.text) ?? .null,
            "commentCount": .integer(Int64(comments.count)),
            "page": .text(h.pageTitle),
            "site": .text(h.site),
            "url": .text(h.articleURL?.absoluteString ?? h.urlKey),
            "color": .text(h.color),
            "status": .text(entry.status),
            "created": .text(ISO8601DateFormatter().string(from: h.createdAt)),
            "day": .text(String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)),
        ]
    }

    static func spec(_ view: HighlightView, search: String) throws -> Data {
        var filters: [[String: Any]] = []
        var groupBy: [[String: Any]] = []
        switch view {
        case .all:
            break
        case .openThreads:
            filters.append(condition("status", "equals", "open"))
        case .byPage:
            groupBy = [level("site", "asc"), level("page", "asc")]
        case .byDate:
            groupBy = [level("day", "desc")]
        }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            filters.append([
                "kind": "group", "combinator": "or",
                "children": ["quote", "comments", "page", "url"].map { condition($0, "contains", query) },
            ])
        }
        var spec: [String: Any] = [
            "specVersion": 1, "viewType": "table",
            "sort": [["fieldId": "created", "direction": "desc"]],
            "tieBreak": "sourceOrder",
        ]
        if !filters.isEmpty { spec["filter"] = ["kind": "group", "combinator": "and", "children": filters] }
        if !groupBy.isEmpty { spec["groupBy"] = groupBy }
        return try JSONSerialization.data(withJSONObject: spec, options: [.sortedKeys])
    }

    private static func condition(_ field: String, _ op: String, _ value: String) -> [String: Any] {
        ["kind": "condition", "fieldId": field, "operator": op, "value": value]
    }

    private static func level(_ field: String, _ direction: String) -> [String: Any] {
        ["fieldId": field, "direction": direction, "collation": "natural"]
    }

    private static func title(of key: TableCellValue) -> String {
        switch key {
        case .text(let text): text
        case .integer(let number): String(number)
        case .real(let number): String(number)
        case .bool(let flag): flag ? "Yes" : "No"
        case .list(let items): items.joined(separator: ", ")
        case .null: "—"
        }
    }
}
