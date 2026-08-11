import Foundation
import Testing
@testable import FastTab

private func makeApp(
    name: String,
    homeURL: String,
    browserAppName: String = "Microsoft Edge",
    appBundleIdentifier: String? = nil
) -> InstalledWebApp {
    InstalledWebApp(
        name: name,
        homeURL: homeURL,
        browserAppName: browserAppName,
        appBundleIdentifier: appBundleIdentifier ?? "com.example.\(name.lowercased())"
    )
}

// MARK: - Route key

@Test func routeKeyIgnoresPathAndDefaultsPortByScheme() async throws {
    let a = webAppRouteKey(for: "https://calendar.notion.so/some/page?x=1")
    let b = webAppRouteKey(for: "https://calendar.notion.so/other/page")
    #expect(a == b)

    let httpsDefault = webAppRouteKey(for: "https://example.com")
    let httpsExplicit = webAppRouteKey(for: "https://example.com:443/path")
    #expect(httpsDefault == httpsExplicit)
}

@Test func routeKeyDistinguishesLoopbackApportsByPort() async throws {
    let sheetCanvas = webAppRouteKey(for: "http://127.0.0.1:5173/")
    let unifiedTasks = webAppRouteKey(for: "http://127.0.0.1:8787/")
    #expect(sheetCanvas != unifiedTasks)
}

@Test func routeKeyRejectsNonHTTPSchemes() async throws {
    #expect(webAppRouteKey(for: "chrome://password-manager/passwords") == nil)
    #expect(webAppRouteKeyString(for: "not a url") == nil)
}

// MARK: - Matching

@Test func matchResolvesDistinctAppsSharingAHostByPathSegment() async throws {
    let docs = makeApp(name: "Docs", homeURL: "https://docs.google.com/document/u/0/")
    let sheets = makeApp(name: "Sheets", homeURL: "https://docs.google.com/spreadsheets/u/0/")
    let slides = makeApp(name: "Slides", homeURL: "https://docs.google.com/presentation/u/0/")
    let apps = [docs, sheets, slides]

    let matchedDocs = matchInstalledWebApp(
        url: "https://docs.google.com/document/d/abc123/edit",
        browserName: "Microsoft Edge",
        in: apps
    )
    #expect(matchedDocs?.name == "Docs")

    let matchedSheets = matchInstalledWebApp(
        url: "https://docs.google.com/spreadsheets/d/xyz/edit",
        browserName: "Microsoft Edge",
        in: apps
    )
    #expect(matchedSheets?.name == "Sheets")
}

@Test func matchReturnsNilWhenPathSegmentIsAmbiguous() async throws {
    // Same first path segment, so the tie-break itself can't disambiguate.
    let a = makeApp(name: "A", homeURL: "https://docs.google.com/document/a/")
    let b = makeApp(name: "B", homeURL: "https://docs.google.com/document/b/")

    let matched = matchInstalledWebApp(
        url: "https://docs.google.com/document/c/edit",
        browserName: "Microsoft Edge",
        in: [a, b]
    )
    #expect(matched == nil)
}

@Test func matchRefusesCrossBrowserRouting() async throws {
    let chromeGmail = makeApp(name: "Gmail", homeURL: "https://mail.google.com/mail/", browserAppName: "Google Chrome")

    let matched = matchInstalledWebApp(
        url: "https://mail.google.com/mail/u/0/#inbox",
        browserName: "Microsoft Edge",
        in: [chromeGmail]
    )
    #expect(matched == nil)

    let matchedSameBrowser = matchInstalledWebApp(
        url: "https://mail.google.com/mail/u/0/#inbox",
        browserName: "Google Chrome",
        in: [chromeGmail]
    )
    #expect(matchedSameBrowser?.name == "Gmail")
}

@Test func matchReturnsNilForSiteWithNoInstalledApp() async throws {
    let notion = makeApp(name: "Notion Calendar", homeURL: "https://calendar.notion.so/")

    let matched = matchInstalledWebApp(
        url: "https://www.youtube.com/watch?v=abc",
        browserName: "Microsoft Edge",
        in: [notion]
    )
    #expect(matched == nil)
}

// MARK: - Live window selection

private struct FakeWindow {
    let url: String
}

@Test func selectWindowDisambiguatesByPathSegmentWhenTwoAppWindowsShareAHost() async throws {
    let docs = makeApp(name: "Docs", homeURL: "https://docs.google.com/document/u/0/")
    let sheets = makeApp(name: "Sheets", homeURL: "https://docs.google.com/spreadsheets/u/0/")
    // Both apps' windows are open at once, each already steered to a deep link.
    let windows = [
        FakeWindow(url: "https://docs.google.com/document/d/abc123/edit"),
        FakeWindow(url: "https://docs.google.com/spreadsheets/d/xyz/edit")
    ]

    let docsWindow = selectWindow(for: docs, among: windows, urlOf: \.url)
    #expect(docsWindow?.url == windows[0].url)

    let sheetsWindow = selectWindow(for: sheets, among: windows, urlOf: \.url)
    #expect(sheetsWindow?.url == windows[1].url)
}

@Test func selectWindowReturnsNilRatherThanGuessingWhenWindowsAreAmbiguous() async throws {
    let docs = makeApp(name: "Docs", homeURL: "https://docs.google.com/document/u/0/")
    // Two windows on the same site, same first path segment as each other —
    // can't tell which one is Docs's own window.
    let windows = [
        FakeWindow(url: "https://docs.google.com/document/d/one/edit"),
        FakeWindow(url: "https://docs.google.com/document/d/two/edit")
    ]

    #expect(selectWindow(for: docs, among: windows, urlOf: \.url) == nil)
}

@Test func selectWindowReturnsTheSoleMatchWhenOnlyOneWindowIsOpen() async throws {
    let notion = makeApp(name: "Notion Calendar", homeURL: "https://calendar.notion.so/")
    let windows = [FakeWindow(url: "https://calendar.notion.so/week/42")]

    #expect(selectWindow(for: notion, among: windows, urlOf: \.url)?.url == windows[0].url)
}
