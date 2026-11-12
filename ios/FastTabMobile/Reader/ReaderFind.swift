import Foundation
import WebKit

// MARK: - Matcher

/// Find in Article matching. Pure: runs over the page text from `ftReadAloudText()` (title +
/// body, whitespace collapsed) and returns UTF-16 ranges into that same string, which the page
/// paints with `ftFindShow` (reader_template.html).
///
/// - Case- and diacritic-insensitive, Vietnamese included ("viet" finds "Việt", "duong" finds
///   "Đường": đ/Đ fold to d, which diacritic folding alone leaves alone).
/// - Whitespace in the query is trimmed and runs collapse to one space (the page text is collapsed too).
/// - Matches never overlap: after a match the search resumes after it, so "aa" in "aaa" is ONE
///   match (at 0), and "aa" in "aaaa" is two (0 and 2).
struct ReaderFindMatcher {
    /// Folded characters of the text, each with the UTF-16 range of the original character it came from.
    private let folded: [Character]
    private let origin: [Range<Int>]

    init(text: String) {
        var folded: [Character] = []
        var origin: [Range<Int>] = []
        var offset = 0
        for ch in text {
            let length = ch.utf16.count
            for f in Self.fold(String(ch)) {
                folded.append(f)
                origin.append(offset..<(offset + length))
            }
            offset += length
        }
        self.folded = folded
        self.origin = origin
    }

    static func fold(_ s: String) -> String {
        s.replacingOccurrences(of: "đ", with: "d").replacingOccurrences(of: "Đ", with: "d")
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    static func normalizedQuery(_ query: String) -> String {
        query.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Non-overlapping matches in reading order; empty for an empty (or whitespace-only) query.
    func matches(for query: String) -> [NSRange] {
        let q = Array(Self.fold(Self.normalizedQuery(query)))
        guard !q.isEmpty, q.count <= folded.count else { return [] }
        var result: [NSRange] = []
        var i = 0
        while i <= folded.count - q.count {
            if folded[i] == q[0], Array(folded[i..<(i + q.count)]) == q {
                let start = origin[i].lowerBound, end = origin[i + q.count - 1].upperBound
                // A query ending mid-way through a multi-character fold of one original character
                // still covers that whole character; skip a range already reported.
                if result.last.map({ $0.location + $0.length <= start }) ?? true {
                    result.append(NSRange(location: start, length: end - start))
                }
                i += q.count
            } else {
                i += 1
            }
        }
        return result
    }
}

// MARK: - Current match / wrap-around

/// Which match is current, with wrap-around both ways. Pure; `ReaderView` holds one.
struct ReaderFindState: Equatable {
    var query = ""
    var matchCount = 0
    /// Index of the current match; nil with no matches.
    var current: Int?

    /// New results for the query: the first match becomes current.
    mutating func setResults(count: Int) {
        matchCount = count
        current = count > 0 ? 0 : nil
    }

    mutating func next() {
        guard matchCount > 0 else { return }
        current = ((current ?? -1) + 1) % matchCount
    }

    mutating func previous() {
        guard matchCount > 0 else { return }
        current = ((current ?? 0) - 1 + matchCount) % matchCount
    }

    /// "3 of 12", "No matches", or "" while the query is empty.
    var countLabel: String {
        if ReaderFindMatcher.normalizedQuery(query).isEmpty { return "" }
        guard let current, matchCount > 0 else { return "No matches" }
        return "\(current + 1) of \(matchCount)"
    }
}

// MARK: - Page bridge

/// JS for the page's find functions. Only numbers cross into JS — never the query or the
/// page text — so nothing the user types can break out of the script.
enum ReaderFindJS {
    static let fetchText = "window.ftReadAloudText ? ftReadAloudText() : ''"
    static let clear = "window.ftFindClear && ftFindClear();"

    /// Paints every match, emphasises `current` and scrolls it into view.
    /// Returns 'ok', 'unmapped' or 'stale' (the page's text map changed: refetch and rematch).
    static func show(ranges: [NSRange], current: Int?) -> String {
        struct Payload: Encodable { let ranges: [[Int]]; let current: Int }
        let payload = Payload(ranges: ranges.map { [$0.location, $0.length] }, current: current ?? -1)
        let json = (try? JSONEncoder().encode(payload)).flatMap { String(data: $0, encoding: .utf8) } ?? "{\"ranges\":[],\"current\":-1}"
        return "window.ftFindShow ? ftFindShow(\(json)) : 'missing';"
    }
}

// MARK: - More (•••) menu

/// The reader's ••• menu, as data so its order, grouping and gating are tested
/// (`ReaderFindTests`). `ReaderView.moreActionsMenu` renders it.
enum ReaderMoreMenuEntry: Equatable {
    case item(ReaderMoreMenuAction)
    case section(String, [ReaderMoreMenuAction])
    case divider
}

enum ReaderMoreMenuAction: Equatable {
    case readingSettings
    case readAloudSettings
    /// `showsPlus`: small "Plus" caption, the summary is behind the paywall for this user.
    case summary(showsPlus: Bool)
    case cleanUpTranscript
    case findInArticle
    case reload
    case shareLink
    case openInSafari
    case saveToBookmarkFolder
    case deleteLink
}

enum ReaderMoreMenu {
    static func entries(isLoaded: Bool, isEntitled: Bool, hasSavedSummary: Bool,
                        cleanupAvailable: Bool) -> [ReaderMoreMenuEntry] {
        var entries: [ReaderMoreMenuEntry] = [.item(.readingSettings), .item(.readAloudSettings)]
        var ai: [ReaderMoreMenuAction] = []
        if isLoaded { ai.append(.summary(showsPlus: !isEntitled && !hasSavedSummary)) }
        if cleanupAvailable { ai.append(.cleanUpTranscript) }
        if !ai.isEmpty { entries.append(.section("AI", ai)) }
        entries.append(.divider)
        if isLoaded { entries.append(.item(.findInArticle)) }
        entries += [.item(.reload), .item(.shareLink), .item(.openInSafari), .divider,
                    .item(.saveToBookmarkFolder), .item(.deleteLink)]
        return entries
    }
}

// MARK: - Controller

/// Drives Find in Article for one reader page: holds the query, the matches and the current
/// one, and paints them through `ReaderFindJS`. `ReaderWebView` hands it the web view.
@MainActor
final class ReaderFindController: ObservableObject {
    @Published private(set) var isOpen = false
    @Published private(set) var state = ReaderFindState()
    weak var webView: WKWebView?
    /// Fetching the text rebuilds the page's shared text map (Read Aloud's locator must follow).
    var onPageMapRebuilt: (() -> Void)?

    private var matcher: ReaderFindMatcher?
    private var ranges: [NSRange] = []
    private var searchTask: Task<Void, Never>?

    func open() {
        isOpen = true
        if matcher == nil { fetchText { } }
    }

    func close() {
        isOpen = false
        searchTask?.cancel()
        state = ReaderFindState()
        ranges = []
        matcher = nil // the page may change (highlights, reload) before the next Find
        webView?.evaluateJavaScript(ReaderFindJS.clear, completionHandler: nil)
    }

    /// Live search: runs ~150 ms after the last keystroke.
    func setQuery(_ query: String) {
        guard query != state.query else { return }
        state.query = query
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.search()
        }
    }

    func next() { state.next(); show(retry: true) }
    func previous() { state.previous(); show(retry: true) }

    private func search() {
        guard isOpen else { return }
        guard let matcher else { fetchText { [weak self] in self?.search() }; return }
        ranges = matcher.matches(for: state.query)
        state.setResults(count: ranges.count)
        show(retry: true)
    }

    private func fetchText(then: @escaping () -> Void) {
        webView?.evaluateJavaScript(ReaderFindJS.fetchText) { [weak self] result, _ in
            guard let self, self.isOpen else { return }
            self.onPageMapRebuilt?()
            self.matcher = ReaderFindMatcher(text: result as? String ?? "")
            then()
        }
    }

    private func show(retry: Bool) {
        guard isOpen else { return }
        let js = ReaderFindJS.show(ranges: ranges, current: state.current)
        webView?.evaluateJavaScript(js) { [weak self] result, _ in
            // The page changed under its text map (new highlight, reload): rematch once.
            guard retry, let self, let status = result as? String, status == "stale" || status == "unmapped" else { return }
            let current = self.state.current
            self.fetchText { [weak self] in
                guard let self, let matcher = self.matcher else { return }
                self.ranges = matcher.matches(for: self.state.query)
                self.state.setResults(count: self.ranges.count)
                if let current, current < self.ranges.count { self.state.current = current }
                self.show(retry: false)
            }
        }
    }
}
