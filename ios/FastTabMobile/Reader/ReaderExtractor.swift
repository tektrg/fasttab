import Foundation
import WebKit

/// Loads a URL in a hidden `WKWebView`, injects Readability.js, and returns a `ReaderArticle`.
/// Falls back gracefully: if extraction yields empty content, throws `ExtractionError.noContent`.
@MainActor
public final class ReaderExtractor: NSObject {

    // MARK: - Errors

    public enum ExtractionError: Error, LocalizedError {
        case readabilityJSNotFound
        case navigationFailed(Error)
        case timeout
        case noContent
        case scriptError(String)

        public var errorDescription: String? {
            switch self {
            case .readabilityJSNotFound: return "Readability.js resource missing from bundle."
            case .navigationFailed(let e): return "Page load failed: \(e.localizedDescription)"
            case .timeout: return "Page load timed out."
            case .noContent: return "No readable content found on this page."
            case .scriptError(let msg): return "Extraction script error: \(msg)"
            }
        }
    }

    // MARK: - Singleton

    public static let shared = ReaderExtractor()

    // MARK: - State

    private var activeSessions: [ObjectIdentifier: (WKWebView, ExtractionDelegate)] = [:]
    private var readabilityJS: String?

    private static let extractionTimeoutSeconds: TimeInterval = 20

    // MARK: - Init

    private override init() {
        super.init()
        loadReadabilityJS()
    }

    // MARK: - Public API

    /// Extracts a readable article from `url`. Must be called from the main actor.
    public func extract(url: URL) async throws -> ReaderArticle {
        if readabilityJS == nil {
            loadReadabilityJS()
        }
        guard let js = readabilityJS else {
            throw ExtractionError.readabilityJSNotFound
        }

        return try await withCheckedThrowingContinuation { continuation in
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .default()
            // Sized viewport so WebKit does not throttle JS timers or responsive layouts
            let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 393, height: 852), configuration: config)
            wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

            var sessionKey: ObjectIdentifier?
            let delegate = ExtractionDelegate(
                url: url,
                readabilityJS: js,
                continuation: continuation,
                onResolve: { [weak self] _ in
                    if let key = sessionKey {
                        self?.activeSessions.removeValue(forKey: key)
                    }
                }
            )
            wv.navigationDelegate = delegate
            let key = ObjectIdentifier(wv)
            sessionKey = key
            self.activeSessions[key] = (wv, delegate)

            delegate.startTimeout(seconds: Self.extractionTimeoutSeconds)
            wv.load(URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: Self.extractionTimeoutSeconds))
        }
    }

    // MARK: - Script Helpers

    /// Generates the JavaScript IIFE snippet used to extract posts from an X/Twitter DOM.
    /// Returns `{ title, byline, siteName, content, excerpt }` or `null` if unhydrated/empty.
    public static func buildTwitterExtractionScript() -> String {
        """
        (function() {
          try {
            var articles = document.querySelectorAll('article');
            if (articles.length === 0) return null;

            var threadHtml = [];
            var mainTitle = '';
            var authorName = '';
            var authorHandle = '';
            var rootTime = '';

            for (var i = 0; i < articles.length; i++) {
              var a = articles[i];
              var timeEl = a.querySelector('time');
              var tweetTime = timeEl ? (timeEl.innerText.trim() || timeEl.getAttribute('datetime') || '') : '';

              // Extract author info from the first article
              if (i === 0) {
                rootTime = tweetTime;
                var userAnchors = a.querySelectorAll('a[href^="/"]');
                for (var u = 0; u < userAnchors.length; u++) {
                  var txt = userAnchors[u].innerText.trim();
                  if (txt.indexOf('@') === 0 && !authorHandle) {
                    authorHandle = txt;
                  } else if (txt && !authorName && txt.indexOf('@') === -1 && txt.indexOf('\\n') === -1) {
                    authorName = txt;
                  }
                }
              }

              // Only stitch continuation posts by the original author
              if (i > 0) {
                if (!authorHandle) continue;
                var thisHandle = '';
                var thisAnchors = a.querySelectorAll('a[href^="/"]');
                for (var tu = 0; tu < thisAnchors.length; tu++) {
                  var ttxt = thisAnchors[tu].innerText.trim();
                  if (ttxt.indexOf('@') === 0) {
                    thisHandle = ttxt;
                    break;
                  }
                }
                if (thisHandle.toLowerCase() !== authorHandle.toLowerCase()) {
                  continue;
                }
              }

              var tweetTextEl = a.querySelector('[data-testid="tweetText"]') ||
                                a.querySelector('div[dir="auto"].whitespace-pre-wrap') ||
                                a.querySelector('div[dir="auto"].break-words') ||
                                a.querySelector('[lang][dir="auto"]');

              if (!tweetTextEl) {
                var dirAutoList = a.querySelectorAll('div[dir="auto"]');
                for (var d = 0; d < dirAutoList.length; d++) {
                  var candidate = dirAutoList[d];
                  if (candidate.closest('a') || candidate.closest('button')) continue;
                  var candidateText = candidate.innerText.trim();
                  if (candidateText && candidateText !== authorName && candidateText !== authorHandle) {
                    tweetTextEl = candidate;
                    break;
                  }
                }
              }

              var tweetText = tweetTextEl ? tweetTextEl.innerHTML : '';
              var rawText = tweetTextEl ? tweetTextEl.innerText.trim() : '';

              var imgs = a.querySelectorAll('img[src*="pbs.twimg.com/media"]');
              if (!tweetText && !rawText && imgs.length === 0) continue;

              if (!mainTitle) {
                if (rawText) {
                  mainTitle = rawText.length > 80 ? rawText.substring(0, 77) + '…' : rawText;
                } else if (authorName || authorHandle) {
                  mainTitle = 'Post by ' + (authorName || authorHandle);
                }
              }

              var imgHtml = '';
              for (var m = 0; m < imgs.length; m++) {
                imgHtml += '<p><img src="' + imgs[m].src + '" style="max-width:100%; border-radius:12px; margin: 12px 0;" /></p>';
              }

              var postHeader = '<div style="font-size: 0.9em; font-weight: 600; margin-bottom: 6px; color: var(--fg-muted, #536471);">'
                + (authorName ? '<span>' + authorName + '</span> ' : '')
                + (authorHandle ? '<span style="font-weight: normal; color: var(--fg-muted, gray);">' + authorHandle + '</span>' : '')
                + (tweetTime ? ' · <span style="font-weight: normal; color: var(--fg-muted, gray);">' + tweetTime + '</span>' : '')
                + '</div>';

              var bodyHtml = tweetText ? '<div class="tweet-body" style="font-size: 1.1em; line-height: 1.5; margin-bottom: 12px; white-space: pre-wrap; word-break: break-word;">' + tweetText + '</div>' : '';

              threadHtml.push('<div class="tweet-post" style="margin-bottom: 24px; padding-bottom: 16px; border-bottom: 1px solid var(--divider, rgba(128,128,128,0.2));">'
                + (i > 0 ? '<p style="font-size: 0.85em; color: var(--fg-muted, gray); margin-bottom: 6px;">Thread continuation</p>' : postHeader)
                + bodyHtml
                + imgHtml
                + '</div>');
            }

            if (threadHtml.length > 0) {
              var combinedContent = threadHtml.join('');
              var pageTitle = mainTitle || document.title || 'Post on X';
              var byline = (authorName || '') + (authorHandle ? ' (' + authorHandle + ')' : '') + (rootTime ? ' · ' + rootTime : '');
              return {
                title: pageTitle,
                byline: byline.trim(),
                siteName: 'X',
                content: combinedContent,
                excerpt: mainTitle
              };
            }
            return null;
          } catch(e) {
            return { error: e.message };
          }
        })()
        """
    }

    // MARK: - Private

    private func loadReadabilityJS() {
        let fileURL = Bundle.main.url(forResource: "Readability", withExtension: "js") ??
                      Bundle.main.url(forResource: "Readability", withExtension: "js", subdirectory: "Resources")
        guard let url = fileURL,
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            return
        }
        readabilityJS = source
    }
}

// MARK: - Extraction Delegate (WKNavigationDelegate)

@MainActor
private final class ExtractionDelegate: NSObject, WKNavigationDelegate {
    private let url: URL
    private let readabilityJS: String
    private var continuation: CheckedContinuation<ReaderArticle, Error>?
    private var onResolve: ((Result<ReaderArticle, Error>) -> Void)?
    private var isResolved = false
    private var timeoutTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?

    private var pollCount = 0
    private var lastScriptError: String?
    private static let maxHydrationPolls = 10
    private static let pollIntervalNanos: UInt64 = 400_000_000 // 400ms

    init(
        url: URL,
        readabilityJS: String,
        continuation: CheckedContinuation<ReaderArticle, Error>,
        onResolve: @escaping (Result<ReaderArticle, Error>) -> Void
    ) {
        self.url = url
        self.readabilityJS = readabilityJS
        self.continuation = continuation
        self.onResolve = onResolve
    }

    func startTimeout(seconds: TimeInterval) {
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, !self.isResolved else { return }
            self.resolve(with: .failure(ReaderExtractor.ExtractionError.timeout))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !isResolved, pollTask == nil else { return }
        attemptExtraction(in: webView)
    }

    private func attemptExtraction(in webView: WKWebView) {
        let script = buildExtractionScript()
        webView.evaluateJavaScript(script) { [weak self] result, error in
            guard let self, !self.isResolved else { return }

            if let dict = result as? [String: Any] {
                if let errMsg = dict["error"] as? String {
                    self.lastScriptError = errMsg
                }
                if let content = dict["content"] as? String,
                   !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Success!
                    let article = ReaderArticle(
                        title: (dict["title"] as? String) ?? (webView.title ?? self.url.host() ?? ""),
                        byline: (dict["byline"] as? String) ?? "",
                        siteName: (dict["siteName"] as? String) ?? (self.url.host() ?? ""),
                        content: content,
                        excerpt: (dict["excerpt"] as? String) ?? "",
                        url: self.url,
                        extractedAt: Date()
                    )
                    self.resolve(with: .success(article))
                    return
                }
            } else if let error = error {
                self.lastScriptError = error.localizedDescription
            }

            // If immediate extraction produced no content, start hydration polling
            self.pollCount += 1
            if self.pollCount < Self.maxHydrationPolls {
                self.pollTask = Task { @MainActor [weak self, weak webView] in
                    try? await Task.sleep(nanoseconds: Self.pollIntervalNanos)
                    guard let self, !self.isResolved, let wv = webView else { return }
                    self.attemptExtraction(in: wv)
                }
            } else {
                // Polling exhausted without finding readable content
                if let scriptErr = self.lastScriptError {
                    self.resolve(with: .failure(ReaderExtractor.ExtractionError.scriptError(scriptErr)))
                } else {
                    self.resolve(with: .failure(ReaderExtractor.ExtractionError.noContent))
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard !isResolved else { return }
        resolve(with: .failure(ReaderExtractor.ExtractionError.navigationFailed(error)))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard !isResolved else { return }
        resolve(with: .failure(ReaderExtractor.ExtractionError.navigationFailed(error)))
    }

    // MARK: - Helpers

    private func buildExtractionScript() -> String {
        let twitterScript = ReaderExtractor.buildTwitterExtractionScript()
        return """
        (function() {
          try {
            var host = window.location.hostname || '';
            var isTwitter = host === 'x.com' || host.endsWith('.x.com') || host === 'twitter.com' || host.endsWith('.twitter.com');

            if (isTwitter) {
              return (\(twitterScript));
            }

            // General Readability extraction
            \(readabilityJS)
            var docClone = document.cloneNode(true);
            var reader = new Readability(docClone);
            var article = reader.parse();
            if (!article) return null;
            return {
              title:    article.title    || '',
              byline:   article.byline   || '',
              siteName: article.siteName || '',
              content:  article.content  || '',
              excerpt:  article.excerpt  || ''
            };
          } catch(e) {
            return { error: e.message };
          }
        })();
        """
    }

    private func resolve(with result: Result<ReaderArticle, Error>) {
        guard !isResolved else { return }
        isResolved = true
        timeoutTask?.cancel()
        timeoutTask = nil
        pollTask?.cancel()
        pollTask = nil
        continuation?.resume(with: result)
        continuation = nil
        onResolve?(result)
        onResolve = nil
    }
}
