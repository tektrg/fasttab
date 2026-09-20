import Foundation

/// Synthetic Claude session transcript lines (one content block per line, as
/// Claude Code writes them). No real transcript content lives in the repo.
enum TranscriptFixtures {
    private static func line(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    static func assistantText(_ text: String, sidechain: Bool = false, model: String = "claude-test") -> String {
        line(["type": "assistant", "isSidechain": sidechain,
              "message": ["id": "msg_1", "model": model, "role": "assistant", "content": [["type": "text", "text": text]]]])
    }

    static func thinking() -> String {
        line(["type": "assistant", "isSidechain": false,
              "message": ["id": "msg_2", "model": "claude-test", "content": [["type": "thinking", "thinking": "hmm", "signature": "x"]]]])
    }

    static func toolUse(_ name: String, path: String? = nil, input: [String: Any] = [:]) -> String {
        var arguments = input
        if let path { arguments["file_path"] = path }
        return line(["type": "assistant", "isSidechain": false,
                     "message": ["id": "msg_3", "model": "claude-test", "content": [["type": "tool_use", "id": "toolu_1", "name": name, "input": arguments]]]])
    }

    static func askUserQuestion() -> String {
        toolUse("AskUserQuestion", input: ["questions": [["question": "Which?", "header": "H", "options": []]]])
    }

    static func userToolResult(_ text: String = "ok", toolUseId: String = "toolu_1") -> String {
        line(["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": toolUseId, "content": text]]]])
    }

    static func housekeeping() -> String {
        line(["type": "last-prompt", "lastPrompt": "assistant"])   // mentions the word, is not an assistant line
    }

    static func jsonl(_ lines: [String]) -> Data {
        Data((lines.joined(separator: "\n") + "\n").utf8)
    }
}
