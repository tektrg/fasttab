import Foundation

/// A removed result row's way out: it slides off to the side, leaves the
/// page, and only then is released.
///
/// The row must stay in its exited (off to the side) position until it has
/// left the list *and* the list has finished collapsing. Releasing it while it
/// is still drawn animates it back to rest before it disappears — the
/// "swipes away, snaps back, then vanishes" bug (2026-11-11).
///
/// Pages draw from different lists, and not all of them drop a removed row
/// right away: a custom view re-evaluates its own list later (debounced, off
/// the main thread). So the row is also *hidden* from every page at the moment
/// it is removed (`hide` + `visible`), instead of waiting for that page's list
/// to catch up — the 2026-11-13 "still snaps back" regression on custom views.
struct RowRemovalExit: Equatable {
    /// How long a removed row stays hidden while its page's list catches up.
    /// A row still listed after this is a close that really failed: it shows
    /// again.
    static let hideDuration: TimeInterval = 5

    private(set) var exitingID: String?
    private var hiddenAt: [String: Date] = [:]

    var hiddenIDs: Set<String> { Set(hiddenAt.keys) }

    /// Starts the exit slide for `id`. Returns a different row whose exit was
    /// still pending, so the caller can remove it right away.
    mutating func begin(_ id: String) -> String? {
        let superseded = exitingID == id ? nil : exitingID
        exitingID = id
        return superseded
    }

    func isExiting(_ id: String) -> Bool { exitingID == id }

    /// Takes the row off every page now, in the same step as its removal.
    mutating func hide(_ id: String, now: Date) {
        hiddenAt = hiddenAt.filter { now.timeIntervalSince($0.value) < Self.hideDuration }
        hiddenAt[id] = now
    }

    /// Whether the result row `id` was removed within `hideDuration`.
    func isHidden(_ id: String, now: Date) -> Bool {
        guard let removedAt = hiddenAt[id] else { return false }
        return now.timeIntervalSince(removedAt) < Self.hideDuration
    }

    /// `items` minus the hidden result rows. Stack's pinned slots are never
    /// hidden: closing one leaves a ghost in place.
    func visible(_ items: [CommandBarDisplayItem], now: Date) -> [CommandBarDisplayItem] {
        guard !hiddenAt.isEmpty else { return items }
        return items.filter { item in
            guard case .result(let result) = item else { return true }
            return !isHidden(result.id, now: now)
        }
    }

    /// Ends the exit for `id` once removal has played out. Returns `true` when
    /// the row is still listed (the close failed), meaning it slides back into
    /// place. A stale call for a row that a newer removal replaced is ignored.
    @discardableResult
    mutating func finish(_ id: String, stillListed: Bool) -> Bool {
        guard exitingID == id else { return false }
        exitingID = nil
        return stillListed
    }
}

extension Array where Element == CommandBarDisplayItem {
    /// The result row with `id` that this page actually draws. Swipes and
    /// removals look rows up here — not in the Recents/search list, which
    /// holds neither Stack's "Sent to Mac" rows nor a custom view's rows.
    func drawnResult(id: String) -> BrowserSearchResult? {
        for item in self {
            if case .result(let result) = item, result.id == id { return result }
        }
        return nil
    }
}
