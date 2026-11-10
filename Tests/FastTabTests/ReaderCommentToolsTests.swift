import FastTabSync
import Foundation
import IndieMCP
import Testing
@testable import FastTabMCP
@testable import FastTabReader

/// The MCP comment tools over a seeded mirror, called the way `tools/call` does.
@MainActor
@Suite("Reader comment MCP tools")
struct ReaderCommentToolsTests {
    func makeTools() -> ReaderCommentTools {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-tools-\(UUID().uuidString)")
        let mirror = ReaderMirror(directory: dir)
        let json: [String: Any] = [
            "id": "h1", "urlKey": "https://a.com/x", "selectedText": "plan then act", "color": "blue",
            "serializedRange": #"{"text":"plan then act","start":3,"len":13}"#, "createdAt": 780_000_000.0,
        ]
        mirror.applyRemote(SyncedReaderHighlight(
            id: "h1", urlKey: "https://a.com/x", payload: try! JSONSerialization.data(withJSONObject: json)))
        return ReaderCommentTools(library: ReaderLibrary(directory: dir, comments: mirror.comments))
    }

    func call(_ tools: ReaderCommentTools, _ name: String, _ arguments: [String: JSONValue]) async -> MCPToolResult {
        await tools.tools.first { $0.name == name }!.handler(arguments)
    }

    @Test func onlyReadToolsRemain() {
        let tools = makeTools().tools
        #expect(tools.map(\.name) == ["list_threads", "read_thread"])
        #expect(tools.allSatisfy { $0.readOnly })
    }

    @Test func agentReadsThreadsTheUserWrote() async throws {
        let tools = makeTools()
        #expect(await call(tools, "list_threads", [:]).resultCount == 0, "open-threads is the default and empty")
        try await tools.library.comment("Source?", onHighlight: "h1", by: .init(kind: .human, id: "me", label: "Me"))
        #expect(await call(tools, "list_threads", ["view": "open-threads"]).resultCount == 1)
        let read = await call(tools, "read_thread", ["highlight_id": "h1"])
        #expect(read.structuredContent?["thread"] == "open")
        #expect(read.structuredContent?["url"]?.stringValue?.hasSuffix("#:~:text=plan%20then%20act") == true)

        #expect(await call(tools, "list_threads", ["view": "nope"]).isError)
        #expect(await call(tools, "read_thread", ["highlight_id": "missing"]).isError)
        #expect(await call(tools, "list_threads", ["view": "all"]).resultCount == 1)
    }
}
