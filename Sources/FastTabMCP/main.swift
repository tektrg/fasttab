import FastTabReader
import Foundation
import IndieMCP
import ReadingConnector

// fasttab-mcp: Fast Tab's read-only reading connector over MCP (stdio). An agent client
// (Claude Code, Claude Desktop, ...) starts it from FastTab.app/Contents/MacOS/. It reads the
// files the app keeps (FastTab List, phone reading activity, highlights + threads) and writes
// nothing back. Never listens on a network.
//
// Also the `fasttab` terminal command: `fasttab-mcp cli <command> …`, or the binary symlinked
// as `fasttab` (`ln -s …/fasttab-mcp ~/.local/bin/fasttab`).

let sources = ReadingSources.standard()
/// `FASTTAB_READER_DIR` still overrides just the reader mirror (older test setups).
let readerDirectory: URL = ProcessInfo.processInfo.environment["FASTTAB_READER_DIR"]
    .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) } ?? sources.readerDirectory

let reading = ReadingTools(
    connector: ReadingConnector(sources: sources),
    index: try? ReadingIndex(fileURL: ReadingIndex.fileURL(supportDirectory: sources.supportDirectory)))
let threads = ReaderCommentTools(library: ReaderLibrary(directory: readerDirectory))
let allTools = reading.tools + threads.tools

let arguments = Array(CommandLine.arguments.dropFirst())
let invokedAsCLI = URL(fileURLWithPath: CommandLine.arguments.first ?? "").lastPathComponent == "fasttab"
if invokedAsCLI || arguments.first == "cli" {
    let output = await ReadingCLI(tools: allTools).run(invokedAsCLI ? arguments : Array(arguments.dropFirst()))
    FileHandle(fileDescriptor: output.exitCode == 0 ? 1 : 2).write(Data(output.text.utf8))
    exit(output.exitCode)
}

let server = MCPServer(
    info: MCPServerInfo(
        name: "fasttab", version: "2",
        instructions: ReadingTools.instructions + "\n\n" + ReaderCommentTools.instructions),
    tools: MCPToolRegistry(allTools),
    recordToolCall: { _ in })
await StdioTransport(server: server).run(input: FileHandle.standardInput.bytes) { reply in
    // Markdown answers reach the agent as plain text (see MarkdownReplies).
    let body = reply.last == UInt8(ascii: "\n") ? reply.dropLast() : reply
    FileHandle.standardOutput.write(MarkdownReplies.rewrite(Data(body)) + Data("\n".utf8))
}
