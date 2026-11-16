import XCTest
import WebKit
import UIKit
@testable import FastTabMobile

/// Heading font (separate from the body font): Fraunces, the one bundled font.
/// Covers the choice list, saved values from older builds, the CSS handed to the
/// reader page, the font + licence in the app bundle, and a real WebKit load.
@MainActor
final class ReaderHeadingFontTests: XCTestCase {

    private var suite: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ReaderHeadingFontTests.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeStore() -> ReaderReadingSettingsStore {
        ReaderReadingSettingsStore(local: suite, cloud: nil, isCloudSyncEnabled: false)
    }

    // MARK: - Choices + defaults

    func testChoicesAndDefaultUnchanged() {
        XCTAssertEqual(ReaderHeadingFont.allCases, [.matchBody, .fraunces])
        XCTAssertEqual(ReaderHeadingFont.fraunces.label, "Fraunces")
        XCTAssertNil(ReaderReadingSettings.defaults.headingFont)
        XCTAssertEqual(ReaderReadingSettings.defaults.effectiveHeadingFont, .matchBody)
    }

    /// "Match body" must render exactly what headings looked like before this setting.
    func testMatchBodyKeepsEveryFamilysOwnTitleStackAndBold() {
        for family in ReaderFontFamily.allCases {
            let s = ReaderReadingSettings(fontFamily: family)
            XCTAssertEqual(s.cssTitleStack, family.cssTitleStack, family.rawValue)
            XCTAssertEqual(s.cssBodyStack, family.cssBodyStack, family.rawValue)
            XCTAssertEqual(s.cssTitleWeight, 700, family.rawValue)
        }
    }

    func testFrauncesChangesHeadingsOnlyAtWeight400() {
        for family in ReaderFontFamily.allCases {
            let s = ReaderReadingSettings(fontFamily: family, headingFont: .fraunces)
            XCTAssertEqual(s.cssTitleStack, "'Fraunces', Georgia, serif", family.rawValue)
            XCTAssertEqual(s.cssBodyStack, family.cssBodyStack, "body must not change (\(family.rawValue))")
            XCTAssertEqual(s.cssTitleWeight, 400, family.rawValue)
        }
    }

    // MARK: - Saved values (UserDefaults + iCloud KVS share this JSON)

    /// A value saved by a build before the heading font existed (real field set, no `headingFont`).
    private let preHeadingFontFixture = """
    {"fontSize":20,"fontFamily":"georgia","colorScheme":"dark","lineHeight":"relaxed",
     "lightBackgroundHex":"#F5EFDC","darkBackgroundHex":"#000000","speechRate":1.25,
     "updatedAt":784000000}
    """

    func testOldStoredValueStillLoadsWithBodyMatchingHeadings() throws {
        suite.set(Data(preHeadingFontFixture.utf8), forKey: ReaderReadingSettingsStore.defaultsKey)
        let s = makeStore().settings
        XCTAssertEqual(s.fontFamily, .georgia)
        XCTAssertEqual(s.fontSize, 20)
        XCTAssertEqual(s.speechRate, 1.25)
        XCTAssertNil(s.headingFont)
        XCTAssertEqual(s.cssTitleStack, ReaderFontFamily.georgia.cssTitleStack)
    }

    /// A later build may add another heading font; this build must not drop the whole settings value.
    func testUnknownHeadingFontFallsBackToMatchBodyAndKeepsOtherFields() throws {
        let json = preHeadingFontFixture.replacingOccurrences(
            of: "\"speechRate\"", with: "\"headingFont\":\"someFutureFont\",\"speechRate\"")
        let s = try JSONDecoder().decode(ReaderReadingSettings.self, from: Data(json.utf8))
        XCTAssertEqual(s.effectiveHeadingFont, .matchBody)
        XCTAssertEqual(s.fontFamily, .georgia)
    }

    func testFrauncesPersistsAndMatchBodyStoresNothing() throws {
        let store = makeStore()
        store.setHeadingFont(.fraunces)
        XCTAssertEqual(makeStore().settings.headingFont, .fraunces)
        XCTAssertFalse(makeStore().settings.isAppearanceDefault)

        let data = try XCTUnwrap(suite.data(forKey: ReaderReadingSettingsStore.defaultsKey))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"headingFont\":\"fraunces\""))

        store.setHeadingFont(.matchBody)
        XCTAssertNil(makeStore().settings.headingFont)
        XCTAssertTrue(makeStore().settings.isAppearanceDefault)
    }

    func testAppearanceResetClearsHeadingFont() {
        let store = makeStore()
        store.setHeadingFont(.fraunces)
        store.resetAppearanceToDefaults()
        XCTAssertNil(makeStore().settings.headingFont)
    }

    // MARK: - Reader page CSS

    func testSettingsJSCarriesFrauncesStackAndWeight() {
        let s = ReaderReadingSettings(fontFamily: .systemSans, headingFont: .fraunces)
        let js = ReaderWebView.settingsJS(settings: s, theme: .resolve(backgroundHex: "#FAFAF8"))
        XCTAssertTrue(js.contains("r.setProperty('--reader-font-title','\\'Fraunces\\', Georgia, serif')"), js)
        XCTAssertTrue(js.contains("r.setProperty('--reader-title-weight','400')"), js)
        XCTAssertTrue(js.contains("r.setProperty('--reader-title-strong-weight','400')"), js)
        let plain = ReaderWebView.settingsJS(settings: ReaderReadingSettings(), theme: .resolve(backgroundHex: "#FAFAF8"))
        XCTAssertTrue(plain.contains("r.setProperty('--reader-title-strong-weight','bolder')"), plain)
        XCTAssertTrue(js.contains("r.setProperty('--reader-font-body','\(ReaderFontFamily.systemSans.cssBodyStack.replacingOccurrences(of: "\\", with: "\\\\"))')"))
    }

    func testFontFaceEmbedsTheWholeFontAsData() throws {
        let css = try XCTUnwrap(ReaderBundledFont.fontFaceCSS)
        XCTAssertEqual(css.components(separatedBy: "@font-face{font-family:'Fraunces'").count - 1, 2,
                       "one face per subset (latin + vietnamese)")
        XCTAssertEqual(css.components(separatedBy: "font-weight:100 900").count - 1, 2)
        for subset in ReaderBundledFont.subsets {
            let data = try XCTUnwrap(ReaderBundledFont.data(subset), subset.resource)
            XCTAssertTrue(css.contains("src:url(data:font/woff2;base64,\(data.base64EncodedString())) format('woff2')"))
            XCTAssertTrue(css.contains("unicode-range:\(subset.unicodeRange);"), subset.resource)
        }
        XCTAssertTrue(ReaderBundledFont.vietnamese.unicodeRange.contains("U+1EA0-1EF9"))
    }

    func testTemplateGetsFontFaceAndBootstrap() throws {
        let html = try XCTUnwrap(ReaderWebView.templateHTML(bootstrapJSON: "{\"title\":\"T\"}"))
        XCTAssertTrue(html.contains("<style id=\"ft-bundled-fonts\">@font-face{font-family:'Fraunces'"))
        XCTAssertTrue(html.contains("<script id=\"fasttab-article-data\" type=\"application/json\">"))
        XCTAssertFalse(html.contains("<!-- FONTS -->"))
        XCTAssertFalse(html.contains("<!-- BOOTSTRAP -->"))
    }

    // MARK: - App bundle

    func testFontAndLicenceShipInTheApp() throws {
        let fontURL = try XCTUnwrap(Bundle.main.url(forResource: "fraunces-latin", withExtension: "woff2"))
        let font = try Data(contentsOf: fontURL)
        XCTAssertEqual(font.prefix(4), Data("wOF2".utf8))
        XCTAssertEqual(font.count, 67_388)
        let viURL = try XCTUnwrap(Bundle.main.url(forResource: "fraunces-vietnamese", withExtension: "woff2"))
        let vi = try Data(contentsOf: viURL)
        XCTAssertEqual(vi.prefix(4), Data("wOF2".utf8))
        XCTAssertEqual(vi.count, 19_748)

        let licenceURL = try XCTUnwrap(Bundle.main.url(forResource: "Fraunces-OFL", withExtension: "txt"))
        let licence = try String(contentsOf: licenceURL, encoding: .utf8)
        XCTAssertTrue(licence.contains("The Fraunces Project Authors"))
        XCTAssertTrue(licence.contains("SIL OPEN FONT LICENSE Version 1.1"))
    }

    /// Settings preview row draws real Fraunces, at 400 (the file's own default is 900).
    func testNativePreviewFontIsFrauncesAt400() throws {
        let font = try XCTUnwrap(ReaderBundledFont.frauncesUIFont(size: 20))
        XCTAssertEqual(font.familyName, "Fraunces")
        let variations = CTFontCopyVariation(font as CTFont) as? [NSNumber: NSNumber]
        XCTAssertEqual(variations?[NSNumber(value: ReaderBundledFont.weightAxisTag)]?.doubleValue, 400)
        // Optical size follows the point size, like the page (WebKit's font-optical-sizing: auto).
        XCTAssertEqual(variations?[NSNumber(value: ReaderBundledFont.opticalSizeAxisTag)]?.doubleValue, 20)
        // Vietnamese-only letters resolve to Fraunces too (vietnamese subset in the cascade list).
        for letter in ["ư", "đ", "ệ", "ỗ"] {
            let used = CTFontCreateForString(font as CTFont, letter as CFString, CFRange(location: 0, length: 1))
            XCTAssertEqual(CTFontCopyFamilyName(used) as String, "Fraunces", letter)
        }
    }

    // MARK: - Real WebKit load (offline, article's own https origin)

    func testReaderPageLoadsFrauncesOfflineFromAnArticleOrigin() async throws {
        let s = ReaderReadingSettings(fontFamily: .systemSans, headingFont: .fraunces)
        let webView = try await loadReaderPage(settings: s, title: "A quiet morning", heading: "Field notes")

        let loaded = try await webView.callAsyncJavaScript(
            "return (await document.fonts.load('400 24px Fraunces', 'Field')).length",
            contentWorld: .page) as? Int
        XCTAssertEqual(loaded, 1, "Fraunces face did not load")

        let probe = try await webView.evaluateJavaScript("""
        (function(){var t=getComputedStyle(document.getElementById('reader-title'));
        var h=getComputedStyle(document.querySelector('#reader-body h2'));
        var p=getComputedStyle(document.querySelector('#reader-body p'));
        return [t.fontFamily, t.fontWeight, h.fontFamily, h.fontWeight, p.fontFamily].join('|');})()
        """) as? String
        let parts = try XCTUnwrap(probe).components(separatedBy: "|")
        XCTAssertTrue(parts[0].hasPrefix("Fraunces"), parts[0])
        XCTAssertEqual(parts[1], "400")
        XCTAssertTrue(parts[2].hasPrefix("Fraunces"), parts[2])
        XCTAssertEqual(parts[3], "400")
        XCTAssertFalse(parts[4].contains("Fraunces"), "body must keep its own font: \(parts[4])")
    }

    /// WordPress-style `<h2><strong>…</strong></h2>`: Fraunces stays 400 like plain headings;
    /// "Same as body" keeps the browser's one-step-bolder (900), as before this feature.
    func testBoldTagsInsideHeadings() async throws {
        let probe = "getComputedStyle(document.querySelector('#reader-body h2 strong')).fontWeight"
        let fraunces = try await loadReaderPage(settings: ReaderReadingSettings(headingFont: .fraunces),
                                                title: "T", heading: "<strong>Why it matters</strong>")
        let frauncesWeight = try await fraunces.evaluateJavaScript(probe) as? String
        XCTAssertEqual(frauncesWeight, "400")
        let plain = try await loadReaderPage(settings: ReaderReadingSettings(), title: "T",
                                             heading: "<strong>Why it matters</strong>")
        let plainWeight = try await plain.evaluateJavaScript(probe) as? String
        XCTAssertEqual(plainWeight, "900")
    }

    /// Summary headings in Fraunces grow with iPhone text size exactly when the body font does.
    func testDynamicTypeScalingFollowsBodyFamily() {
        XCTAssertEqual(ReaderFontFamily.allCases.filter(\.scalesWithDynamicType),
                       [.georgia, .palatino, .helvetica, .charter].sorted { a, b in
                           ReaderFontFamily.allCases.firstIndex(of: a)! < ReaderFontFamily.allCases.firstIndex(of: b)! })
    }

    /// Vietnamese headings: both subsets load, so ă đ ơ ư and stacked tones stay Fraunces.
    func testVietnameseHeadingLoadsBothFrauncesSubsets() async throws {
        let s = ReaderReadingSettings(headingFont: .fraunces)
        let webView = try await loadReaderPage(settings: s, title: "Người Việt đọc tin tức mỗi sáng", heading: "Thời tiết")
        let faces = try await webView.callAsyncJavaScript(
            "return (await document.fonts.load('400 24px Fraunces', 'Người Việt đọc tin tức mỗi sáng')).length",
            contentWorld: .page) as? Int
        XCTAssertEqual(faces, 2, "latin + vietnamese Fraunces faces")
        let covered = try await webView.callAsyncJavaScript(
            "return document.fonts.check('400 24px Fraunces', 'ăđơưệọỗ')", contentWorld: .page) as? Bool
        XCTAssertEqual(covered, true)
    }

    func testMatchBodyPageKeepsBoldSystemHeadings() async throws {
        let webView = try await loadReaderPage(settings: ReaderReadingSettings(), title: "T", heading: "H")
        let weight = try await webView.evaluateJavaScript(
            "getComputedStyle(document.querySelector('#reader-body h2')).fontWeight") as? String
        XCTAssertEqual(weight, "700")
        let family = try await webView.evaluateJavaScript(
            "getComputedStyle(document.querySelector('#reader-body h2')).fontFamily") as? String
        XCTAssertFalse(family?.contains("Fraunces") ?? true)
    }

    // MARK: - Helpers

    private func loadReaderPage(settings: ReaderReadingSettings, title: String, heading: String,
                                width: CGFloat = 393) async throws -> WKWebView {
        let html = try XCTUnwrap(ReaderHeadingFontRender.pageHTML(settings: settings, title: title, heading: heading))
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: 700))
        let delegate = LoadWaiter()
        webView.navigationDelegate = delegate
        webView.loadHTMLString(html, baseURL: URL(string: "https://example.com/article"))
        try await delegate.wait()
        return webView
    }
}

/// Builds a reader page exactly as `ReaderWebView.loadTemplate` does, for a fixed article.
@MainActor
enum ReaderHeadingFontRender {
    static func pageHTML(settings: ReaderReadingSettings, title: String, heading: String,
                         paragraph: String = "The quick brown fox jumps over the lazy dog.") -> String? {
        let theme = ReaderResolvedTheme.resolve(backgroundHex: settings.effectiveBackgroundHex(systemIsDark: false))
        let bootstrap: [String: Any] = [
            "title": title, "byline": "", "siteName": "example.com",
            "content": "<p>\(paragraph)</p><h2>\(heading)</h2><p>\(paragraph)</p>",
            "fontSize": settings.fontSize, "fontBody": settings.cssBodyStack,
            "fontTitle": settings.cssTitleStack, "titleWeight": settings.cssTitleWeight,
            "titleStrongWeight": settings.cssTitleStrongWeight,
            "lineHeight": settings.lineHeight.value, "theme": "light", "bg": theme.backgroundHex,
            "fg": theme.foregroundHex, "highlights": [Any](), "transcriptTexts": [Any](),
            "locationBadges": [Any](), "deleteLabel": "Delete", "readAgainLabel": "Read Again",
            "initialProgress": 0, "videoVisible": false, "videoLarge": false,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: bootstrap),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return ReaderWebView.templateHTML(bootstrapJSON: json.replacingOccurrences(of: "</", with: "<\\/"))
    }
}

final class LoadWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    func wait() async throws {
        if let result { return try result.get() }
        try await withCheckedThrowingContinuation { self.continuation = $0 }
    }

    private func finish(_ r: Result<Void, Error>) {
        guard result == nil else { return }
        result = r
        continuation?.resume(with: r)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(.success(())) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) { finish(.failure(error)) }
}

/// Visual proof, skipped unless `FRAUNCES_RENDER_DIR` is set (xcodebuild: `TEST_RUNNER_FRAUNCES_RENDER_DIR`).
/// Real reader pages, current headings vs Fraunces, English + Vietnamese → `<dir>/sheet.png`.
@MainActor
final class ReaderHeadingFontRenderSheet: XCTestCase {
    func testRenderSheet() async throws {
        guard let dir = ProcessInfo.processInfo.environment["FRAUNCES_RENDER_DIR"], !dir.isEmpty else {
            throw XCTSkip("set FRAUNCES_RENDER_DIR to render")
        }
        let samples: [(lang: String, title: String, heading: String, paragraph: String)] = [
            ("English", "The Quiet Return of Slow Reading",
             "Why long articles still matter",
             "Readers who finish long pieces remember more of them, and they come back for the next one."),
            ("Vietnamese", "Người Việt đọc tin tức mỗi sáng",
             "Những điều cần biết về thời tiết hôm nay",
             "Trời Hà Nội sáng nay se lạnh, chiều có mưa rải rác ở vùng ngoại thành."),
        ]
        let columns: [(label: String, settings: ReaderReadingSettings)] = [
            ("Current (System, bold)", ReaderReadingSettings()),
            ("Fraunces 400", ReaderReadingSettings(headingFont: .fraunces)),
        ]
        let cell = CGSize(width: 393, height: 330)
        var shots: [[UIImage]] = []
        for sample in samples {
            var row: [UIImage] = []
            for column in columns {
                let html = try XCTUnwrap(ReaderHeadingFontRender.pageHTML(
                    settings: column.settings, title: sample.title, heading: sample.heading, paragraph: sample.paragraph))
                let webView = WKWebView(frame: CGRect(origin: .zero, size: cell))
                // Must sit in a window on the app's scene, or WebKit never paints (blank snapshot).
                let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
                let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
                window.frame = webView.frame
                window.rootViewController = UIViewController()
                window.rootViewController?.view.addSubview(webView)
                window.makeKeyAndVisible()
                defer { window.isHidden = true }
                let waiter = LoadWaiter()
                webView.navigationDelegate = waiter
                webView.loadHTMLString(html, baseURL: URL(string: "https://example.com/article"))
                try await waiter.wait()
                _ = try await webView.callAsyncJavaScript("await document.fonts.ready; return 1", contentWorld: .page)
                try await Task.sleep(nanoseconds: 800_000_000)
                let shot = try await webView.takeSnapshot(configuration: nil)
                // A painted page has its text; an unpainted one is a single flat colour.
                XCTAssertGreaterThan(Self.distinctColours(shot), 8, "\(sample.lang) / \(column.label) snapshot is blank")
                row.append(shot)
            }
            shots.append(row)
        }

        let labelH: CGFloat = 34, gap: CGFloat = 12
        let size = CGSize(width: CGFloat(columns.count) * (cell.width + gap) + gap,
                          height: labelH + CGFloat(samples.count) * (cell.height + labelH + gap) + gap)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor(white: 0.86, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let bold = [NSAttributedString.Key.font: UIFont.boldSystemFont(ofSize: 15)]
            for (c, column) in columns.enumerated() {
                (column.label as NSString).draw(at: CGPoint(x: gap + CGFloat(c) * (cell.width + gap), y: 10), withAttributes: bold)
            }
            for (r, sample) in samples.enumerated() {
                let y = labelH + CGFloat(r) * (cell.height + labelH + gap)
                (sample.lang as NSString).draw(at: CGPoint(x: gap, y: y + 8), withAttributes: bold)
                for (c, shot) in shots[r].enumerated() {
                    shot.draw(in: CGRect(x: gap + CGFloat(c) * (cell.width + gap), y: y + labelH,
                                         width: cell.width, height: cell.height))
                }
            }
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: dir).appendingPathComponent("sheet.png"))
    }

    private static func distinctColours(_ image: UIImage) -> Int {
        guard let cg = image.cgImage, let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return 0 }
        var seen = Set<UInt32>()
        let stride = max(1, cg.bytesPerRow * cg.height / 4 / 4000)
        for i in Swift.stride(from: 0, to: cg.bytesPerRow * cg.height - 4, by: stride * 4) {
            seen.insert(UInt32(bytes[i]) << 16 | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]))
        }
        return seen.count
    }
}
