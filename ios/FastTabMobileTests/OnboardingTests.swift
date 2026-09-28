import XCTest
import FastTabSync
@testable import FastTabMobile

/// First-run guide logic: routing, the completion flag, Mac detection, the
/// Reader demo pick, the bundled sample, and when Read/Tabs show the sync banner.
@MainActor
final class OnboardingTests: XCTestCase {

    // MARK: - Route

    func testFullGuideWalksEveryStepThenFinishes() {
        var route = OnboardingRoute.fullGuide
        var visited = [route.current]
        while route.advance() { visited.append(route.current) }
        XCTAssertEqual(visited, [.welcome, .connectMac, .tryReader, .sendToMac, .done])
        XCTAssertTrue(route.isLast)
        XCTAssertFalse(route.advance(), "advancing past the last step asks the host to finish")
    }

    func testBackStopsAtFirstStep() {
        var route = OnboardingRoute.fullGuide
        route.goBack()
        XCTAssertEqual(route.current, .welcome)
        _ = route.advance()
        route.goBack()
        XCTAssertEqual(route.current, .welcome)
        XCTAssertTrue(route.isFirst)
    }

    func testSingleStepRouteFinishesOnFirstContinue() {
        var route = OnboardingRoute.single(.connectMac)
        XCTAssertTrue(route.isSingleStep)
        XCTAssertEqual(route.current, .connectMac)
        XCTAssertFalse(route.advance())
    }

    func testPresentationsMapToRoutes() {
        XCTAssertEqual(OnboardingPresentation.fullGuide.route, .fullGuide)
        XCTAssertEqual(OnboardingPresentation.singleStep(.sendToMac).route, .single(.sendToMac))
    }

    // MARK: - Completion flag

    private func makeDefaults() -> UserDefaults {
        let suiteName = "OnboardingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    func testCompletionKeyMatchesMacApp() {
        XCTAssertEqual(OnboardingCompletionStore.completedKey, "onboarding.v1.completed")
    }

    func testFreshInstallPresentsUntilCompleted() {
        let store = OnboardingCompletionStore(defaults: makeDefaults())
        XCTAssertTrue(store.resolveLaunchPresentation(hasCachedMac: false))
        XCTAssertTrue(store.resolveLaunchPresentation(hasCachedMac: false), "not completed yet, still shows next launch")
        store.markCompleted()
        XCTAssertFalse(store.resolveLaunchPresentation(hasCachedMac: false))
    }

    func testExistingUserWithCachedMacIsNeverInterrupted() {
        let store = OnboardingCompletionStore(defaults: makeDefaults())
        XCTAssertFalse(store.resolveLaunchPresentation(hasCachedMac: true))
        XCTAssertTrue(store.isCompleted, "marked done so it doesn't pop up after the Mac is removed")
        XCTAssertFalse(store.resolveLaunchPresentation(hasCachedMac: false))
    }

    // MARK: - Mac detection

    private func device(_ id: String, name: String = "Studio Mac", model: String = "MacBook Pro", kind: SyncedDeviceKind = .mac, lastSeen: Date = Date()) -> SyncedDevice {
        SyncedDevice(id: id, name: name, modelName: model, lastSeenAt: lastSeen, appVersion: "1.0", kind: kind)
    }

    private func tab(_ url: String, title: String = "A title", deviceID: String = "mac") -> SyncedTab {
        SyncedTab(id: UUID().uuidString, deviceID: deviceID, browserName: "Safari", title: title, url: url)
    }

    func testConnectedMacIgnoresPhonesEvenWhenFresher() {
        let mac = device("mac", lastSeen: Date(timeIntervalSinceNow: -3600))
        let phone = device("phone", name: "iPhone", model: "iPhone16,2", kind: .iphone, lastSeen: Date())
        XCTAssertEqual(SyncedDevicePairing.mostRecentMac(in: [mac, phone])?.id, "mac")
    }

    func testMostRecentMacWins() {
        let old = device("old", lastSeen: Date(timeIntervalSinceNow: -3600))
        let fresh = device("fresh", lastSeen: Date())
        XCTAssertEqual(SyncedDevicePairing.mostRecentMac(in: [old, fresh])?.id, "fresh")
    }

    func testBlockedAccountOutranksFoundMac() {
        let state = MacConnectionState.resolve(health: .noAccount, devices: [device("mac")], tabs: [], hasWaitedLongEnough: false)
        XCTAssertEqual(state, .signedOut)
        let restricted = MacConnectionState.resolve(health: .restricted, devices: [], tabs: [], hasWaitedLongEnough: true)
        XCTAssertEqual(restricted, .restricted)
    }

    func testFoundMacCountsOnlyItsOwnTabs() {
        let tabs = [tab("https://a.com/x"), tab("https://b.com/y"), tab("https://c.com/z", deviceID: "other")]
        let state = MacConnectionState.resolve(health: .ok, devices: [device("mac", name: "Trung's MacBook")], tabs: tabs, hasWaitedLongEnough: false)
        XCTAssertEqual(state, .found(macName: "Trung's MacBook", tabCount: 2))
        XCTAssertTrue(state.isFound)
    }

    func testSearchingUntilPatienceRunsOut() {
        let phoneOnly = [device("phone", model: "iPhone16,2", kind: .iphone)]
        XCTAssertEqual(MacConnectionState.resolve(health: .unknown, devices: phoneOnly, tabs: [], hasWaitedLongEnough: false), .searching)
        XCTAssertEqual(MacConnectionState.resolve(health: .ok, devices: phoneOnly, tabs: [], hasWaitedLongEnough: true), .notFound)
        XCTAssertEqual(MacConnectionState.resolve(health: .failing("offline"), devices: [], tabs: [], hasWaitedLongEnough: true), .notFound)
    }

    func testFoundLabelPluralisesTabs() {
        XCTAssertEqual(MacConnectionState.foundLabel(macName: "Mac", tabCount: 1), "Found Mac · 1 tab")
        XCTAssertEqual(MacConnectionState.foundLabel(macName: "Mac", tabCount: 0), "Found Mac · 0 tabs")
    }

    // MARK: - Reader demo pick

    func testArticleHeuristic() {
        let articles = [
            "https://www.nytimes.com/2026/09/01/technology/tabs.html",
            "https://blog.example.com/why-tabs-pile-up",
            "http://example.org/essays/1",
        ]
        let notArticles = [
            "https://example.com/",
            "https://example.com",
            "https://mail.google.com/mail/u/0/#inbox",
            "https://docs.google.com/document/d/abc/edit",
            "https://github.com/tektrg/fasttab/pull/12",
            "https://www.youtube.com/watch?v=abc",
            "https://app.linear.app/team/issue/1",
            "https://dashboard.stripe.com/payments",
            "file:///Users/me/notes.html",
            "http://localhost:3000/posts/1",
            "chrome://settings/privacy",
        ]
        for string in articles {
            XCTAssertTrue(ReaderTryoutPicker.looksLikeArticle(URL(string: string)!), string)
        }
        for string in notArticles {
            XCTAssertFalse(ReaderTryoutPicker.looksLikeArticle(URL(string: string)!), string)
        }
    }

    func testPickPrefersSlugArticleAndSkipsUntitled() {
        let tabs = [
            tab("https://mail.google.com/mail/u/0"),
            tab("https://untitled.com/posts/a-great-read", title: ""),
            tab("https://example.com/news/12345"),
            tab("https://example.com/blog/a-great-read"),
        ]
        XCTAssertEqual(ReaderTryoutPicker.pick(from: tabs)?.url, "https://example.com/blog/a-great-read")
        XCTAssertEqual(ReaderTryoutPicker.pick(from: Array(tabs.prefix(3)))?.url, "https://example.com/news/12345")
        XCTAssertNil(ReaderTryoutPicker.pick(from: [tabs[0]]), "no candidate → the bundled sample is used")
    }

    // MARK: - Bundled sample

    func testSampleArticleShipsInAppBundle() throws {
        let article = try XCTUnwrap(ReaderSampleArticle.article(), "onboarding_sample_article.html missing from the app bundle")
        XCTAssertFalse(article.isEmpty)
        XCTAssertTrue(article.content.contains("<h2>"))
        XCTAssertEqual(article.url, ReaderSampleArticle.url)
    }

    func testSeedingPutsSampleInReaderCache() {
        let cache = ReaderArticleCache()
        XCTAssertTrue(ReaderSampleArticle.seedReaderCache(cache))
        XCTAssertEqual(cache.article(for: ReaderSampleArticle.url)?.title, ReaderSampleArticle.title)
    }

    // MARK: - "Try it" send

    private func openOnMacCommand(url: String) throws -> SyncCommand {
        let payload = OpenOnMacPayload(url: url, title: nil, preferBrowser: nil)
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(payload), encoding: .utf8))
        return SyncCommand(kind: .openOnMac, targetDeviceID: "", sourceDeviceName: "iPhone", payloadJSON: json)
    }

    func testTryItTracksOnlyTheSampleLink() throws {
        let sample = try openOnMacCommand(url: OnboardingSendToMacStep.sampleLinkURL.absoluteString)
        let other = try openOnMacCommand(url: "https://example.com/shared-meanwhile")
        XCTAssertTrue(OnboardingSendToMacStep.isSampleLinkCommand(sample))
        XCTAssertFalse(OnboardingSendToMacStep.isSampleLinkCommand(other))
    }

    // MARK: - Sync banner on Read / Tabs

    func testBannerWarnsOnBlockedAccountNoMacOrOfflineMac() {
        let now = Date()
        let liveMac = device("mac", lastSeen: now.addingTimeInterval(-60))
        let sleepingMac = device("mac", lastSeen: now.addingTimeInterval(-2 * 3600))
        let offlineMac = device("mac", lastSeen: now.addingTimeInterval(-26 * 3600))

        XCTAssertTrue(SyncWarningPolicy.shouldWarn(health: .noAccount, mac: liveMac, now: now))
        XCTAssertTrue(SyncWarningPolicy.shouldWarn(health: .ok, mac: nil, now: now))
        XCTAssertTrue(SyncWarningPolicy.shouldWarn(health: .ok, mac: offlineMac, now: now))
        XCTAssertFalse(SyncWarningPolicy.shouldWarn(health: .ok, mac: liveMac, now: now))
        XCTAssertFalse(SyncWarningPolicy.shouldWarn(health: .ok, mac: sleepingMac, now: now), "an asleep laptop is normal, not a warning")
        XCTAssertFalse(SyncWarningPolicy.shouldWarn(health: .failing("offline"), mac: liveMac, now: now), "transient failures stay on More")
    }
}
