import Foundation
import Testing
@testable import FastTab

private func makeResult(
    title: String,
    url: String = "https://example.com",
    type: BrowserResultType = .tab,
    folderPath: String? = nil
) -> BrowserSearchResult {
    BrowserSearchResult(
        title: title,
        url: url,
        browserName: "Google Chrome",
        type: type,
        timestamp: Date(),
        folderPath: folderPath
    )
}

@Test func urlPathSlugReturnsLastPathComponent() async throws {
    let result = makeResult(title: "Roadmap", url: "https://notion.so/team/roadmap")

    #expect(result.urlPathSlug == "roadmap")
}

@Test func urlPathSlugIsNilForBareDomain() async throws {
    let result = makeResult(title: "Google", url: "https://www.google.com")

    #expect(result.urlPathSlug == nil)
}

@Test func urlPathSlugIsNilWhenItMatchesTheTitle() async throws {
    let result = makeResult(title: "Q3 Report.pdf", url: "file:///Users/x/Documents/Q3 Report.pdf")

    #expect(result.urlPathSlug == nil)
}

@Test func urlPathSlugIsNilForUnparseableUrl() async throws {
    let result = makeResult(title: "Broken", url: "")

    #expect(result.urlPathSlug == nil)
}
