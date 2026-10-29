#if DEBUG
import Foundation
import FastTabSync

/// Made-up reading library for App Store screenshots. Debug builds only.
///
/// Launch with `-FastTabAppStoreDemo YES` (plus `-FastTabAppMode standalone`,
/// `-FastTabStatsDemo YES`, `-onboarding.v1.completed YES`): the FastTab List, reader
/// cache, highlights and last-opened list are filled with the articles below, and sync
/// stays off so nothing reaches iCloud. `-FastTabDemoScreen <name>` picks the opening
/// screen (`AppStoreDemo.Screen`). Driven by `marketing/appstore/tools/capture.sh`, which
/// backs up the simulator's app data first and restores it afterwards.
///
/// Writes into the app's normal stores, so only run it on a simulator.
enum AppStoreDemo {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "FastTabAppStoreDemo") }

    enum Screen: String {
        case read, reader, highlights, more, shuffle
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
