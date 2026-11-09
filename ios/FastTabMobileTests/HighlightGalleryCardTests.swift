import XCTest
import SwiftUI
import IndieGallery
import IndieTags
@testable import FastTabMobile

@MainActor
final class HighlightGalleryCardTests: XCTestCase {

    private func entry(text: String = "Every action you take is a vote for the type of person you wish to become.",
                       title: String = "Habits shape identity",
                       tags: [String] = [], comments: [String] = [], created: Date = .now) -> HighlightFeedEntry {
        HighlightFeedEntry(
            highlight: ReaderHighlight(id: UUID().uuidString, urlKey: "https://a.com/1", selectedText: text,
                                       color: .yellow, serializedRange: "{}", createdAt: created, tags: tags),
            articleTitle: title, folderTags: [], comments: comments)
    }

    // MARK: Meta line

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    func testMetaTodayAndYesterday() {
        let now = date(2026, 11, 9, 15)
        XCTAssertTrue(HighlightGalleryCard.metaText(for: date(2026, 11, 9, 9), now: now, calendar: calendar).hasPrefix("Today, "))
        XCTAssertTrue(HighlightGalleryCard.metaText(for: date(2026, 11, 8, 20), now: now, calendar: calendar).hasPrefix("Yesterday, "))
    }

    func testMetaOlderDatesAddYearOnlyWhenNotThisYear() {
        let now = date(2026, 11, 9)
        let thisYear = HighlightGalleryCard.metaText(for: date(2026, 3, 8), now: now, calendar: calendar)
        let lastYear = HighlightGalleryCard.metaText(for: date(2025, 3, 8), now: now, calendar: calendar)
        XCTAssertFalse(thisYear.contains("2026"), thisYear)
        XCTAssertTrue(lastYear.contains("2025"), lastYear)
    }

    // MARK: Height estimate (column balancing)

    func testEstimateGrowsWithTextTagsAndCommentsAndNarrowColumns() {
        let short = entry(text: "Short.")
        let long = entry(text: String(repeating: "A long highlighted passage. ", count: 8))
        XCTAssertGreaterThan(HighlightGalleryCard.estimatedHeight(long, columnWidth: 170),
                             HighlightGalleryCard.estimatedHeight(short, columnWidth: 170))
        XCTAssertGreaterThan(HighlightGalleryCard.estimatedHeight(entry(tags: ["a", "b", "c"]), columnWidth: 170),
                             HighlightGalleryCard.estimatedHeight(entry(), columnWidth: 170))
        XCTAssertGreaterThan(HighlightGalleryCard.estimatedHeight(entry(comments: ["Nice"]), columnWidth: 170),
                             HighlightGalleryCard.estimatedHeight(entry(), columnWidth: 170))
        XCTAssertGreaterThanOrEqual(HighlightGalleryCard.estimatedHeight(long, columnWidth: 160),
                                    HighlightGalleryCard.estimatedHeight(long, columnWidth: 360))
    }

    func testEstimateIsCappedByLineLimits() {
        let huge = entry(text: String(repeating: "word ", count: 2000), title: String(repeating: "T", count: 900))
        XCTAssertLessThan(HighlightGalleryCard.estimatedHeight(huge, columnWidth: 170), 400)
    }

    // MARK: Render (light + dark, gallery of cards with every slot filled)

    func testGalleryOfCardsRendersInLightAndDark() {
        let entries = [
            entry(tags: ["Habits", "Identity"]),
            entry(text: "Hard things are hard because there are no easy answers.", title: "No clean getaways",
                  tags: ["Leadership"], comments: ["So true", "Agree"]),
            entry(text: "Your time is limited.", title: "Time is limited",
                  created: Date(timeIntervalSinceNow: -86_400 * 40)),
        ]
        for scheme in [ColorScheme.light, .dark] {
            let view = ScrollView {
                IndieGallery(entries, estimatedHeight: HighlightGalleryCard.estimatedHeight) { e in
                    HighlightGalleryCard(entry: e, filter: .constant(HighlightFeedFilter()))
                }
                .padding(16)
            }
            .indieGalleryStyle(.fastTab)
            .frame(width: 390, height: 700)
            .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = renderer.uiImage
            XCTAssertNotNil(image, "\(scheme)")
            XCTAssertGreaterThan(image?.size.width ?? 0, 300)
        }
    }
}
