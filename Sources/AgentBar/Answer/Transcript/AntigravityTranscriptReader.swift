import Foundation

/// Reads an Antigravity conversation's tail transcript
/// (`<appDataDir>/brain/<conversationId>/.system_generated/logs/transcript.jsonl`)
/// to extract the latest visible `PLANNER_RESPONSE` message and any Markdown plan artifact.
/// Synchronous file work; callers run it off the main thread.
struct AntigravityTranscriptReader: Sendable {
    static let tailWindowBytes = [256 * 1024, 1024 * 1024, 4 * 1024 * 1024]

    /// Documented Antigravity app data roots (App, CLI, IDE).
    static var defaultRoots: [URL] {
        let gemini = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini")
        return [
            gemini.appendingPathComponent("antigravity"),
            gemini.appendingPathComponent("antigravity-cli"),
            gemini.appendingPathComponent("antigravity-ide")
        ]
    }

    static var standard: AntigravityTranscriptReader {
        AntigravityTranscriptReader(appDataRoots: defaultRoots)
    }

    let appDataRoots: [URL]

    func context(forSession conversationId: String) -> SessionContext {
        guard let brainDir = brainDirectory(forSession: conversationId) else { return .empty }
        let transcript = brainDir.appendingPathComponent(".system_generated/logs/transcript.jsonl")
        let latestMessage = readLatestPlannerMessage(from: transcript)
        let planFile = findPlanFile(in: brainDir)
        guard latestMessage != nil || planFile != nil else { return .empty }
        return SessionContext(latestMessage: latestMessage, planFile: planFile)
    }

    func brainDirectory(forSession conversationId: String) -> URL? {
        guard SessionTranscriptReader.isSafeFileStem(conversationId) else { return nil }
        for root in appDataRoots {
            let dir = root.appendingPathComponent("brain").appendingPathComponent(conversationId)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue {
                return dir
            }
        }
        return nil
    }

    private func readLatestPlannerMessage(from transcript: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: transcript),
              let fileSize = try? handle.seekToEnd() else { return nil }
        defer { try? handle.close() }
        for window in Self.tailWindowBytes {
            let startOffset = fileSize > UInt64(window) ? fileSize - UInt64(window) : 0
            guard (try? handle.seek(toOffset: startOffset)) != nil,
                  let tail = try? handle.readToEnd() else { break }
            if let message = Self.scanLatestPlannerMessage(in: tail, chunkStartsAtFileStart: startOffset == 0) {
                return message
            }
            if startOffset == 0 { break }
        }
        return nil
    }

    /// Scans JSONL lines backwards for the newest `PLANNER_RESPONSE` step with non-empty `content`.
    static func scanLatestPlannerMessage(in data: Data, chunkStartsAtFileStart: Bool) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var lines = text.split(whereSeparator: \.isNewline)
        if !chunkStartsAtFileStart, !lines.isEmpty {
            lines.removeFirst() // may be cut mid-line at the tail boundary
        }
        let decoder = JSONDecoder()
        for rawLine in lines.reversed() {
            guard rawLine.contains("PLANNER_RESPONSE"),
                  let lineData = rawLine.data(using: .utf8),
                  let step = try? decoder.decode(TranscriptStep.self, from: lineData),
                  step.type == "PLANNER_RESPONSE",
                  let content = step.content?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !content.isEmpty else { continue }
            return content
        }
        return nil
    }

    private func findPlanFile(in brainDir: URL) -> URL? {
        let preferred = brainDir.appendingPathComponent("implementation_plan.md")
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: preferred.path, isDirectory: &isDir), !isDir.boolValue {
            return preferred
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: brainDir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return nil }
        return entries
            .filter { $0.pathExtension.lowercased() == "md" }
            .sorted { lhs, rhs in
                let lDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lDate > rDate
            }
            .first
    }

    private struct TranscriptStep: Decodable {
        let type: String?
        let content: String?
    }
}
