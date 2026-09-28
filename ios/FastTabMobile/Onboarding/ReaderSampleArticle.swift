import Foundation

/// The short article bundled for the guide's "Try Reader" step, used when the
/// user has no synced tab that looks like an article (or no Mac at all).
///
/// It opens in the real `ReaderView` with no network: the article is written
/// into `ReaderArticleCache` under `url` first, and the reader loads from the
/// cache before it ever tries the web. `url` is FastTab's own home page, so the
/// reader's Share / Open in Safari buttons still lead somewhere sensible.
enum ReaderSampleArticle {
    static let resourceName = "onboarding_sample_article"
    static let url = URL(string: "https://fasttab.theindie.app/")!
    static let title = "Why your tabs pile up (and how to read them)"
    static let byline = "The FastTab team"
    static let siteName = "FastTab"

    /// Builds the article from the bundled HTML. `nil` only if the resource is
    /// missing from the build, which the unit tests guard against.
    static func article(in bundle: Bundle = .main) -> ReaderArticle? {
        guard let fileURL = bundle.url(forResource: resourceName, withExtension: "html"),
              let html = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        return ReaderArticle(
            title: title,
            byline: byline,
            siteName: siteName,
            content: html,
            excerpt: "How FastTab turns the tabs you meant to read into an easy read on your iPhone.",
            url: url
        )
    }

    /// Puts the sample in the reader cache so `ReaderView(url: url, …)` opens it
    /// instantly and offline. Re-seeded on every open so it always wins over a
    /// cached extraction of the real home page.
    @MainActor
    @discardableResult
    static func seedReaderCache(_ cache: ReaderArticleCache? = nil, bundle: Bundle = .main) -> Bool {
        guard let article = article(in: bundle) else { return false }
        (cache ?? .shared).save(article)
        return true
    }
}
