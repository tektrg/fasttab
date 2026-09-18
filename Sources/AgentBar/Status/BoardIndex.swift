import Foundation

/// Lookups over the delivery board's live rows (the board feed is slow, ~150s,
/// so it is only used for extras: unpushed markers here, Ended rows elsewhere).
struct BoardIndex {
    private var pushTextByRowId: [String: String] = [:]
    private var pushTextByPaneId: [String: String] = [:]

    static let empty = BoardIndex()

    init() {}

    init(rows: [DashboardBoardRow]) {
        for row in rows where row.status == "live" {
            guard let pushText = row.pushText?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !pushText.isEmpty else { continue }
            if let rowId = row.rowId { pushTextByRowId[rowId] = pushText }
            if let paneId = row.paneId { pushTextByPaneId[paneId] = pushText }
        }
    }

    /// The "N ahead — not pushed" style marker, or nil when the row has none
    /// (or the board has no row for this agent).
    func unpushedText(rowId: String?, paneId: String?) -> String? {
        if let rowId, let text = pushTextByRowId[rowId] { return text }
        if let paneId, let text = pushTextByPaneId[paneId] { return text }
        return nil
    }
}
