import FastTabReader
import FastTabSync
import Foundation
@testable import ReadingConnector

/// A throwaway FastTab support folder with a List, phone reading activity and highlights, as
/// the app would have written them. Fixed dates so output is stable.
@MainActor
struct ReadingConnectorFixture {
    nonisolated static let now = Date(timeIntervalSince1970: 1_800_000_000)  // 2027-01-15
    nonisolated static func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    let sources: ReadingSources
    let mirror: ReaderMirror
    var connector: ReadingConnector { ReadingConnector(sources: sources, now: { Self.now }) }

    init() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reading-connector-\(UUID().uuidString)")
        sources = ReadingSources(supportDirectory: dir)
        mirror = ReaderMirror(directory: sources.readerDirectory)
    }

    func writeList(_ items: [SavedOnIPhoneLink]) throws {
        try FastTabListFileStore(fileURL: sources.listFile, defaults: UserDefaults(suiteName: "rc-\(UUID().uuidString)")!)
            .write(items)
    }

    func writeActivity(_ activities: [ReadingActivity]) {
        ReadingActivityMirror(fileURL: sources.activityFile).applyRemoteReadingActivities(activities)
    }

    func addHighlight(id: String, url: String, quote: String, title: String? = nil, color: String = "yellow",
                      createdAt: Date) {
        var json: [String: Any] = [
            "id": id, "urlKey": URL(string: url)!.readerCanonicalKey, "selectedText": quote, "color": color,
            "serializedRange": #"{"text":"\#(quote)","start":0,"len":\#(quote.utf16.count)}"#,
            "createdAt": createdAt.timeIntervalSinceReferenceDate, "urlString": url,
        ]
        if let title { json["title"] = title }
        mirror.applyRemote(SyncedReaderHighlight(
            id: id, urlKey: URL(string: url)!.readerCanonicalKey, payload: try! JSONSerialization.data(withJSONObject: json)))
    }

    func comment(_ text: String, on highlightID: String) async throws {
        try await ReaderLibrary(directory: sources.readerDirectory, comments: mirror.comments)
            .comment(text, onHighlight: highlightID, by: .init(kind: .human, id: "me", label: "Me"))
    }

    /// The standard scene: a read article with highlights + a comment, one in progress, one
    /// unread, one read only on the phone (not in the List), one in Trash, one old.
    static func standard() async throws -> ReadingConnectorFixture {
        let f = try ReadingConnectorFixture()
        try f.writeList([
            SavedOnIPhoneLink(url: "https://essays.example.com/agents", title: "Agents that plan", savedAt: daysAgo(6),
                              readAt: daysAgo(2), progress: 1, progressUpdatedAt: daysAgo(2), readCount: 2,
                              readCountUpdatedAt: daysAgo(2)),
            SavedOnIPhoneLink(url: "https://news.example.org/halfway", title: "Halfway there", savedAt: daysAgo(5),
                              progress: 0.4, progressUpdatedAt: daysAgo(1)),
            SavedOnIPhoneLink(url: "https://blog.example.net/later", title: "Saved for later", savedAt: daysAgo(3)),
            SavedOnIPhoneLink(url: "https://trash.example.com/gone", title: "Trashed", savedAt: daysAgo(3), deletedAt: daysAgo(1)),
            SavedOnIPhoneLink(url: "https://old.example.com/ancient", title: "Old read", savedAt: daysAgo(60),
                              readAt: daysAgo(50), progress: 1, progressUpdatedAt: daysAgo(50),
                              readAgainAt: daysAgo(50), readAgainUpdatedAt: daysAgo(50)),
        ])
        f.writeActivity([
            ReadingActivity(url: "https://phone.example.com/only", title: "Read on the phone", progress: 1, lastReadAt: daysAgo(0.5)),
            // Fresher than the List's 40%: the phone read further.
            ReadingActivity(url: "https://news.example.org/halfway", title: nil, progress: 0.6, lastReadAt: daysAgo(0.25)),
        ])
        f.addHighlight(id: "h1", url: "https://essays.example.com/agents", quote: "Plan first, then act.",
                       title: "Agents that plan", color: "yellow", createdAt: daysAgo(2.1))
        f.addHighlight(id: "h2", url: "https://essays.example.com/agents", quote: "Tools are just functions.",
                       title: "Agents that plan", color: "green", createdAt: daysAgo(2))
        f.addHighlight(id: "h3", url: "https://old.example.com/ancient", quote: "An old thought.",
                       title: "Old read", createdAt: daysAgo(50))
        try await f.comment("This is the core of my next post.", on: "h1")
        return f
    }
}
