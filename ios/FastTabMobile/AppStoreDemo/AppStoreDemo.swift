#if DEBUG
import Foundation
import FastTabSync
import IndieTranscripts
import IndieMotion
import TipKit
import UIKit

/// Made-up reading library for App Store screenshots. Debug builds only.
///
/// Launch with `-FastTabAppStoreDemo YES` (plus `-FastTabAppMode standalone`,
/// `-FastTabStatsDemo YES`, `-onboarding.v1.completed YES`): the FastTab List, reader
/// cache, highlights and last-opened list are filled with the articles below, and sync
/// stays off so nothing reaches iCloud. `-FastTabDemoScreen <name>` picks the opening
/// screen (`AppStoreDemo.Screen`). Driven by `marketing/appstore/tools/capture.sh`, which
/// backs up the simulator's app data first and restores it afterwards.
///
/// With `-FastTabAppMode mac` it also fills the sync cache with a demo Mac, its open browser
/// tabs and bookmarks (`seedMac`), as if FastTab for Mac had synced them.
///
/// Writes into the app's normal stores, so only run it on a simulator.
enum AppStoreDemo {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "FastTabAppStoreDemo") }

    enum Screen: String {
        case read, reader, highlights, more, shuffle, tabs, bookmarks, transcript, listen, swipe, paywall
    }

    static var screen: Screen {
        UserDefaults.standard.string(forKey: "FastTabDemoScreen").flatMap(Screen.init(rawValue:)) ?? .read
    }

    struct DemoHighlight {
        let text: String
        let color: HighlightColor
        let tags: [String]
    }

    struct DemoArticle {
        let url: String
        let title: String
        let byline: String
        let siteName: String
        let excerpt: String
        let html: String
        let hoursAgo: Double
        let progress: Double
        let highlights: [DemoHighlight]
    }

    /// The article the `reader` screen opens.
    static var featured: DemoArticle { articles[0] }

    static let articles: [DemoArticle] = [
        DemoArticle(
            url: "https://slowpage.blog/the-art-of-the-unhurried-read",
            title: "The art of the unhurried read",
            byline: "Mara Ellison",
            siteName: "Slow Page",
            excerpt: "Why the articles we save are worth finishing, and how to make room for them.",
            html: """
            <p>Every week we save more than we read. A link from a friend, an essay someone quoted, a long piece we promise to get to on the weekend. The pile grows quietly until saving starts to feel like a substitute for reading.</p>
            <p>The fix is not more discipline. It is a better place to read: one quiet column of text, no pop-ups, no sidebar, nothing asking for your attention except the words.</p>
            <h2>Make the page disappear</h2>
            <p>Good typography is invisible. The right line length, generous spacing and a calm background let you forget you are looking at a screen. When the page gets out of the way, ten minutes of reading feels like a small holiday.</p>
            <p>Keep only what you came for. A highlight is a note to your future self: the one sentence that made the whole article worth it.</p>
            <h2>Come back to it</h2>
            <p>Most saved articles are not forgotten, just early. A good reading list brings the right piece back at the right moment, picks up where you stopped, and keeps the lines you marked in one place.</p>
            """,
            hoursAgo: 2, progress: 0,
            highlights: [
                DemoHighlight(text: "It is a better place to read: one quiet column of text, no pop-ups, no sidebar, nothing asking for your attention except the words.", color: .yellow, tags: ["reading"]),
                DemoHighlight(text: "A highlight is a note to your future self: the one sentence that made the whole article worth it.", color: .green, tags: ["reading", "ideas"])
            ]
        ),
        DemoArticle(
            url: "https://fieldnotesdaily.com/how-to-take-a-real-break",
            title: "How to take a real break",
            byline: "Jonah Reyes",
            siteName: "Field Notes Daily",
            excerpt: "Rest is a skill. Here is what the research says about recharging well.",
            html: """
            <p>A real break is not scrolling between tasks. It is a few minutes where your attention is allowed to wander somewhere that asks nothing back.</p>
            <p>Short walks, a window, a chapter of something you chose: the best breaks are the ones you look forward to.</p>
            <h2>Small and often</h2>
            <p>Five quiet minutes every hour beat one long collapse at the end of the day.</p>
            """,
            hoursAgo: 20, progress: 0.4,
            highlights: [
                DemoHighlight(text: "Five quiet minutes every hour beat one long collapse at the end of the day.", color: .blue, tags: ["health"])
            ]
        ),
        DemoArticle(
            url: "https://studiomargin.com/a-field-guide-to-good-typography",
            title: "A field guide to good typography",
            byline: "Lena Fischer",
            siteName: "Studio Margin",
            excerpt: "Line length, rhythm and contrast: the small choices that make text easy to read.",
            html: """
            <p>Most reading comfort comes down to three things: how long a line is, how much space sits between lines, and how much the text stands out from the page.</p>
            <p>Aim for 60 to 75 characters a line. Shorter feels choppy, longer makes the eye lose its place.</p>
            """,
            hoursAgo: 30, progress: 0,
            highlights: [
                DemoHighlight(text: "Aim for 60 to 75 characters a line.", color: .pink, tags: ["design"])
            ]
        ),
        DemoArticle(
            url: "https://quietkitchen.co/one-pot-weeknight-dinners",
            title: "Ten one-pot dinners for busy weeknights",
            byline: "Sofia Marin",
            siteName: "Quiet Kitchen",
            excerpt: "Fewer dishes, more flavour: recipes that come together in thirty minutes.",
            html: """
            <p>A good weeknight dinner fits in one pot and thirty minutes. These ten recipes lean on pantry staples and finish with something fresh.</p>
            <p>Start with the lemony white bean stew: it tastes better the next day.</p>
            """,
            hoursAgo: 52, progress: 0,
            highlights: []
        ),
        DemoArticle(
            url: "https://northwindtravel.com/walking-lisbon-in-a-day",
            title: "Walking Lisbon in a day",
            byline: "Tom Hartley",
            siteName: "Northwind Travel",
            excerpt: "Seven hills, one pair of shoes: a route through the city's best viewpoints.",
            html: """
            <p>Lisbon rewards anyone willing to climb. This route links six viewpoints, three cafés and one very steep tram line.</p>
            <p>Start early at the castle, before the tour groups arrive, and end at sunset in Bairro Alto.</p>
            """,
            hoursAgo: 75, progress: 0,
            highlights: [
                DemoHighlight(text: "Start early at the castle, before the tour groups arrive, and end at sunset in Bairro Alto.", color: .yellow, tags: ["travel"])
            ]
        ),
        DemoArticle(
            url: "https://thinkingtools.dev/notes-that-compound",
            title: "Notes that compound: keeping ideas you can find again",
            byline: "Priya Shah",
            siteName: "Thinking Tools",
            excerpt: "A simple system for saving what you read so it is still useful a year later.",
            html: """
            <p>The value of a note is not in writing it but in finding it again at the moment you need it.</p>
            <p>Tag lightly, link generously, and review what you saved once a week.</p>
            """,
            hoursAgo: 100, progress: 0,
            highlights: [
                DemoHighlight(text: "The value of a note is not in writing it but in finding it again at the moment you need it.", color: .green, tags: ["ideas"])
            ]
        ),
        DemoArticle(
            url: "https://deepsky.science/why-we-should-look-up-more",
            title: "Why we should look up more often",
            byline: "Ana Costa",
            siteName: "Deep Sky",
            excerpt: "A beginner's guide to the night sky, no telescope required.",
            html: """
            <p>On a clear night you can see a few thousand stars with your own eyes. Learning five of them is enough to never feel lost under the sky again.</p>
            """,
            hoursAgo: 140, progress: 0,
            highlights: []
        )
    ]

    // MARK: YouTube transcript (fictional talk; the video id is not a real video)

    static let transcriptURL = URL(string: "https://www.youtube.com/watch?v=FtDemo00001")!
    static let transcriptTitle = "How I Read 50 Books a Year Without Trying"

    /// Fixed drag for the `swipe` screen: far enough right to show the MOVE TO stamp.
    static let swipeOffset = CGSize(width: 130, height: 14)

    /// The `listen` screen plays a different article than the `reader` screen.
    static var listenArticle: DemoArticle { articles[1] }

    static func transcriptArticle() -> ReaderArticle {
        let sentences = [
            "So the question I get most is how I find the time to read.",
            "And the honest answer is that I stopped trying to find time.",
            "Instead, I made reading the easiest thing to reach for.",
            "Every article I want to read goes into one list, the moment I see it.",
            "Not a dozen tabs, not a note to self, one list.",
            "Then, when I have ten minutes in a queue or on the train, I open that list.",
            "The second habit is marking the lines that matter.",
            "I highlight maybe one or two sentences per piece.",
            "Once a week I scroll through those highlights, and that is where the ideas stick.",
            "The third habit sounds strange, but I listen to a lot of my reading.",
            "Long essays become something I can finish on a walk.",
            "And videos like this one, I usually read as a transcript instead of watching.",
            "It is faster, and I can skim to the part I came for.",
            "None of this needs willpower.",
            "It just needs the next good thing to read to be one tap away.",
        ]
        var lines: [TranscriptLine] = []
        var ms = 0
        for sentence in sentences {
            lines.append(TranscriptLine(startMs: ms, durationMs: 4_500, text: sentence))
            ms += 4_500
        }
        let transcript = Transcript(videoId: "FtDemo00001", title: transcriptTitle, lang: "en",
                                    kind: .manual, availableLangs: ["en"], lines: lines)
        return TranscriptArticleBuilder.article(from: transcript, url: transcriptURL, videoID: "FtDemo00001",
                                                title: transcriptTitle, channel: "The Quiet Shelf")
    }

    /// Card thumbnail for a demo article: `demo-thumb-<index>.png`, bundled in Debug builds only
    /// (`EXCLUDED_SOURCE_FILE_NAMES` in project.yml keeps them out of Release).
    static func thumbnail(for url: URL) -> UIImage? {
        guard let index = articles.firstIndex(where: { $0.url == url.absoluteString }) else { return nil }
        return UIImage(named: "demo-thumb-\(index)")
    }

    /// The Read tab's Emerging lane: older demo bookmarks, as the real ranking would surface them.
    static func emergingItems() -> [EmergingItem] {
        [(5, "Reading", "Saved 6 weeks ago · matches ideas"), (4, "Travel", "Saved 2 months ago · matches travel"),
         (6, "Science", "Saved 3 months ago")].compactMap { index, folder, reason in
            let article = articles[index]
            guard let url = URL(string: article.url) else { return nil }
            return EmergingItem(id: "appstore-demo-emerging-\(index)", title: article.title, url: url,
                                domain: url.host() ?? "", badgeText: folder, reason: reason, lane: .forgotten)
        }
    }

    /// Clean shots: no TipKit tips, no "Search every Mac" card. Call before `Tips.configure`.
    static func hideTips() {
        Tips.hideAllTipsForTesting()
        let seen = MotionSeenState().dismissing(SearchEveryMacTipRow.tipID)
        UserDefaults.standard.set(seen.rawValue, forKey: "motionSeenState")
    }

    /// Fills the stores. Called once at launch, before the first screen appears.
    @MainActor
    static func seed() {
        let now = Date()
        let list = articles.reversed().map { article in
            SavedOnIPhoneLink(
                id: "appstore-demo-\(article.url.hashValue)",
                url: article.url,
                title: article.title,
                savedAt: now.addingTimeInterval(-article.hoursAgo * 3600)
            )
        }
        SavedOnIPhoneStore.shared.add(list)

        ReaderArticleCache.shared.save(transcriptArticle())
        for article in articles {
            guard let url = URL(string: article.url) else { continue }
            ReaderArticleCache.shared.save(ReaderArticle(
                title: article.title, byline: article.byline, siteName: article.siteName,
                content: article.html, excerpt: article.excerpt, url: url
            ))
            ReaderHighlightStore.shared.removeAll(for: url)
            for (index, highlight) in article.highlights.enumerated() {
                guard let range = serializedRange(of: highlight.text, in: article.html) else { continue }
                ReaderHighlightStore.shared.add(ReaderHighlight(
                    id: "appstore-demo-\(article.url.hashValue)-\(index)",
                    urlKey: url.readerCanonicalKey,
                    selectedText: highlight.text,
                    color: highlight.color,
                    serializedRange: range,
                    createdAt: now.addingTimeInterval(-article.hoursAgo * 3600 + Double(index) * 60),
                    title: article.title,
                    urlString: article.url,
                    tags: highlight.tags
                ))
            }
        }

        // Last Opened + the resume chip on the Read tab: part-read articles. The featured one
        // stays at 0 so the `reader` screen opens at its title.
        for article in articles where article.progress > 0 {
            guard let url = URL(string: article.url) else { continue }
            ReaderReadingProgress.shared.set(progress: article.progress, for: url)
            LastOpenedStore.shared.recordOpened(url: url, title: article.title)
            LastOpenedStore.shared.updateProgress(url: url, progress: article.progress)
        }
    }

    /// A demo Mac with open Safari/Chrome tabs and bookmarks in the sync cache.
    @MainActor
    static func seedMac() {
        let now = Date()
        let mac = SyncedDevice(id: "appstore-demo-mac", name: "MacBook Pro", modelName: "MacBook Pro",
                               lastSeenAt: now, appVersion: "1.6.0", kind: .mac)
        LocalCache.shared.updateDevice(mac)
        let tabs: [(String, String, String)] = [
            ("Safari", "The art of the unhurried read", articles[0].url),
            ("Safari", "A field guide to good typography", articles[2].url),
            ("Safari", "Walking Lisbon in a day", articles[4].url),
            ("Chrome", "Notes that compound: keeping ideas you can find again", articles[5].url),
            ("Chrome", "Q4 planning board", "https://boards.example.com/q4-planning"),
            ("Chrome", "Ten one-pot dinners for busy weeknights", articles[3].url),
            ("Chrome", "Why we should look up more often", articles[6].url),
            ("Safari", "How to take a real break", articles[1].url)
        ]
        for (index, tab) in tabs.enumerated() {
            LocalCache.shared.updateTab(SyncedTab(
                id: "appstore-demo-tab-\(index)", deviceID: mac.id, browserName: tab.0, title: tab.1, url: tab.2,
                timestamp: now.addingTimeInterval(-Double(index) * 600),
                windowIndex: 0, tabIndex: index, tabID: index + 1
            ))
        }
        let bookmarks: [(String, String, String)] = [
            ("", "The art of the unhurried read", articles[0].url),
            ("", "Notes that compound: keeping ideas you can find again", articles[5].url),
            ("", "A field guide to good typography", articles[2].url),
            ("Travel", "Walking Lisbon in a day", articles[4].url),
            ("Cooking", "Ten one-pot dinners for busy weeknights", articles[3].url),
            ("Health", "How to take a real break", articles[1].url),
            ("Science", "Why we should look up more often", articles[6].url)
        ]
        for browser in ["Safari", "Chrome"] {
            let items = bookmarks.enumerated().map { index, bookmark in
                SyncedBookmarkItem(id: "appstore-demo-\(browser)-\(index)", title: bookmark.1, url: bookmark.2,
                                   folderPath: bookmark.0.isEmpty ? "Bookmarks Bar" : "Bookmarks Bar/\(bookmark.0)",
                                   dateAdded: now.addingTimeInterval(-Double(index + 1) * 86_400))
            }
            LocalCache.shared.updateBookmarkBlob(SyncedBookmarkBlob(
                deviceID: mac.id, browserName: browser, profileName: "Default",
                bookmarks: browser == "Safari" ? items.filter { $0.folderPath == "Bookmarks Bar" } : items.filter { $0.folderPath != "Bookmarks Bar" }
            ))
        }
    }

    /// The reader's highlight anchor (`serializeRange` in reader_template.html): the passage's
    /// UTF-16 offset in the article body's text, which for this tag-only HTML is the HTML minus tags.
    static func serializedRange(of text: String, in html: String) -> String? {
        let bodyText = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression) as NSString
        let found = bodyText.range(of: text)
        guard found.location != NSNotFound else { return nil }
        let desc: [String: Any] = ["text": text, "start": found.location, "len": (text as NSString).length]
        guard let data = try? JSONSerialization.data(withJSONObject: desc) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
#endif
