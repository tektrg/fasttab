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
/// `reader_template.html`). Builds a `ReadAloudTextLocator` from the page's text once
/// per playback session. Owned by `ReaderWebView.Coordinator`.
@MainActor
final class ReadAloudPageSync {
    weak var webView: WKWebView?
    private var lastState: ReadAloudPageState?
    private var locator: ReadAloudTextLocator?
    private var locatorSessionID: Int?

    func apply(_ state: ReadAloudPageState) {
        guard state != lastState else { return }
        lastState = state
        guard let position = state.position else {
            webView?.evaluateJavaScript("window.ftReadAloudClear && ftReadAloudClear();", completionHandler: nil)
            return
        }
        guard locatorSessionID == position.sessionID else {
            rebuildLocator(sessionID: position.sessionID, chunks: state.chunks)
            return
        }
        pushLastState()
    }

    private func rebuildLocator(sessionID: Int, chunks: [String]) {
        locatorSessionID = sessionID
        locator = nil
        webView?.evaluateJavaScript("window.ftReadAloudText ? ftReadAloudText() : ''") { [weak self] result, _ in
            guard let self, self.locatorSessionID == sessionID else { return }
            self.locator = ReadAloudTextLocator(documentText: result as? String ?? "", chunks: chunks)
            self.pushLastState()
        }
    }

    private func pushLastState() {
        guard let state = lastState, let position = state.position,
              let ranges = locator?.documentRanges(for: position) else { return }
        let js = "window.ftReadAloudShow && ftReadAloudShow("
            + "\(ranges.paragraph.location),\(ranges.paragraph.length),"
            + "\(ranges.word.location),\(ranges.word.length),\(state.autoScroll));"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }
}
