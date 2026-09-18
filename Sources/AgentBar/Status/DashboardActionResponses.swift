import Foundation

/// `POST /api/focus` reply: `{"ok": true}` or `{"ok": false, "error": "..."}`.
struct DashboardFocusResponse: Decodable {
    let ok: Bool?
    let error: String?
}

/// `GET /api/pane/screen` reply: `{"ok": true, "lines": [...], "readTs": <epoch secs>}`
/// or `{"ok": false, "error": "...", "readTs": ...}`.
struct DashboardPaneScreenResponse: Decodable {
    let ok: Bool?
    let lines: [String]?
    let readTs: Double?
    let error: String?
}
