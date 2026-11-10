import Foundation
import IndieMCP

/// The `fasttab` terminal command: each subcommand calls the MCP tool of the same job, so the
/// terminal and the agent always get the same answer. Markdown by default, `--json` for scripts.
public struct ReadingCLI: Sendable {
    public struct Command: Sendable {
        public let name: String
        public let tool: String
        /// The argument a bare (non-flag) word fills, e.g. `fasttab article <url>`.
        public let positional: String?
        public let usage: String
    }

    public let tools: [MCPTool]
    public let commands: [Command]

    public init(tools: [MCPTool], commands: [Command] = ReadingCLI.standardCommands) {
        self.tools = tools
        self.commands = commands.filter { command in tools.contains { $0.name == command.tool } }
    }

    public static let standardCommands: [Command] = [
        Command(name: "reading", tool: "reading_list", positional: nil,
                usage: "fasttab reading [--status unread|reading|read|read_again] [--since 7d] [--limit 50]"),
        Command(name: "highlights", tool: "highlights", positional: nil,
                usage: "fasttab highlights [--since 7d] [--url <url>] [--topic <words>] [--limit 100]"),
        Command(name: "article", tool: "article", positional: "url",
                usage: "fasttab article <url> [--fetch-text]"),
        Command(name: "pack", tool: "context_pack", positional: "topic",
                usage: "fasttab pack [--period 7d] [<topic words>] [--max-tokens 8000]"),
        Command(name: "search", tool: "search", positional: "query",
                usage: "fasttab search <words> [--sources list,highlights,comments,bookmarks,history,text] [--limit 20]"),
        Command(name: "bookmarks", tool: "bookmarks", positional: "query",
                usage: "fasttab bookmarks [<words>] [--folder <name>]"),
        Command(name: "history", tool: "history", positional: nil,
                usage: "fasttab history [--since 3d] (off until allowed in FastTab Settings › Highlights › AI agent access)"),
    ]

    public struct Output: Equatable, Sendable {
        public let text: String
        public let exitCode: Int32
    }

    public var help: String {
        (["fasttab — your Fast Tab reading, read-only. Add --json for JSON.", ""] + commands.map { "  " + $0.usage })
            .joined(separator: "\n") + "\n"
    }

    /// `arguments` without the program name.
    public func run(_ arguments: [String]) async -> Output {
        guard let first = arguments.first, !["-h", "--help", "help"].contains(first) else {
            return Output(text: help, exitCode: arguments.isEmpty ? 64 : 0)
        }
        guard let command = commands.first(where: { $0.name == first }),
              let tool = tools.first(where: { $0.name == command.tool }) else {
            return Output(text: "Unknown command \(first).\n\n" + help, exitCode: 64)
        }
        let parsed: [String: JSONValue]
        do { parsed = try Self.parse(Array(arguments.dropFirst()), positional: command.positional) } catch {
            return Output(text: "\(error)\n\n  \(command.usage)\n", exitCode: 64)
        }
        let result = await tool.handler(parsed)
        if result.isError { return Output(text: result.text + "\n", exitCode: 1) }
        if let markdown = result.structuredContent?["markdown"]?.stringValue { return Output(text: markdown, exitCode: 0) }
        return Output(text: result.text + "\n", exitCode: 0)
    }

    struct UsageError: Error, CustomStringConvertible {
        let description: String
    }

    /// `--some-flag value` → `some_flag: value` (whole numbers as integers), `--json` →
    /// `format: json`, `--fetch-text` → `fetch_text: true`; bare words join into `positional`.
    static func parse(_ arguments: [String], positional: String?) throws -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        var words: [String] = []
        var index = 0
        let switches = ["fetch-text": "fetch_text"]
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            guard argument.hasPrefix("--") else {
                words.append(argument)
                continue
            }
            let name = String(argument.dropFirst(2))
            if name == "json" {
                result["format"] = "json"
                continue
            }
            if let key = switches[name] {
                result[key] = true
                continue
            }
            guard index < arguments.count else { throw UsageError(description: "\(argument) needs a value.") }
            let value = arguments[index]
            index += 1
            let key = name.replacingOccurrences(of: "-", with: "_")
            result[key] = Int(value).map(JSONValue.int) ?? .string(value)
        }
        if !words.isEmpty {
            guard let positional else { throw UsageError(description: "Unexpected \(words.joined(separator: " ")).") }
            result[positional] = .string(words.joined(separator: " "))
        }
        return result
    }
}
