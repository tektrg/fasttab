import Foundation
import WebKit

/// Warms the web view side of the reader (web-content process, template, fonts)
/// so the real `ReaderWebView` paints immediately. Holds at most one hidden view.
@MainActor
protocol ReaderWebViewWarming: AnyObject {
    func warm(with article: ReaderArticle)
    func release()
}

@MainActor
final class ReaderWebViewWarmer: ReaderWebViewWarming {
    private var webView: WKWebView?

    func warm(with article: ReaderArticle) {
        release()
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        let warmView = WKWebView(frame: CGRect(x: 0, y: 0, width: 393, height: 852), configuration: config)
        // Same template + bootstrap the visible reader uses. The throwaway view model
        // records nothing: history and stats only start in `loadInitialState()`.
        let viewModel = ReaderViewModel(url: article.url, title: article.title)
        ReaderWebView.loadTemplate(into: warmView, viewModel: viewModel, article: article)
        webView = warmView
    }

    func release() {
        webView?.stopLoading()
        webView = nil
    }
}

/// Gets an article ready before the reader opens: extracts it into
/// `ReaderArticleCache` (the cache `ReaderViewModel` already reads first) and
/// warms one web view, so opening shows content with no spinner.
///
/// It only fills caches. It never touches `LastOpenedStore`, reading progress or
/// stats, which start when `ReaderView` appears. A failed preload is silent: the
/// reader then loads the normal way. First user: the onboarding "Try Reader" step.
@MainActor
final class ReaderPreloader: ObservableObject {
    static let shared = ReaderPreloader()

    enum Status: Equatable {
        case idle
        case preparing
        case ready
        /// Extraction failed (offline, blocked page). Cache untouched.
        case failed
    }

    typealias Extract = (URL) async throws -> ReaderArticle

    /// Status of the most recent request; see `status(for:)` to ask about one URL.
    @Published private(set) var status: Status = .idle
    private(set) var currentURL: URL?

    private let cache: ReaderArticleCache
    private let extract: Extract
    private let warmer: ReaderWebViewWarming
    private var task: Task<Void, Never>?

    init(
        cache: ReaderArticleCache? = nil,
        extract: @escaping Extract = { try await ReaderExtractor.shared.extract(url: $0) },
        warmer: ReaderWebViewWarming? = nil
    ) {
        self.cache = cache ?? .shared
        self.extract = extract
        self.warmer = warmer ?? ReaderWebViewWarmer()
    }

    func status(for url: URL) -> Status {
        isCurrent(url) ? status : .idle
    }

    /// Prepares `url` in the background. Repeat calls for the same URL do nothing (a
    /// failed URL is not retried on its own; pass `retryFailed` when the user is waiting);
    /// a different URL replaces the previous request (one warm web view at most).
    /// YouTube transcript links are skipped: they use a different pipeline.
    func preload(url: URL, retryFailed: Bool = false) {
        guard ReaderContentRoute.route(for: url) == .article else { return }
        guard begin(url, retryFailed: retryFailed) else { return }
        if let cached = cache.article(for: url) {
            finish(with: cached)
            return
        }
        let extract = self.extract
        task = Task { [weak self] in
            do {
                let article = try await extract(url)
                guard !Task.isCancelled, let self, self.isCurrent(url) else { return }
                self.cache.save(article)
                self.finish(with: article)
            } catch {
                guard !Task.isCancelled, let self, self.isCurrent(url) else { return }
                self.status = .failed
            }
        }
    }

    /// Prepares the bundled sample article. No network.
    func preloadSample(bundle: Bundle = .main) {
        let url = ReaderSampleArticle.url
        guard begin(url) else { return }
        guard let article = ReaderSampleArticle.article(in: bundle),
              ReaderSampleArticle.seedReaderCache(cache, bundle: bundle) else {
            status = .failed
            return
        }
        finish(with: article)
    }

    /// Stops any request in flight and frees the warm web view. Cached articles stay.
    func cancel() {
        task?.cancel()
        task = nil
        currentURL = nil
        status = .idle
        warmer.release()
    }

    // MARK: - Private

    /// Starts a request; false if the same URL is already preparing or ready (or failed,
    /// unless `retryFailed`). Otherwise every tab sync would re-run a 20 s failing extraction.
    private func begin(_ url: URL, retryFailed: Bool = false) -> Bool {
        if isCurrent(url) {
            if status == .preparing || status == .ready { return false }
            if status == .failed && !retryFailed { return false }
        }
        task?.cancel()
        task = nil
        warmer.release()
        currentURL = url
        status = .preparing
        return true
    }

    private func isCurrent(_ url: URL) -> Bool {
        currentURL?.readerCanonicalKey == url.readerCanonicalKey
    }

    private func finish(with article: ReaderArticle) {
        warmer.warm(with: article)
        status = .ready
    }
}
