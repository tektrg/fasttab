import Foundation
import Testing
import IndieSearch
@testable import FastTab

private func makeResult(
    title: String,
    url: String,
    type: BrowserResultType = .history,
    timestamp: Date = Date(timeIntervalSince1970: 1_000_000),
    browserName: String = "Chrome"
) -> BrowserSearchResult {
    BrowserSearchResult(
        title: title,
        url: url,
        browserName: browserName,
        type: type,
        timestamp: timestamp
    )
}

// MARK: - Word matching

@Test func typedWordsMatchAcrossJoinedAndSeparatedTitleWords() async throws {
    let result = makeResult(
        title: "Realtime e-commerce order | Bi Hub",
        url: "https://bihub.sevensystem.vn/dashboards/42"
    )

    #expect(result.matches(query: "real time bi hub"))
    #expect(result.matches(query: "bi hub real time"))
    #expect(result.matches(query: "e commerce order"))
    #expect(!result.matches(query: "real time invoice"))
}

@Test func typedWordsMatchAgainstDomainAsWellAsTitle() async throws {
    let result = makeResult(
        title: "Realtime e-commerce order | Bi Hub",
        url: "https://bihub.sevensystem.vn/dashboards/42"
    )

    #expect(result.matches(query: "real time sevensystem"))
    #expect(result.matches(query: "sevensystem.vn"))
    #expect(!result.matches(query: "real time othersystem"))
}

@Test func matchingIgnoresAccentsInBothDirections() async throws {
    let result = makeResult(title: "Đơn hàng đã giao", url: "https://shop.example.com/don-hang")

    #expect(result.matches(query: "don hang"))
    #expect(result.matches(query: "Đơn hàng"))
    #expect(result.matches(query: "DON HANG"))
    #expect(result.matches(query: "da giao"))
    #expect(!result.matches(query: "don huy"))
}

@Test func emptyOrPunctuationOnlyQueryMatchesEverything() async throws {
    let result = makeResult(title: "Anything", url: "https://example.com")

    #expect(result.matches(query: ""))
    #expect(result.matches(query: "   "))
    #expect(result.matches(query: "--- ..."))
}

// MARK: - SQL predicate

@Test func historyGlobPatternCoversCaseAndAccentVariants() async throws {
    let pattern = historySearchGlobPattern(for: "don")

    #expect(pattern.hasPrefix("*"))
    #expect(pattern.hasSuffix("*"))
    #expect(pattern.contains("[dDđĐ]"))
    // The "o" class must reach the Vietnamese horn-and-tone forms.
    #expect(pattern.contains("ơ"))
    #expect(pattern.contains("ồ"))
}

@Test func historyGlobPatternNeverEmitsUnescapedGlobMetacharacters() async throws {
    // Metacharacters can only legally appear as the class delimiters we emit.
    for word in searchWords(in: "a*b?c[d]e^f-g 'quoted'") {
        let pattern = historySearchGlobPattern(for: word)
        #expect(!pattern.contains("*") || pattern.hasPrefix("*"))
        #expect(!pattern.contains("?"))
        #expect(!pattern.contains("'"))
        #expect(!pattern.contains("^"))
    }
}

@Test func historySQLPredicateRequiresEveryWordInEitherColumn() async throws {
    let predicate = historySearchSQLPredicate(query: "bi hub", urlColumn: "url", titleColumn: "title")

    // One AND-ed group per word, each an OR across both columns.
    #expect(predicate.components(separatedBy: " AND ").count == 2)
    #expect(predicate.contains("url GLOB"))
    #expect(predicate.contains("title GLOB"))
}

/// Regression guard: Foundation rewrites process arguments to Unicode NFD, so
/// any accented character left in the SQL would reach `sqlite3` decomposed and
/// break every accent class. The predicate must stay pure ASCII.
@Test func historySQLPredicateStaysASCIISoProcessArgumentsSurviveIntact() async throws {
    let predicate = historySearchSQLPredicate(query: "Đơn hàng", urlColumn: "url", titleColumn: "title")

    #expect(predicate.unicodeScalars.allSatisfy { $0.isASCII })
    #expect(predicate.contains("char(0x"))
}

@Test func historySQLPredicateMatchesEverythingForEmptyQuery() async throws {
    #expect(historySearchSQLPredicate(query: "", urlColumn: "url", titleColumn: "title") == "1")
    #expect(historySearchSQLPredicate(query: "   ", urlColumn: "url", titleColumn: "title") == "1")
}

// MARK: - Real SQLite behaviour

/// Runs the real generated predicate against a throwaway SQLite file seeded
/// with `rows` of (title, url) and returns the matching titles. Guards the part
/// unit tests can't cover: that the generated GLOB is valid SQLite syntax and
/// that its character classes really do match accented, mixed-case stored text.
///
/// The script is fed over **stdin**, not as a process argument. Foundation
/// rewrites arguments to Unicode NFD, which would seed the table with
/// decomposed titles — unlike the precomposed text browsers actually store, so
/// the test would be measuring the wrong thing.
func titlesMatchingInSQLite(query: String, rows: [(title: String, url: String)]) throws -> [String] {
    let scratchDirectory = NSTemporaryDirectory() + "fasttab-glob-\(UUID().uuidString)/"
    try FileManager.default.createDirectory(atPath: scratchDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: scratchDirectory) }

    let inserts = rows.map { row in
        let title = row.title.replacingOccurrences(of: "'", with: "''")
        let url = row.url.replacingOccurrences(of: "'", with: "''")
        return "INSERT INTO urls (title, url) VALUES ('\(title)', '\(url)');"
    }.joined(separator: "\n")

    let predicate = historySearchSQLPredicate(query: query, urlColumn: "url", titleColumn: "title")
    let scriptPath = scratchDirectory + "seed.sql"
    try """
    CREATE TABLE urls (title TEXT, url TEXT);
    \(inserts)
    SELECT title FROM urls WHERE \(predicate) ORDER BY title;
    """.write(toFile: scriptPath, atomically: true, encoding: .utf8)

    let sqlite = Process()
    sqlite.launchPath = "/usr/bin/sqlite3"
    sqlite.arguments = [scratchDirectory + "history.db"]
    sqlite.standardInput = try #require(FileHandle(forReadingAtPath: scriptPath))
    let stdout = Pipe()
    sqlite.standardOutput = stdout
    try sqlite.run()
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    sqlite.waitUntilExit()

    let text = try #require(String(data: data, encoding: .utf8))
    return text.split(separator: "\n").map(String.init)
}

@Test func sqliteFindsPageWhoseTitleSplitsTheTypedWordsDifferently() async throws {
    let matched = try titlesMatchingInSQLite(
        query: "real time bi hub",
        rows: [
            ("Realtime e-commerce order | Bi Hub", "https://bihub.sevensystem.vn/dashboards/42"),
            ("Realtime inventory | Warehouse", "https://warehouse.sevensystem.vn/stock")
        ]
    )

    #expect(matched == ["Realtime e-commerce order | Bi Hub"])
}

@Test func sqliteFindsPageByDomainWordFromTheURL() async throws {
    let matched = try titlesMatchingInSQLite(
        query: "real time sevensystem",
        rows: [
            ("Realtime e-commerce order | Bi Hub", "https://bihub.sevensystem.vn/dashboards/42"),
            ("Realtime standup notes", "https://notion.so/standup")
        ]
    )

    #expect(matched == ["Realtime e-commerce order | Bi Hub"])
}

@Test func sqliteMatchesAccentedTitlesFromAccentlessTyping() async throws {
    let rows = [
        ("Đơn hàng đã giao", "https://shop.example.com/orders"),
        ("Đơn hàng đã huỷ", "https://shop.example.com/cancelled")
    ]

    #expect(try titlesMatchingInSQLite(query: "don hang da giao", rows: rows) == ["Đơn hàng đã giao"])
    #expect(try titlesMatchingInSQLite(query: "DON HANG", rows: rows).count == 2)
}

@Test func sqliteEmptyQueryReturnsEveryRow() async throws {
    let matched = try titlesMatchingInSQLite(
        query: "",
        rows: [("First", "https://a.example.com"), ("Second", "https://b.example.com")]
    )

    #expect(matched == ["First", "Second"])
}

// MARK: - History page identity / dedup

@Test func historyPageIdentityDropsQueryFragmentWwwAndTrailingSlash() async throws {
    let canonical = "example.com/articles/launch"

    #expect(historyPageIdentity(forURL: "https://example.com/articles/launch") == canonical)
    #expect(historyPageIdentity(forURL: "https://www.example.com/articles/launch/") == canonical)
    #expect(historyPageIdentity(forURL: "https://example.com/articles/launch?utm_source=x") == canonical)
    #expect(historyPageIdentity(forURL: "https://example.com/articles/launch#section-2") == canonical)
    #expect(historyPageIdentity(forURL: "https://example.com/articles/other") != canonical)
}

@Test func historyDedupCollapsesSameTitleWhenOnlyTheUrlTailDiffers() async throws {
    let older = makeResult(
        title: "Launch plan",
        url: "https://example.com/plan?utm_source=newsletter",
        timestamp: Date(timeIntervalSince1970: 1_000_000)
    )
    let newer = makeResult(
        title: "Launch plan",
        url: "https://example.com/plan?ref=slack#top",
        timestamp: Date(timeIntervalSince1970: 2_000_000)
    )

    #expect(HistorySearchExpansion.canonicalHistoryKey(for: older)
        == HistorySearchExpansion.canonicalHistoryKey(for: newer))
}

@Test func historyDedupKeepsPagesApartWhenTitlesDiffer() async throws {
    let first = makeResult(title: "cats - Google Search", url: "https://google.com/search?q=cats")
    let second = makeResult(title: "dogs - Google Search", url: "https://google.com/search?q=dogs")

    #expect(HistorySearchExpansion.canonicalHistoryKey(for: first)
        != HistorySearchExpansion.canonicalHistoryKey(for: second))
}

@Test func historyDedupKeepsBrowsersApart() async throws {
    let chrome = makeResult(title: "Launch plan", url: "https://example.com/plan", browserName: "Chrome")
    let safari = makeResult(title: "Launch plan", url: "https://example.com/plan", browserName: "Safari")

    #expect(HistorySearchExpansion.canonicalHistoryKey(for: chrome)
        != HistorySearchExpansion.canonicalHistoryKey(for: safari))
}

@Test func historyDedupCollapsesAcrossLiveCountBadge() async throws {
    let badged = makeResult(title: "(2) Delivery Run - SpeechToDo | Notion", url: "https://notion.so/delivery-run")
    let unbadged = makeResult(title: "Delivery Run - SpeechToDo | Notion", url: "https://notion.so/delivery-run")

    #expect(HistorySearchExpansion.canonicalHistoryKey(for: badged)
        == HistorySearchExpansion.canonicalHistoryKey(for: unbadged))
}

@Test func strippingLeadingCountBadgeRemovesDigitPrefix() async throws {
    #expect(strippingLeadingCountBadge("(2) Delivery Run") == "Delivery Run")
    #expect(strippingLeadingCountBadge("(12) Inbox") == "Inbox")
    #expect(strippingLeadingCountBadge("(9+) Engineering AI Adoption Framework") == "Engineering AI Adoption Framework")
    #expect(strippingLeadingCountBadge("(99+) Notion") == "Notion")
    #expect(strippingLeadingCountBadge("[3] Slack") == "Slack")
    #expect(strippingLeadingCountBadge("• Unread document") == "Unread document")
    #expect(strippingLeadingCountBadge("* Unsaved file") == "Unsaved file")
}

@Test func strippingLeadingCountBadgeLeavesOtherTitlesUnchanged() async throws {
    #expect(strippingLeadingCountBadge("Delivery Run") == "Delivery Run")
    #expect(strippingLeadingCountBadge("(draft) Delivery Run") == "(draft) Delivery Run")
    #expect(strippingLeadingCountBadge("(2026) Strategy Plan") == "(2026) Strategy Plan")
}

