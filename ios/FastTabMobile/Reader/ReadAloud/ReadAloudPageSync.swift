import WebKit

/// What the reader page needs to show Read Aloud progress.
struct ReadAloudPageState: Equatable {
    var position: ReadAloudSpokenPosition?
    var chunks: [String]
    var autoScroll: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        // `chunks` only change with a new session, which `position.sessionID` already captures.
        lhs.position == rhs.position && lhs.autoScroll == rhs.autoScroll
    }
}

/// Pushes the spoken word to the page (`ftReadAloudShow` / `ftReadAloudClear` in
/// `reader_template.html`). Builds a `ReadAloudTextLocator` from the page's text per
/// playback session, and rebuilds it when the page reports its text map is stale
/// (DOM changed: highlight added, transcript re-cleaned, page reloaded).
/// Owned by `ReaderWebView.Coordinator`.
@MainActor
final class ReadAloudPageSync {
    weak var webView: WKWebView?
    private var lastState: ReadAloudPageState?
    private var locator: ReadAloudTextLocator?
    private var locatorSessionID: Int?
    /// Guards against rebuild loops: one rebuild per spoken position at most.
    private var rebuiltForPosition: ReadAloudSpokenPosition?

    func apply(_ state: ReadAloudPageState) {
        guard state != lastState else { return }
        lastState = state
        guard let position = state.position else {
            evaluate("window.ftReadAloudClear && ftReadAloudClear();", purpose: "clear")
            return
        }
        guard locatorSessionID == position.sessionID, locator != nil else {
            rebuildLocator(sessionID: position.sessionID, chunks: state.chunks)
            return
        }
        pushLastState()
    }

    private func rebuildLocator(sessionID: Int, chunks: [String]) {
        locatorSessionID = sessionID
        locator = nil
        webView?.evaluateJavaScript("window.ftReadAloudText ? ftReadAloudText() : ''") { [weak self] result, error in
            guard let self, self.locatorSessionID == sessionID else { return }
            if let error { readAloudLog.error("page text fetch failed: \(error.localizedDescription)") }
            let locator = ReadAloudTextLocator(documentText: result as? String ?? "", chunks: chunks)
            let unmatched = locator.chunkStarts.filter { $0 == nil }.count
            if unmatched > 0 { readAloudLog.info("\(unmatched) of \(chunks.count) chunks not found on page") }
            self.locator = locator
            self.pushLastState()
        }
    }

    private func pushLastState() {
        guard let state = lastState, let position = state.position else { return }
        guard let ranges = locator?.documentRanges(for: position) else {
            // This paragraph isn't on the page: show nothing rather than an old word.
            evaluate("window.ftReadAloudClear && ftReadAloudClear();", purpose: "clear unmapped")
            return
        }
        let js = "window.ftReadAloudShow ? ftReadAloudShow("
            + "\(ranges.paragraph.location),\(ranges.paragraph.length),"
            + "\(ranges.word.location),\(ranges.word.length),\(state.autoScroll)) : 'missing';"
        webView?.evaluateJavaScript(js) { [weak self] result, error in
            if let error {
                readAloudLog.error("highlight JS failed: \(error.localizedDescription)")
                return
            }
            let status = result as? String ?? "?"
            guard status != "ok", let self, self.lastState?.position == position,
                  self.rebuiltForPosition != position else { return }
            readAloudLog.info("page map \(status) at chunk \(position.chunkIndex): rebuilding")
            self.rebuiltForPosition = position
            self.rebuildLocator(sessionID: position.sessionID, chunks: state.chunks)
        }
    }

    private func evaluate(_ js: String, purpose: String) {
        webView?.evaluateJavaScript(js) { _, error in
            if let error { readAloudLog.error("\(purpose) JS failed: \(error.localizedDescription)") }
        }
    }
}
