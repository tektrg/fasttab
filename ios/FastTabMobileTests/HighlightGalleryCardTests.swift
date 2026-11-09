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
        XCTAssertLessThan(HighlightGalleryCard.estimatedHeight(huge, columnWidth: 170), 500)
    }

    // MARK: Render (light + dark, gallery of cards with every slot filled)

    func testGalleryOfCardsRendersInLightAndDark() {
        let entries = [
            entry(tags: ["Habits", "Identity", "Work/Research/AI papers/Long reads to finish"]),
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
            .background(DS.Palette.canvas)
            .environment(\.colorScheme, scheme)
            // A real window, not ImageRenderer: the gallery needs a layout pass to learn its width
            // (it stays hidden until then) and lazy stacks only build cards inside a live hierarchy.
            let host = UIHostingController(rootView: view)
            host.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
            window.rootViewController = host
            window.makeKeyAndVisible()
            for _ in 0..<5 {
                host.view.layoutIfNeeded()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
            }
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            window.isHidden = true
            // For eyeballing: the simulator can write to the host's /tmp.
            try? image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/highlights-gallery-\(scheme == .dark ? "dark" : "light").png"))
            // Cards drawn = many distinct colours (text, chips, colour bar); a blank canvas has few.
            XCTAssertGreaterThan(Self.distinctColorCount(image), 40, "gallery rendered blank in \(scheme)")
        }
    }

    /// Distinct colours on a coarse grid of the image (cheap "is anything drawn" check).
    private static func distinctColorCount(_ image: UIImage) -> Int {
        guard let cg = image.cgImage, let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return 0 }
        var seen = Set<UInt32>()
        let bpp = cg.bitsPerPixel / 8
        for y in stride(from: 0, to: cg.height, by: 6) {
            for x in stride(from: 0, to: cg.width, by: 6) {
                let o = y * cg.bytesPerRow + x * bpp
                seen.insert(UInt32(bytes[o]) << 16 | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]))
            }
        }
        return seen.count
    }
}
