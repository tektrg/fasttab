import FastTabReader
import Foundation
import IndieComments
import IndieMCP

/// Read-only comment-thread tools over the reader mirror, named like MDLY's (list, read).
/// Threads hang off highlights, so `read_thread` takes a `highlight_id`; `list_threads` runs
/// the same saved views as Settings > Highlights. The write tools (create_thread, reply,
/// resolve, reopen) were removed with the reading connector (owner, 2026-11-09): agents read,
/// only the user writes.
struct ReaderCommentTools {
    let library: ReaderLibrary
    static let instructions = """
    list_threads lists highlights in a saved view (all, open-threads, by-page, by-date) with \
    each comment thread's status; read_thread shows one highlight's full thread.
    """

    var tools: [MCPTool] {
        [listThreads, readThread]
    }

    // MARK: - Tools

    private var listThreads: MCPTool {
        MCPTool(
            name: "list_threads", title: "List highlights",
            description: "Highlights in one of the saved views, with each thread's status, comment count and "
                + "latest comment. Views: " + HighlightView.allCases.map { "\($0.rawValue) (\($0.summary))" }
                .joined(separator: "; "),
            inputSchema: schema([
                "view": ["type": "string", "enum": .array(HighlightView.allCases.map { .string($0.rawValue) }),
                         "description": "Default open-threads."],
                "search": ["type": "string", "description": "Words to find in quotes, comments, page titles or URLs."],
                "limit": ["type": "integer", "description": "Most highlights to return (default 50)."],
            ], required: [])
        ) { arguments in
            let viewName = arguments["view"]?.stringValue ?? HighlightView.openThreads.rawValue
            guard let view = HighlightView(rawValue: viewName) else {
                return .failure("Unknown view \(viewName).", outcome: .error, summary: "list_threads: bad view")
            }
            let limit = max(1, arguments["limit"]?.intValue ?? 50)
            do {
                var remaining = limit
                var returned: [HighlightEntry] = []
                let sections = try HighlightsTable.run(
                    view, search: arguments["search"]?.stringValue ?? "", entries: await library.entries())
                let json: [JSONValue] = sections.compactMap { section in
                    let entries = Array(section.entries.prefix(remaining))
                    remaining -= entries.count
                    returned += entries
                    guard !entries.isEmpty else { return nil }
                    return ["title": section.title.map(JSONValue.string) ?? .null,
                            "highlights": .array(entries.map(Self.summary))]
                }
                let total = sections.reduce(0) { $0 + $1.entries.count }
                return .success(
                    ["view": .string(view.rawValue), "total": .int(total), "sections": .array(json)],
                    summary: "list_threads \(view.rawValue): \(returned.count) of \(total)",
                    returnedItems: returned.map(Self.item))
            } catch {
                return .failure("Could not run the view: \(error)", outcome: .error, summary: "list_threads failed")
            }
        }
    }

    private var readThread: MCPTool {
        MCPTool(
            name: "read_thread", title: "Read a thread",
            description: "One highlight with its full comment thread, oldest comment first.",
            inputSchema: schema(["highlight_id": idProperty], required: ["highlight_id"])
        ) { arguments in
            await perform("read_thread", arguments) { id in try await library.entry(id: id) }
        }
    }

    // MARK: - Helpers

    struct ToolError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private var idProperty: JSONValue { ["type": "string", "description": "A highlight id from list_threads."] }

    private func schema(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
        ["type": "object", "properties": .object(properties), "required": .array(required.map(JSONValue.string)),
         "additionalProperties": false]
    }

    private func perform(
        _ name: String, _ arguments: [String: JSONValue], _ action: (String) async throws -> HighlightEntry
    ) async -> MCPToolResult {
        guard let id = arguments["highlight_id"]?.stringValue else {
            return .failure("Missing highlight_id.", outcome: .error, summary: "\(name): no highlight_id")
        }
        do {
            let entry = try await action(id)
            return .success(Self.detail(entry), summary: "\(name) \(id)", returnedItems: [Self.item(entry)])
        } catch {
            return .failure(String(describing: error), outcome: .error, summary: "\(name) \(id) failed")
        }
    }

    static func item(_ entry: HighlightEntry) -> AgentAccessEvent.ReturnedItem {
        .init(id: entry.id, title: String(entry.highlight.selectedText.prefix(80)))
    }

    static func summary(_ entry: HighlightEntry) -> JSONValue {
        let h = entry.highlight
        let comments = entry.comments.compactMap(\.text)
        return [
            "highlight_id": .string(h.id),
            "quote": .string(h.selectedText),
            "page": .string(h.pageTitle),
            "site": .string(h.site),
            "url": .string(h.urlAtHighlight?.absoluteString ?? h.urlKey),
            "color": .string(h.color),
            "thread": .string(entry.status),
            "comment_count": .int(comments.count),
            "latest_comment": comments.last.map(JSONValue.string) ?? .null,
            "created": .string(ISO8601DateFormatter().string(from: h.createdAt)),
        ]
    }

    static func detail(_ entry: HighlightEntry) -> JSONValue {
        guard case .object(var members) = summary(entry) else { return summary(entry) }
        members["comments"] = .array(entry.comments.map { event in
            ["author": .string(event.by.label ?? event.by.id), "author_kind": .string(event.by.kind.rawValue),
             "text": .string(event.text ?? "")]
        })
        return .object(members)
    }
}
