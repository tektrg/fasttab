import Foundation

/// What the tail of a Claude session transcript says about the agent's last words.
struct TranscriptScan: Equatable, Sendable {
    /// The last text the assistant wrote, whatever tool calls and thinking came after.
    let latestMessage: String?
    /// Markdown files the agent most recently wrote, edited or read, newest first.
    let markdownPathCandidates: [String]
}

/// Reads the newest lines of a session transcript (JSONL, one content block per
/// line). Pure: bytes in, findings out. The caller supplies only the tail of a
/// file that can reach 100MB+, so the first line of the chunk is usually cut
/// short and must be dropped unless the chunk starts at the file's start.
enum TranscriptTailScanner {
    static let maxMessageLength = 6000
    static let maxPlanCandidates = 6
    private static let assistantMarker = Data("\"assistant\"".utf8)
    private static let newline = UInt8(ascii: "\n")
    private static let fileTools: Set<String> = ["Write", "Edit", "Read"]
    /// Markdown the agent reads for orientation, never as a plan.
    private static let ignoredFileNames: Set<String> = ["skill.md", "claude.md", "agents.md", "readme.md", "memory.md"]
    private static let ignoredPathPrefixes = ["/tmp/", "/private/tmp/"]

    static func scan(_ tail: Data, chunkStartsAtFileStart: Bool) -> TranscriptScan {
        var latestMessage: String?
        var candidates: [String] = []
        var lines = tail.split(separator: newline, omittingEmptySubsequences: true)
        if !chunkStartsAtFileStart, !lines.isEmpty { lines.removeFirst() }   // cut mid-line
        for line in lines.reversed() {
            guard line.range(of: assistantMarker) != nil,
                  let blocks = assistantBlocks(inLine: Data(line)) else { continue }
            for block in blocks.reversed() {
                if latestMessage == nil, let text = messageText(of: block) { latestMessage = text }
                if candidates.count < maxPlanCandidates, let path = markdownPath(of: block), !candidates.contains(path) {
                    candidates.append(path)
                }
            }
        }
        return TranscriptScan(latestMessage: latestMessage, markdownPathCandidates: candidates)
    }

    /// The content blocks of a main-conversation assistant line; nil for anything else
    /// (user lines, sub-agent chatter, the "no response requested" placeholders).
    private static func assistantBlocks(inLine line: Data) -> [[String: Any]]? {
        guard let entry = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              entry["type"] as? String == "assistant",
              entry["isSidechain"] as? Bool != true,
              let message = entry["message"] as? [String: Any],
              message["model"] as? String != "<synthetic>" else { return nil }
        if let text = message["content"] as? String { return [["type": "text", "text": text]] }
        return message["content"] as? [[String: Any]]
    }

    private static func messageText(of block: [String: Any]) -> String? {
        guard block["type"] as? String == "text", let text = block["text"] as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > maxMessageLength ? String(trimmed.prefix(maxMessageLength - 1)) + "…" : trimmed
    }

    private static func markdownPath(of block: [String: Any]) -> String? {
        guard block["type"] as? String == "tool_use",
              let tool = block["name"] as? String, fileTools.contains(tool),
              let input = block["input"] as? [String: Any],
              let path = input["file_path"] as? String,
              isPlanCandidate(path) else { return nil }
        return path
    }

    static func isPlanCandidate(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.lowercased().hasSuffix(".md"),
              !ignoredFileNames.contains((path as NSString).lastPathComponent.lowercased()) else { return false }
        return !ignoredPathPrefixes.contains { path.hasPrefix($0) }
    }
}
