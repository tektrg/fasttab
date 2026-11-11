import FastTabReader
import FastTabSync
import Foundation

/// One page the user has saved or read: a FastTab List item, the phone's reading activity for
/// it, or both (joined on the canonical-URL id).
public struct ReadingItem: Hashable, Sendable {
    public enum Status: String, CaseIterable, Sendable {
        case unread, reading, read
        case readAgain = "read_again"
    }

    public let id: String
    public let url: String
    public let title: String?
    public let domain: String?
    /// 0...1.
    public let progress: Double
    public let readCount: Int
    public let readAt: Date?
    public let savedAt: Date?
    /// The latest of saved / progress / read / read-count changes and phone activity.
    public let lastActivityAt: Date
    public let inList: Bool
    public let isReadAgain: Bool

    public var displayTitle: String { (title?.isEmpty == false ? title : nil) ?? domain ?? url }

    /// read_again wins (it is a deliberate mark); then read (marked, or scrolled past the
    /// List's read threshold); then reading (started); else unread.
    public var status: Status {
        if isReadAgain { return .readAgain }
        if readAt != nil || progress >= FastTabListLibrary.readThreshold { return .read }
        return progress > 0.01 ? .reading : .unread
    }

    /// True for the filter: read_again items also count as read when they were read.
    public func matches(_ wanted: Status) -> Bool {
        switch wanted {
        case .readAgain: isReadAgain
        case .read: readAt != nil || progress >= FastTabListLibrary.readThreshold
        case .reading: !isReadAgain && status == .reading
        case .unread: !isReadAgain && status == .unread
        }
    }
}

/// A page's highlights and threads with its reading state: what `article(url)` returns.
public struct ArticleDetail: Sendable {
    public let url: String
    public let item: ReadingItem?
    public let highlights: [HighlightEntry]
}

/// The reading connector's engine: read-only queries over the List, the phone's reading
/// activity and highlights. Shared by the `fasttab-mcp` tools and the `fasttab` CLI.
public struct ReadingConnector: Sendable {
    public let sources: ReadingSources
    public let now: @Sendable () -> Date

    public init(sources: ReadingSources = .standard(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.sources = sources
        self.now = now
    }

    // MARK: - Reading list

    /// Every page with reading state, newest activity first. Trash and purged items are left
    /// out; phone activity for a page not in the List still appears.
    public func items() -> [ReadingItem] {
        let listItems = sources.listItems().filter { !$0.isTrashed && !$0.isPurged }
        var activityByID = Dictionary(sources.activities().map { ($0.id, $0) }, uniquingKeysWith: ReadingActivity.merge)
        var items: [ReadingItem] = listItems.map { link in
            let id = FastTabListLibrary.itemID(for: link.url)
            return Self.item(list: link, activity: activityByID.removeValue(forKey: id), id: id)
        }
        items += activityByID.values.map { Self.item(list: nil, activity: $0, id: $0.id) }
        return items.sorted { ($0.lastActivityAt, $0.id) > ($1.lastActivityAt, $1.id) }
    }

    /// `reading_list`: optional status filter and activity window, at most `limit`.
    public func readingList(status: ReadingItem.Status? = nil, since: Date? = nil, limit: Int = 50) -> [ReadingItem] {
        Array(items()
            .filter { item in status.map(item.matches) ?? true }
            .filter { item in since.map { item.lastActivityAt >= $0 } ?? true }
            .prefix(max(1, limit)))
    }

    public func item(url: String) -> ReadingItem? {
        let id = FastTabListLibrary.itemID(for: url)
        return items().first { $0.id == id }
    }

    // MARK: - Highlights

    /// `highlights`: newest first; `since` on the highlight's date, `url` to one page,
    /// `topic` = every word found in the quote, a comment, the page title or URL.
    public func highlights(since: Date? = nil, url: String? = nil, topic: String? = nil, limit: Int = 100) async -> [HighlightEntry] {
        let key = url.flatMap(URL.init(string:))?.readerCanonicalKey
        let words = Self.words(topic)
        return Array(await sources.readerLibrary.entries()
            .filter { entry in since.map { entry.highlight.createdAt >= $0 } ?? true }
            .filter { entry in key.map { entry.highlight.urlKey == $0 } ?? true }
            .filter { entry in words.isEmpty || Self.contains(words, in: Self.searchableText(entry)) }
            .prefix(max(1, limit)))
    }

    /// `article(url)`: the page's List/activity state and every highlight on it, oldest
    /// highlight first (reading order).
    public func article(url: String) async -> ArticleDetail {
        let entries = await highlights(url: url, limit: .max).sorted { $0.highlight.createdAt < $1.highlight.createdAt }
        return ArticleDetail(url: url, item: item(url: url), highlights: entries)
    }

    // MARK: - Helpers

    static func item(list: SavedOnIPhoneLink?, activity: ReadingActivity?, id: String) -> ReadingItem {
        let url = list?.url ?? activity?.url ?? ""
        let dates = [list?.savedAt, list?.progressUpdatedAt, list?.readAt, list?.readCountUpdatedAt,
                     list?.readAgainAt, activity?.lastReadAt].compactMap { $0 }
        // The fresher of the two progress readings.
        let progress: Double
        if let list, let activity {
            progress = activity.lastReadAt > (list.progressUpdatedAt ?? .distantPast) ? activity.progress : list.progress
        } else {
            progress = list?.progress ?? activity?.progress ?? 0
        }
        let title = (list?.title?.isEmpty == false ? list?.title : nil) ?? activity?.title
        return ReadingItem(
            id: id, url: url, title: title, domain: FastTabListBridge.domain(of: url),
            progress: progress, readCount: list?.readCount ?? 0, readAt: list?.readAt,
            savedAt: list?.savedAt, lastActivityAt: dates.max() ?? .distantPast,
            inList: list != nil, isReadAgain: list?.isReadAgain ?? false)
    }

    static func searchableText(_ entry: HighlightEntry) -> String {
        ([entry.highlight.selectedText, entry.highlight.pageTitle, entry.highlight.urlKey]
         + (entry.highlight.tags ?? []) + entry.comments.compactMap(\.text)).joined(separator: "\n")
    }

    static func words(_ text: String?) -> [String] {
        (text ?? "").split(whereSeparator: { $0.isWhitespace }).map { fold(String($0)) }.filter { !$0.isEmpty }
    }

    static func contains(_ words: [String], in text: String) -> Bool {
        let folded = fold(text)
        return words.allSatisfy { folded.contains($0) }
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
