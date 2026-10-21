import Foundation
import WebKit

/// Loads a page in an off-screen `WKWebView`, runs Readability.js on it and returns the
/// article. Same approach and script as the phone's `ReaderExtractor` (minus its X/Twitter
/// paths): retries a few times while client-rendered pages hydrate, gives up after a timeout.
@MainActor
final class MacReaderExtractor: NSObject, WKNavigationDelegate {
    enum Failure: Error, Equatable {
        case resourcesMissing, loadFailed, timedOut, noContent
    }

    static let timeoutSeconds: Double = 20
    static let maxAttempts = 10
    static let retryDelay: Duration = .milliseconds(400)

    private let url: URL
    private let readabilityJS: String
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<MacReaderArticle, Error>?
    private var attempts = 0
    private var isExtracting = false

    private init(url: URL, readabilityJS: String) {
        self.url = url
        self.readabilityJS = readabilityJS
    }

    static func extract(url: URL) async throws -> MacReaderArticle {
        guard let js = MacReaderResources.readabilityJS else { throw Failure.resourcesMissing }
        let extractor = MacReaderExtractor(url: url, readabilityJS: js)
        return try await extractor.run()
    }

    private func run() async throws -> MacReaderArticle {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 1400))
            webView.navigationDelegate = self
            self.webView = webView
            webView.load(URLRequest(url: url, timeoutInterval: Self.timeoutSeconds))
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(Self.timeoutSeconds))
                self?.finish(.failure(Failure.timedOut))
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.startExtracting() }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.finish(.failure(Failure.loadFailed)) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.finish(.failure(Failure.loadFailed)) }
    }

    private func startExtracting() {
        guard !isExtracting else { return }
        isExtracting = true
        attempt()
    }

    private func attempt() {
        guard let webView, continuation != nil else { return }
        attempts += 1
        webView.evaluateJavaScript(MacReaderExtractionScript.make(readabilityJS: readabilityJS)) { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let article = MacReaderExtractionScript.article(from: result, url: self.url, pageTitle: webView.title) {
                    self.finish(.success(article))
                } else if self.attempts < Self.maxAttempts {
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: Self.retryDelay)
                        self?.attempt()
                    }
                } else {
                    self.finish(.failure(Failure.noContent))
                }
            }
        }
    }

    private func finish(_ result: Result<MacReaderArticle, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        continuation.resume(with: result)
    }
}

/// The JavaScript run in the page and the reading of its result. Pure, so it is tested.
enum MacReaderExtractionScript {
    static func make(readabilityJS: String) -> String {
        """
        (function() {
          try {
            \(readabilityJS)
            var article = new Readability(document.cloneNode(true)).parse();
            if (!article) return null;
            return { title: article.title || '', byline: article.byline || '',
                     siteName: article.siteName || '', content: article.content || '' };
          } catch (e) { return { error: String(e && e.message || e) }; }
        })();
        """
    }

    /// The article in a script result, or nil when the page has no readable content (yet).
    static func article(from result: Any?, url: URL, pageTitle: String?, now: Date = Date()) -> MacReaderArticle? {
        guard let dict = result as? [String: Any],
              let content = dict["content"] as? String,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let host = url.host() ?? ""
        let title = (dict["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? pageTitle ?? host
        let siteName = (dict["siteName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? host
        return MacReaderArticle(title: title, byline: dict["byline"] as? String ?? "", siteName: siteName,
                                content: content, url: url, extractedAt: now)
    }
}
