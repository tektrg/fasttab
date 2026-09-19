import Foundation

// Wire types for the `actions` object the dashboard attaches to live agents and
// to board rows: `{stop: {enabled, needsConfirm, reason}, close: {...}, ...}`.
// Only stop and close are read.

struct DashboardActionEntry: Decodable {
    let enabled: Bool?
    let needsConfirm: Bool?
    let reason: String?

    private enum CodingKeys: String, CodingKey { case enabled, needsConfirm, reason }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = container.lenient(.enabled)
        needsConfirm = container.lenient(.needsConfirm)
        reason = container.lenient(.reason)
    }

    /// A missing `enabled` is treated as refused: better a greyed button than
    /// a live one on a row the server never said yes to.
    var availability: ActionAvailability {
        ActionAvailability(isEnabled: enabled ?? false, needsConfirm: needsConfirm ?? false, reason: reason)
    }
}

struct DashboardActions: Decodable {
    let stop: DashboardActionEntry?
    let close: DashboardActionEntry?

    private enum CodingKeys: String, CodingKey { case stop, close }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stop = container.lenient(.stop)
        close = container.lenient(.close)
    }
}

extension AgentActions {
    /// What the payload says; `fallback` for an action it does not mention or
    /// when it has no `actions` at all.
    init(decoded: DashboardActions?, fallback: AgentActions) {
        self.init(
            stop: decoded?.stop?.availability ?? fallback.stop,
            close: decoded?.close?.availability ?? fallback.close
        )
    }
}
