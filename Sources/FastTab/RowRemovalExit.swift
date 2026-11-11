/// Tracks the one result row currently playing its "removed" exit slide.
///
/// The row must stay in its exited (off to the side) position until it has
/// left the list *and* the list has finished collapsing. Clearing it earlier
/// animates the row back to its resting position before it disappears — the
/// "swipes away, snaps back, then vanishes" bug (2026-11-11).
struct RowRemovalExit: Equatable {
    private(set) var exitingID: String?

    /// Starts the exit slide for `id`. Returns a different row whose exit was
    /// still pending, so the caller can remove it right away.
    mutating func begin(_ id: String) -> String? {
        let superseded = exitingID == id ? nil : exitingID
        exitingID = id
        return superseded
    }

    func isExiting(_ id: String) -> Bool { exitingID == id }

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
