import XCTest
import IndieLinks
@testable import FastTabMobile

/// Link cards: `LinkCardMetadata` (shared IndieLinks module) → what a Fast Tab card shows.
final class LinkCardPreviewTests: XCTestCase {

    // MARK: - Metadata → card text

    func testXPostShowsTweetTextAsTitleAndNameWithHandleAsSubtitle() {
        let metadata = LinkCardMetadata(
            site: .x, snippet: "just setting up my twttr",
            authorName: "jack", authorHandle: "@jack", mediaKind: .none
        )
        let preview = LinkPreview(metadata: metadata)

        XCTAssertTrue(preview.isTweet)
        XCTAssertEqual(preview.title, "just setting up my twttr")
        XCTAssertEqual(preview.snippetText, "just setting up my twttr")
        XCTAssertEqual(preview.siteSubtitle, "jack (@jack)")
    }

    func testXPostWithOnlyAHandleUsesTheHandleAsSubtitle() {
        let preview = LinkPreview(metadata: LinkCardMetadata(site: .x, snippet: "gm", authorHandle: "@jack"))
        XCTAssertEqual(preview.siteSubtitle, "@jack")
    }

    func testXArticleUsesArticleTitleOverTeaser() {
        let metadata = LinkCardMetadata(site: .x, title: "Why local-first", snippet: "Teaser text", mediaKind: .photo)
        XCTAssertEqual(LinkPreview(metadata: metadata).title, "Why local-first")
    }

    func testXVideoKeepsMediaKindAndDuration() {
        let metadata = LinkCardMetadata(site: .x, snippet: "Liftoff", mediaKind: .video, durationSeconds: 75)
        let preview = LinkPreview(metadata: metadata)
        XCTAssertEqual(preview.mediaKind, .video)
        XCTAssertEqual(preview.durationSeconds, 75)
    }

    func testYouTubeShowsVideoTitleAndChannelName() {
        let metadata = LinkCardMetadata(
            site: .youtube, title: "Never Gonna Give You Up",
            authorName: "Rick Astley", authorHandle: "@RickAstleyYT", mediaKind: .video
        )
        let preview = LinkPreview(metadata: metadata, isYouTubeShort: true)
        XCTAssertFalse(preview.isTweet)
        XCTAssertEqual(preview.title, "Never Gonna Give You Up")
        XCTAssertEqual(preview.siteSubtitle, "Rick Astley")
        XCTAssertTrue(preview.isYouTubeShort)
    }

    func testRedditShowsSubredditAndAuthor() {
        let metadata = LinkCardMetadata(
            site: .reddit, title: "How to smooth a zoom?", snippet: "I have a couple of shots",
            authorName: "u/Winter_Ad3298", authorHandle: "r/davinciresolve"
        )
        let preview = LinkPreview(metadata: metadata)
        XCTAssertEqual(preview.title, "How to smooth a zoom?")
        XCTAssertEqual(preview.siteSubtitle, "r/davinciresolve · u/Winter_Ad3298")
        XCTAssertEqual(preview.snippetText, "I have a couple of shots")
    }

    func testGitHubRepoShowsStarsAndDescription() {
        let metadata = LinkCardMetadata(
            site: .github, title: "swiftlang/swift", snippet: "The Swift Programming Language",
            mediaKind: .photo, stats: ["stars": 69_812, "forks": 10_500]
        )
        let preview = LinkPreview(metadata: metadata)
        XCTAssertEqual(preview.title, "swiftlang/swift")
        XCTAssertEqual(preview.siteSubtitle, "★ 69.8k · The Swift Programming Language")
    }

    func testGitHubRepoWithoutApiDetailsHasNoSubtitle() {
        let preview = LinkPreview(metadata: LinkCardMetadata(site: .github, title: "swiftlang/swift", mediaKind: .photo))
        XCTAssertNil(preview.siteSubtitle)
    }

    /// Same as Parklet (IndieLinks `headline` / `secondaryLine`): the PR's title leads, its
    /// "owner/repo#N" is the source line, like a subreddit or channel.
    func testGitHubPullRequestShowsItsTitleOverTheNumberedRepo() {
        let metadata = LinkCardMetadata(
            site: .github, title: "Fix the build", authorName: "octocat", authorHandle: "swiftlang/swift#1"
        )
        let preview = LinkPreview(metadata: metadata)
        XCTAssertEqual(preview.title, "Fix the build")
        XCTAssertEqual(preview.siteSubtitle, "swiftlang/swift#1")
    }

    // MARK: - Card title choice

    func testCardTitlePrefersSiteTitleOverStoredBrowserTitle() {
        let preview = LinkPreview(metadata: LinkCardMetadata(site: .github, title: "swiftlang/swift"))
        XCTAssertEqual(
            LinkPreview.cardTitle(storedTitle: "GitHub - swiftlang/swift: The Swift Programming Language", preview: preview),
            "swiftlang/swift"
        )
    }

    func testCardTitleKeepsStoredTitleForGenericSites() {
        let preview = LinkPreview(title: "Example Domain")
        XCTAssertEqual(LinkPreview.cardTitle(storedTitle: "My saved title", preview: preview), "My saved title")
        XCTAssertEqual(LinkPreview.cardTitle(storedTitle: "https://example.com", preview: preview), "Example Domain")
        XCTAssertEqual(LinkPreview.cardTitle(storedTitle: "https://example.com", preview: nil), "https://example.com")
    }

    // MARK: - Images

    func testXPhotoURLIsRewrittenToMediumSize() {
        let original = URL(string: "https://pbs.twimg.com/media/DHEXH7RV0AAUwKj.jpg?name=orig")!
        XCTAssertEqual(
            LinkCardImageLoader.cardSizedURL(original).absoluteString,
            "https://pbs.twimg.com/media/DHEXH7RV0AAUwKj.jpg?name=medium"
        )
    }

    func testXVideoThumbnailGetsMediumSizeParameter() {
        let thumb = URL(string: "https://pbs.twimg.com/ext_tw_video_thumb/1732820284301058052/pu/img/A-6jgWgxmMJ43_YO.jpg")!
        XCTAssertEqual(LinkCardImageLoader.cardSizedURL(thumb).query, "name=medium")
    }

    func testNonXMediaURLsAreUnchanged() {
        let avatar = URL(string: "https://pbs.twimg.com/profile_images/1/abc_200x200.jpg")!
        let youtube = URL(string: "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg")!
        XCTAssertEqual(LinkCardImageLoader.cardSizedURL(avatar), avatar)
        XCTAssertEqual(LinkCardImageLoader.cardSizedURL(youtube), youtube)
    }

    func testYouTubeLetterboxCropsToTheCenterBand() {
        let hqdefault = CGSize(width: 480, height: 360)
        XCTAssertEqual(
            LinkCardImageLoader.centerCropRect(for: hqdefault, aspectRatio: 16.0 / 9.0),
            CGRect(x: 0, y: 45, width: 480, height: 270)
        )
        XCTAssertEqual(
            LinkCardImageLoader.centerCropRect(for: hqdefault, aspectRatio: 9.0 / 16.0),
            CGRect(x: 139, y: 0, width: 203, height: 360)
        )
    }

    // MARK: - Disk cache

    func testMetadataCacheRoundTripsAndExpires() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = URL(string: "https://github.com/swiftlang/swift")!
        let metadata = LinkCardMetadata(
            site: .github, title: "swiftlang/swift",
            imageURL: URL(string: "https://opengraph.githubassets.com/1/swiftlang/swift"),
            mediaKind: .photo, stats: ["stars": 69_812]
        )
        let savedAt = Date(timeIntervalSince1970: 1_000_000)

        LinkCardMetadataCache(directory: directory, now: { savedAt }).store(metadata, for: url)

        let sixDaysLater = LinkCardMetadataCache(directory: directory, now: { savedAt.addingTimeInterval(6 * 86_400) })
        XCTAssertEqual(sixDaysLater.lookup(url)?.metadata, metadata)
        XCTAssertEqual(sixDaysLater.lookup(url)?.isRetryDue, false)
        XCTAssertNil(sixDaysLater.lookup(URL(string: "https://github.com/apple/swift")!))

        let eightDaysLater = LinkCardMetadataCache(directory: directory, now: { savedAt.addingTimeInterval(8 * 86_400) })
        XCTAssertNil(eightDaysLater.lookup(url))
    }

    /// A partial card (e.g. GitHub API rate-limited) is fetched once more after 6 hours,
    /// not kept thin for the whole 7-day lifetime, and not retried forever either.
    func testPartialCardIsRetriedOnceAfterSixHours() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = URL(string: "https://github.com/swiftlang/swift")!
        let partial = LinkCardMetadata(site: .github, title: "swiftlang/swift", mediaKind: .photo, isPartial: true)
        let savedAt = Date(timeIntervalSince1970: 1_000_000)
        func cache(hoursLater hours: Double) -> LinkCardMetadataCache {
            LinkCardMetadataCache(directory: directory, now: { savedAt.addingTimeInterval(hours * 3_600) })
        }

        cache(hoursLater: 0).store(partial, for: url)
        XCTAssertEqual(cache(hoursLater: 5).lookup(url)?.isRetryDue, false)
        XCTAssertEqual(cache(hoursLater: 7).lookup(url)?.isRetryDue, true)

        cache(hoursLater: 7).store(partial, for: url, wasRetry: true)
        XCTAssertEqual(cache(hoursLater: 20).lookup(url)?.isRetryDue, false)
        XCTAssertEqual(cache(hoursLater: 20).lookup(url)?.metadata, partial)
    }
}
