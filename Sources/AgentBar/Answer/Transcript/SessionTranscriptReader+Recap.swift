import Foundation

extension SessionTranscriptReader {
    /// The newest `away_summary` recap in the session's transcript (the full text of Claude Code's
    /// "※ recap" line, with its "(disable recaps in /config)" footer), or nil. Tail-read like the rest.
    func latestAwaySummary(forSession sessionId: String) -> String? {
        guard let transcript = transcriptURL(forSession: sessionId),
              let handle = try? FileHandle(forReadingFrom: transcript),
              let fileSize = try? handle.seekToEnd() else { return nil }
        defer { try? handle.close() }
        for window in Self.tailWindowBytes {
            let startOffset = fileSize > UInt64(window) ? fileSize - UInt64(window) : 0
            guard (try? handle.seek(toOffset: startOffset)) != nil, let tail = try? handle.readToEnd() else { return nil }
            if let found = Self.latestAwaySummary(in: tail, chunkStartsAtFileStart: startOffset == 0) { return found }
            if startOffset == 0 { return nil }
        }
        return nil
    }

    static func latestAwaySummary(in tail: Data, chunkStartsAtFileStart: Bool) -> String? {
        var lines = tail.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if !chunkStartsAtFileStart, !lines.isEmpty { lines.removeFirst() }   // a window may begin mid-line
        for line in lines.reversed() {
            guard line.range(of: Data("away_summary".utf8)) != nil,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["type"] as? String == "system", object["subtype"] as? String == "away_summary",
                  let content = object["content"] as? String, !content.isEmpty else { continue }
            return content
        }
        return nil
    }
}
