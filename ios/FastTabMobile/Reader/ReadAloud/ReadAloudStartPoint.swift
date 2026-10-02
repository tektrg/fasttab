import Foundation

/// What the reader shows right now, in the page's text-map offsets (see
/// `ftReadAloudViewport` in `reader_template.html`). The reader restores the saved
/// reading progress by scrolling, so "what is on screen" is that same position.
struct ReadAloudViewport: Equatable {
    let pageText: String
    let firstVisibleOffset: Int
    let lastVisibleOffset: Int
    /// Scrolled to the very top: Play starts with the title.
    let isAtTop: Bool

    init(pageText: String, firstVisibleOffset: Int, lastVisibleOffset: Int, isAtTop: Bool) {
        self.pageText = pageText
        self.firstVisibleOffset = firstVisibleOffset
        self.lastVisibleOffset = lastVisibleOffset
        self.isAtTop = isAtTop
    }

    init?(javaScriptResult result: Any?) {
        guard let dict = result as? [String: Any],
              let text = dict["text"] as? String,
              let first = (dict["first"] as? NSNumber)?.intValue,
              let last = (dict["last"] as? NSNumber)?.intValue else { return nil }
        self.init(pageText: text, firstVisibleOffset: first, lastVisibleOffset: last,
                  isAtTop: (dict["atTop"] as? Bool) ?? false)
    }
}

/// Where the Play button starts. The rule, in order:
/// 1. Paused, and the paused paragraph is still on screen (or the screen is unknown) → resume.
/// 2. The last run read to the end of the article → start from the title.
/// 3. The page is at the very top (or the screen is unknown) → start from the title.
/// 4. Otherwise → the first paragraph at or below the top of the screen.
enum ReadAloudStartPoint: Equatable {
    case resume
    case chunk(Int)

    static func decide(
        isPaused: Bool,
        pausedChunk: Int,
        finishedArticle: Bool,
        chunks: [String],
        viewport: ReadAloudViewport?
    ) -> Self {
        guard let viewport else { return isPaused ? .resume : .chunk(0) }
        let locator = ReadAloudTextLocator(documentText: viewport.pageText, chunks: chunks)
        if isPaused, locator.chunk(pausedChunk, overlaps: viewport.firstVisibleOffset, viewport.lastVisibleOffset) {
            return .resume
        }
        if finishedArticle || viewport.isAtTop { return .chunk(0) }
        return .chunk(locator.firstChunk(atOrAfter: viewport.firstVisibleOffset) ?? 0)
    }
}
