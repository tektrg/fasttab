import Foundation

/// Where a card reads the agent's "Last message" from. Pure: no disk, no network.
///
/// A row on this Mac reads its transcript from disk (full text). A row on another machine (the Air,
/// Oracle) has no transcript here, so it asks the dashboard (`GET /api/session/latest`, which reads
/// it over ssh). If that fails the card falls back to the dashboard's short screen scrape
/// (`AnswerCard.message`), so a dead ssh costs the length of the message, never the card.
enum LatestMessageSource: Equatable, Sendable {
    case localTranscript
    case dashboard(rowId: String)

    /// Mirrors the dashboard's `herdr_transport.split_pane_key`: a pane key `machine:pane` is remote
    /// unless the prefix is `local` or a herdr id (`w2`, `p_1`, `t3`: a bare local id such as `w8:p3`).
    static func isRemotePane(_ paneId: String?) -> Bool {
        guard let paneId, let colon = paneId.firstIndex(of: ":") else { return false }
        let prefix = String(paneId[..<colon])
        if prefix.isEmpty || prefix == "local" { return false }
        return !looksLikeHerdrId(prefix)
    }

    static func choose(paneId: String?, rowId: String?) -> LatestMessageSource {
        guard isRemotePane(paneId), let rowId, !rowId.isEmpty else { return .localTranscript }
        return .dashboard(rowId: rowId)
    }

    /// The context a remote read gives: the message when it is non-blank, else nothing (the card then
    /// falls back to its scrape). A remote row has no plan file on this Mac.
    static func remoteContext(text: String?) -> SessionContext {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return .empty }
        return SessionContext(latestMessage: trimmed, planFile: nil)
    }

    /// Runs the right read for `source`. A remote read that comes back empty or failed is `.empty`.
    static func resolve(
        _ source: LatestMessageSource,
        readLocal: @Sendable () async -> SessionContext,
        readRemote: @Sendable (_ rowId: String) async -> String?
    ) async -> SessionContext {
        switch source {
        case .localTranscript: return await readLocal()
        case .dashboard(let rowId): return remoteContext(text: await readRemote(rowId))
        }
    }

    /// What every card's transcript loader calls: `resolve` wired to this Mac's reader and the dashboard.
    static func read(
        _ source: LatestMessageSource,
        sessionId: String,
        readLocal: @escaping @Sendable (_ sessionId: String) async -> SessionContext,
        status: (any AgentStatusSource)?
    ) async -> SessionContext {
        await resolve(
            source,
            readLocal: { await readLocal(sessionId) },
            readRemote: { await status?.latestMessage(rowId: $0) }
        )
    }

    /// The same choice for the multi-question form the agent is waiting on: this Mac's transcript (needs the
    /// session id), or the dashboard's copy for a row on another machine. Nil (none, a failed read, no status
    /// source) leaves the card on the single question scraped from the pane.
    static func readPendingForm(
        _ source: LatestMessageSource,
        sessionId: String?,
        readLocal: @escaping @Sendable (_ sessionId: String) async -> PendingQuestionForm?,
        status: (any AgentStatusSource)?
    ) async -> PendingQuestionForm? {
        switch source {
        case .localTranscript:
            guard let sessionId else { return nil }
            return await readLocal(sessionId)
        case .dashboard(let rowId):
            return await status?.pendingForm(rowId: rowId)
        }
    }

    /// `^(w[0-9A-Za-z]+|p_?[0-9A-Za-z]+|t[0-9A-Za-z]+)$`
    private static func looksLikeHerdrId(_ prefix: String) -> Bool {
        guard let first = prefix.first, "wpt".contains(first) else { return false }
        var rest = prefix.dropFirst()
        if first == "p", rest.first == "_" { rest = rest.dropFirst() }
        return !rest.isEmpty && rest.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}
