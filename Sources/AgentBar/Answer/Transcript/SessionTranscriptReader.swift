import Foundation

/// Finds an agent's Claude session transcript and reads only its tail: they
/// reach 100MB+, and the last words are at the end. Synchronous file work;
/// callers run it off the main thread.
struct SessionTranscriptReader: Sendable {
    /// Tail sizes tried in turn until a message is found: a long tool output
    /// can push the last text out of the first window.
    static let tailWindowBytes = [256 * 1024, 1024 * 1024, 4 * 1024 * 1024]

    let projectsRoot: URL

    static var standard: SessionTranscriptReader {
        SessionTranscriptReader(
            projectsRoot: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        )
    }

    /// Never throws: whatever cannot be read is simply not shown.
    func context(forSession sessionId: String) -> SessionContext {
        guard let transcript = transcriptURL(forSession: sessionId),
              let handle = try? FileHandle(forReadingFrom: transcript),
              let fileSize = try? handle.seekToEnd() else { return .empty }
        defer { try? handle.close() }
        var scan = TranscriptScan(latestMessage: nil, markdownPathCandidates: [])
        for window in Self.tailWindowBytes {
            let startOffset = fileSize > UInt64(window) ? fileSize - UInt64(window) : 0
            guard (try? handle.seek(toOffset: startOffset)) != nil,
                  let tail = try? handle.readToEnd() else { break }
            scan = TranscriptTailScanner.scan(tail, chunkStartsAtFileStart: startOffset == 0)
            if scan.latestMessage != nil || startOffset == 0 { break }
        }
        return SessionContext(latestMessage: scan.latestMessage, planFile: firstExistingFile(in: scan.markdownPathCandidates))
    }

    /// The AskUserQuestion form the agent is waiting on, when its transcript says so. The tail is widened
    /// step by step until the newest such call is found (answered or not) or the whole file was read.
    /// Never throws: nil means "no pending form" for whatever reason.
    func pendingQuestionForm(forSession sessionId: String) -> PendingQuestionForm? {
        guard let transcript = transcriptURL(forSession: sessionId),
              let handle = try? FileHandle(forReadingFrom: transcript),
              let fileSize = try? handle.seekToEnd() else { return nil }
        defer { try? handle.close() }
        for window in Self.tailWindowBytes {
            let startOffset = fileSize > UInt64(window) ? fileSize - UInt64(window) : 0
            guard (try? handle.seek(toOffset: startOffset)) != nil, let tail = try? handle.readToEnd() else { return nil }
            switch AskUserQuestionExtractor.find(in: tail, chunkStartsAtFileStart: startOffset == 0) {
            case .pending(let form): return form
            case .settled: return nil
            case .notFound: if startOffset == 0 { return nil }
            }
        }
        return nil
    }

    /// The answers the transcript recorded for `form` (the agent's own record of what was submitted), or nil when it
    /// has none yet (the result line lags the terminal by a moment) or cannot be read. Never throws.
    func recordedAnswers(forSession sessionId: String, form: PendingQuestionForm) -> RecordedFormAnswers? {
        guard let transcript = transcriptURL(forSession: sessionId),
              let handle = try? FileHandle(forReadingFrom: transcript),
              let fileSize = try? handle.seekToEnd() else { return nil }
        defer { try? handle.close() }
        for window in Self.tailWindowBytes {
            let startOffset = fileSize > UInt64(window) ? fileSize - UInt64(window) : 0
            guard (try? handle.seek(toOffset: startOffset)) != nil, let tail = try? handle.readToEnd() else { return nil }
            if let found = AskUserQuestionResultExtractor.find(
                toolUseId: form.toolUseId, form: form, in: tail, chunkStartsAtFileStart: startOffset == 0
            ) { return found }
            if startOffset == 0 { return nil }
        }
        return nil
    }

    /// `<projectsRoot>/<any project folder>/<session id>.jsonl`. The folder name is
    /// the cwd with slashes flattened, which is unreliable, so search every folder.
    func transcriptURL(forSession sessionId: String) -> URL? {
        guard Self.isSafeFileStem(sessionId),
              let folders = try? FileManager.default.contentsOfDirectory(
                at: projectsRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
              ) else { return nil }
        return folders
            .map { $0.appendingPathComponent("\(sessionId).jsonl") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Session ids come from the dashboard: keep them from walking out of the folder.
    static func isSafeFileStem(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
    }

    private func firstExistingFile(in paths: [String]) -> URL? {
        paths.lazy
            .map { URL(fileURLWithPath: $0) }
            .first { url in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
            }
    }
}
