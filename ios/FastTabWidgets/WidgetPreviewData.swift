import Foundation

extension WidgetSnapshot {
    /// Sample content for the widget gallery and Xcode previews.
    static let preview: WidgetSnapshot = {
        func link(_ title: String, _ url: String) -> Link {
            let url = URL(string: url)!
            return Link(title: title, url: url, domain: url.host() ?? "")
        }
        let today = Calendar.current.startOfDay(for: Date())
        let wordsByDay = Dictionary(uniqueKeysWithValues: [2_100.0, 3_400, 3_050, 900, 3_600, 4_200, 3_300]
            .enumerated()
            .map { (Calendar.current.date(byAdding: .day, value: -$0.offset, to: today)!, $0.element) })
        return WidgetSnapshot(
            upNext: [
                link("The quiet power of plain text", "https://example.com/plain-text"),
                link("How SQLite is tested", "https://sqlite.org/testing.html"),
                link("Designing calm technology", "https://calmtech.com/"),
            ],
            reading: Reading(dailyWordGoal: 3_000, wordsByDay: wordsByDay),
            shuffle: Shuffle(
                item: link("A field guide to fermentation", "https://example.com/ferment"),
                badge: "Bookmarks/Cooking", highlightID: nil, thumbnailFileName: nil
            ),
            openTabs: OpenTabs(totalCount: 42, recent: [
                link("Pull request #812 · FastTab", "https://github.com/theindie/fasttab/pull/812"),
                link("WidgetKit | Apple Developer", "https://developer.apple.com/widgets/"),
                link("Hacker News", "https://news.ycombinator.com/"),
            ])
        )
    }()
}
