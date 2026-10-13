import FastTabReader
import Foundation
import IndieComments
import IndieMCP

/// Comment tools over the reader mirror, named like MDLY's (create_thread, reply, resolve,
/// reopen, list, read). Threads hang off highlights, so every tool takes a `highlight_id`;
/// `list_threads` runs the same saved views as Settings > Highlights.
struct ReaderCommentTools {
    let library: ReaderLibrary
    let author = CommentAuthor(kind: .agent, id: "fasttab-mcp", label: "Agent")

    static let instructions = """
    Fast Tab reader highlights from the user's iPhone, each with an optional comment thread. \
    Start with list_threads (view "open-threads" is the work queue), read a thread with \
    read_thread, answer with reply, and resolve it when done. create_thread starts a thread on \
    a highlight that has none. Comments sync back to the iPhone.
    """

    var tools: [MCPTool] {
        [listThreads, readThread, createThread, reply, setResolved(true), setResolved(false)]
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

    private var createThread: MCPTool {
        MCPTool(
            name: "create_thread", title: "Start a thread",
            description: "Starts the comment thread on a highlight that has none. Use reply when it has one.",
            inputSchema: schema(["highlight_id": idProperty, "text": textProperty], required: ["highlight_id", "text"]),
            readOnly: false
        ) { arguments in
            await perform("create_thread", arguments) { id in
                guard try await library.entry(id: id).thread == nil else {
                    throw ToolError("Highlight \(id) already has a thread; use reply.")
                }
                return try await library.comment(try text(arguments), onHighlight: id, by: author)
            }
        }
    }

    private var reply: MCPTool {
        MCPTool(
            name: "reply", title: "Reply",
            description: "Adds a comment to a highlight's thread. Replying to a resolved thread reopens it.",
            inputSchema: schema(["highlight_id": idProperty, "text": textProperty], required: ["highlight_id", "text"]),
            readOnly: false
        ) { arguments in
            await perform("reply", arguments) { id in
                guard try await library.entry(id: id).thread != nil else { throw ReaderLibrary.Failure.noThread(id) }
                return try await library.comment(try text(arguments), onHighlight: id, by: author)
            }
        }
    }

    private func setResolved(_ resolved: Bool) -> MCPTool {
        let name = resolved ? "resolve" : "reopen"
        return MCPTool(
            name: name, title: resolved ? "Resolve" : "Reopen",
            description: resolved ? "Marks a highlight's thread resolved." : "Reopens a resolved thread.",
            inputSchema: schema(["highlight_id": idProperty], required: ["highlight_id"]),
            readOnly: false
        ) { arguments in
            await perform(name, arguments) { id in try await library.setResolved(resolved, onHighlight: id, by: author) }
        }
    }

    // MARK: - Helpers

    struct ToolError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private var idProperty: JSONValue { ["type": "string", "description": "A highlight id from list_threads."] }
    private var textProperty: JSONValue { ["type": "string", "description": "The comment, plain text."] }

    private func schema(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
        ["type": "object", "properties": .object(properties), "required": .array(required.map(JSONValue.string)),
         "additionalProperties": false]
    }

    private func text(_ arguments: [String: JSONValue]) throws -> String {
        guard let text = arguments["text"]?.stringValue else { throw ToolError("Missing text.") }
        return text
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
