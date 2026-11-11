import Foundation

/// Claude Code's end-of-turn recap ("※ recap: …") reaches AgentBar already squeezed: the dashboard keeps
/// the first ~88 and last ~58 characters of a long recap joined by " … " (`classify_pane.last_signal_line`,
/// on purpose: ranking reads the closing sentence). The full text is in the session transcript as a
/// `system` entry with subtype `away_summary`. This puts the full text back, only when the transcript's
/// recap provably is the one on the pane (its start and end match the squeezed text).
enum RecapText {
    static let prefix = "※ recap:"
    private static let gap = " … "
    private static let trailer = "(disable recaps in /config)"

    /// A recap the dashboard squeezed (starts with the marker and holds the " … " join).
    static func isSqueezed(_ statusText: String) -> Bool {
        statusText.hasPrefix(prefix) && statusText.contains(gap)
    }

    /// The transcript recap with its "(disable recaps in /config)" footer and extra whitespace removed.
    static func cleaned(_ transcriptContent: String) -> String {
        var text = collapse(transcriptContent)
        if text.hasSuffix(trailer) { text = String(text.dropLast(trailer.count)) }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// The row text with the whole recap, or nil when the transcript's recap is not the squeezed one.
    static func expanded(squeezed: String, transcriptContent: String) -> String? {
        guard isSqueezed(squeezed), let gapRange = squeezed.range(of: gap) else { return nil }
        let head = collapse(String(squeezed[..<gapRange.lowerBound].dropFirst(prefix.count)))
        let tail = collapse(String(squeezed[gapRange.upperBound...]))
        let full = cleaned(transcriptContent)
        guard !head.isEmpty, !tail.isEmpty, full.hasPrefix(head), full.hasSuffix(tail), full.count >= head.count + tail.count
        else { return nil }
        return "\(prefix) \(full)"
    }

    private static func collapse(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

/// Swaps squeezed recaps for the full text, one transcript read per (session, squeezed text), off the main
/// thread. Rows show the squeezed text until the read lands, then `onChange` asks the model to re-derive.
/// A session whose transcript is not on this Mac (an agent on another machine) simply stays squeezed.
@MainActor
final class RecapExpander {
    typealias Load = @Sendable (_ sessionId: String) async -> String?

    /// Safety cap, same spirit as `LiveAgentMapper.statusTextMaxLength` (a recap is ~300 characters).
    static let maxLength = 1_200

    var onChange: () -> Void = {}
    private let load: Load
    private let now: () -> Date
    /// How long a "no matching recap yet" answer stands before the transcript is read again (the
    /// transcript line can land a moment after the pane draws the recap, and a remote session's
    /// transcript is never here — so not every second).
    private let retryAfter: TimeInterval
    private struct Entry { let full: String?; let at: Date }
    private var results: [String: Entry] = [:]
    private var inFlight: Set<String> = []

    init(
        retryAfter: TimeInterval = 30,
        now: @escaping () -> Date = { Date() },
        load: @escaping Load = RecapExpander.readLatestAwaySummary
    ) {
        self.retryAfter = retryAfter
        self.now = now
        self.load = load
    }

    nonisolated static func readLatestAwaySummary(sessionId: String) async -> String? {
        await Task.detached(priority: .utility) {
            SessionTranscriptReader.standard.latestAwaySummary(forSession: sessionId)
        }.value
    }

    func expanded(_ agents: [AgentSnapshot]) -> [AgentSnapshot] {
        agents.map { agent in
            guard RecapText.isSqueezed(agent.statusText), let sessionId = agent.sessionId else { return agent }
            let key = Self.key(sessionId, agent.statusText)
            if let entry = results[key] {
                if let full = entry.full, let text = StatusTextCleaner.singleLine(full, maxLength: Self.maxLength) {
                    return agent.withStatusText(text)
                }
                if now().timeIntervalSince(entry.at) >= retryAfter {
                    fetch(key: key, sessionId: sessionId, squeezed: agent.statusText)
                }
                return agent
            }
            fetch(key: key, sessionId: sessionId, squeezed: agent.statusText)
            return agent
        }
    }

    func reset() {
        results = [:]
    }

    private func fetch(key: String, sessionId: String, squeezed: String) {
        guard inFlight.insert(key).inserted else { return }
        Task {
            let content = await load(sessionId)
            inFlight.remove(key)
            let full = content.flatMap { RecapText.expanded(squeezed: squeezed, transcriptContent: $0) }
            results[key] = Entry(full: full, at: now())
            if full != nil { onChange() }   // nothing to redraw when there was no match
        }
    }

    private static func key(_ sessionId: String, _ squeezed: String) -> String { "\(sessionId)|\(squeezed)" }
}
