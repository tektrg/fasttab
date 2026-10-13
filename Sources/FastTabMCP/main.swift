import FastTabReader
import Foundation
import IndieMCP

// fasttab-mcp: Fast Tab's reader comment tools over MCP (stdio). An agent client (Claude Code,
// Claude Desktop, ...) starts it from FastTab.app/Contents/MacOS/. It reads and writes the
// reader mirror the app keeps; the app syncs those comments to the iPhone on its next tick.
// Works while Fast Tab is closed (writes then wait for the next launch). Never listens on a
// network.

/// The app's reader mirror; `FASTTAB_READER_DIR` overrides it (tests, a second profile).
let directory: URL = {
    if let override = ProcessInfo.processInfo.environment["FASTTAB_READER_DIR"], !override.isEmpty {
        return URL(fileURLWithPath: override, isDirectory: true)
    }
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return ReaderMirror.directory(supportDirectory: support.appendingPathComponent("com.trungluong.FastTab"))
}()

let tools = ReaderCommentTools(library: ReaderLibrary(directory: directory))
let server = MCPServer(
    info: MCPServerInfo(name: "fasttab", version: "1", instructions: ReaderCommentTools.instructions),
    tools: MCPToolRegistry(tools.tools),
    recordToolCall: { _ in })
await StdioTransport(server: server).run()
