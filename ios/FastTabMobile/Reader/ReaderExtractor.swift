import Foundation
import WebKit

/// Loads a URL in a hidden `WKWebView`, injects Readability.js, and returns a `ReaderArticle`.
///
/// For X/Twitter status URLs a two-track parallel strategy is used:
///   • oEmbed HTTP call  — reliable tweet text, no authentication needed.
///   • WKWebView scrape  — CDN images load from pbs.twimg.com without auth.
/// Both run in parallel; results are merged before returning to the caller.
/// For all other URLs: WKWebView + Readability.js is used directly.
@MainActor
public final class ReaderExtractor: NSObject {

    // MARK: - Errors

    public enum ExtractionError: Error, LocalizedError {
        case readabilityJSNotFound
        case navigationFailed(Error)
        case timeout
        case noContent
        case scriptError(String)
        /// X Article whose body could not be fetched; the UI falls back to Safari Reader.
        case xArticleUnavailable

        public var errorDescription: String? {
            switch self {
            case .readabilityJSNotFound: return "Readability.js resource missing from bundle."
            case .navigationFailed(let e): return "Page load failed: \(e.localizedDescription)"
            case .timeout: return "Page load timed out."
            case .noContent: return "No readable content found on this page."
            case .scriptError(let msg): return "Extraction script error: \(msg)"
            case .xArticleUnavailable: return "Couldn't load this X article."
            }
        }
    }

    // MARK: - Singleton

    public static let shared = ReaderExtractor()

    // MARK: - State

    private var activeSessions: [ObjectIdentifier: (WKWebView, ExtractionDelegate)] = [:]
    private var imageSessions: [ObjectIdentifier: (WKWebView, TwitterImageDelegate)] = [:]
    private var readabilityJS: String?

    private static let extractionTimeoutSeconds: TimeInterval = 20

    // MARK: - Init

    private override init() {
        super.init()
        loadReadabilityJS()
    }

    // MARK: - Public API

    /// Extracts a readable article from `url`. Must be called from the main actor.
    ///
    /// For X/Twitter status URLs:
    ///   1. oEmbed API (text) + WKWebView CDN image scrape run **in parallel**.
    ///   2. Results are merged: oEmbed text + CDN images → single `ReaderArticle`.
    ///   3. If oEmbed fails, falls back to full WKWebView + Readability extraction.
    /// For all other URLs: WKWebView + Readability.js is used directly.
    public func extract(url: URL) async throws -> ReaderArticle {
        // X Articles (`/article/<id>`) have no tweet text at all — go straight to the article body.
        // If that fetch fails, throw: the web view can't get past X's login wall either.
        if XArticleExtractor.isArticleURL(url) {
            guard let article = await XArticleExtractor.fetch(url: url) else {
                throw ExtractionError.xArticleUnavailable
            }
            return article
        }

        if Self.isTwitterStatusURL(url) {
            // Run text (oEmbed) and image scrape in parallel — both work without auth.
            // Images run as an unstructured Task so an early return (Article path) isn't held up by it.
            let imagesTask = Task { await self.extractTwitterImagesOnly(url: url) }
            let oembedResult = await extractTwitterViaOEmbed(url: url)

            // An Article post's tweet text is only a t.co link; oEmbed "succeeds" with that link
            // and the reader would show the cover image with no body. Fetch the real article.
            if let oembed = oembedResult, XArticleExtractor.isLinkOnly(oembed.excerpt) {
                guard let article = await XArticleExtractor.fetch(url: url) else {
                    throw ExtractionError.xArticleUnavailable
                }
                return article
            }

            if let article = oembedResult {
                // oEmbed gave us text — append any CDN images scraped from the live page
                return appendImages(await imagesTask.value, to: article)
            }
            // oEmbed failed — fall through to full WKWebView extraction
        }

        return try await extractViaWebView(url: url)
    }

    // MARK: - Twitter URL Detection

    /// Returns `true` if `url` is an X.com or twitter.com domain.
    nonisolated public static func isTwitterURL(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return host == "x.com" || host == "www.x.com" || host.hasSuffix(".x.com") ||
               host == "twitter.com" || host == "www.twitter.com" || host.hasSuffix(".twitter.com")
    }

    /// Returns `true` if `url` is an individual X/Twitter post status page.
    public static func isTwitterStatusURL(_ url: URL) -> Bool {
        guard isTwitterURL(url) else { return false }
        return url.path.contains("/status/")
    }

    // MARK: - Twitter oEmbed Text Extraction

    /// Fetches tweet text via the public oEmbed endpoint — no authentication required.
    /// Returns a `ReaderArticle` with the tweet text and author info, but NO images
    /// (images are added separately by `extractTwitterImagesOnly`).
    private func extractTwitterViaOEmbed(url: URL) async -> ReaderArticle? {
        var components = URLComponents(string: "https://publish.twitter.com/oembed")
        components?.queryItems = [
            URLQueryItem(name: "url",          value: url.absoluteString),
            URLQueryItem(name: "omit_script",  value: "true"),
            URLQueryItem(name: "dnt",          value: "true")
        ]
        guard let oembedURL = components?.url else { return nil }

        do {
            var request = URLRequest(url: oembedURL)
            request.timeoutInterval = 8.0
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }

            let authorName = json["author_name"] as? String ?? ""
            let authorURL  = json["author_url"]  as? String ?? ""
            let rawHTML    = json["html"]         as? String ?? ""

            // Derive @handle from author URL (e.g. https://twitter.com/username)
            let authorHandle: String = {
                if let parsed = URL(string: authorURL) {
                    let last = parsed.lastPathComponent
                    if !last.isEmpty && last != "/" { return "@" + last }
                }
                return ""
            }()

            // Extract plain text from the oEmbed HTML <p> block
            let tweetText = Self.extractTextFromOEmbedHTML(rawHTML)
            guard !tweetText.isEmpty else { return nil }

            let title = tweetText.count > 80 ? String(tweetText.prefix(77)) + "…" : tweetText
            let bylineParts: [String?] = [
                authorName.isEmpty  ? nil : authorName,
                authorHandle.isEmpty ? nil : authorHandle
            ]
            let byline = bylineParts.compactMap { $0 }.joined(separator: " ")

            // Build reader-mode HTML with tweet text; images appended later
            let postHeader = buildPostHeaderHTML(authorName: authorName, authorHandle: authorHandle, time: "")
            let bodyHTML = "<div class=\"tweet-body\" style=\"font-size: 1.1em; line-height: 1.5; margin-bottom: 12px; white-space: pre-wrap; word-break: break-word;\">\(Self.htmlEscape(tweetText))</div>"
            let content = "<div class=\"tweet-post\" style=\"margin-bottom: 24px; padding-bottom: 16px; border-bottom: 1px solid var(--divider, rgba(128,128,128,0.2));\">\(postHeader)\(bodyHTML)</div>"

            return ReaderArticle(
                title: title,
                byline: byline,
                siteName: "X",
                content: content,
                excerpt: title,
                url: url,
                extractedAt: Date()
            )
        } catch {
            return nil
        }
    }

    // MARK: - Twitter CDN Image Scrape

    /// Loads the tweet page in a hidden WKWebView and extracts any CDN image URLs.
    /// CDN images (pbs.twimg.com) load without authentication — this is how images
    /// showed in the old Reader Mode even when tweet text was blocked by the login wall.
    ///
    /// Uses a short polling window (5 × 500 ms = 2.5 s + page load) since images
    /// appear in the DOM quickly from CDN; runs in parallel with the oEmbed call.
    private func extractTwitterImagesOnly(url: URL) async -> [String] {
        await withCheckedContinuation { continuation in
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .default()
            let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 393, height: 852), configuration: config)
            wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

            var sessionKey: ObjectIdentifier?
            let delegate = TwitterImageDelegate(
                continuation: continuation,
                onResolve: { [weak self] in
                    if let key = sessionKey {
                        self?.imageSessions.removeValue(forKey: key)
                    }
                }
            )
            wv.navigationDelegate = delegate
            let key = ObjectIdentifier(wv)
            sessionKey = key
            imageSessions[key] = (wv, delegate)

            delegate.startTimeout(seconds: 10)
            wv.load(URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 10))
        }
    }

    // MARK: - WKWebView Full Extraction (non-Twitter and oEmbed fallback)

    private func extractViaWebView(url: URL) async throws -> ReaderArticle {
        if readabilityJS == nil { loadReadabilityJS() }
        guard let js = readabilityJS else {
            throw ExtractionError.readabilityJSNotFound
        }

        return try await withCheckedThrowingContinuation { continuation in
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .default()
            let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 393, height: 852), configuration: config)
            wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

            var sessionKey: ObjectIdentifier?
            let delegate = ExtractionDelegate(
                url: url,
                readabilityJS: js,
                continuation: continuation,
                onResolve: { [weak self] _ in
                    if let key = sessionKey { self?.activeSessions.removeValue(forKey: key) }
                }
            )
            wv.navigationDelegate = delegate
            let key = ObjectIdentifier(wv)
            sessionKey = key
            activeSessions[key] = (wv, delegate)

            delegate.startTimeout(seconds: Self.extractionTimeoutSeconds)
            wv.load(URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: Self.extractionTimeoutSeconds))
        }
    }

    // MARK: - Helpers

    /// Appends CDN image `<img>` tags to the article's content HTML.
    private func appendImages(_ imageURLs: [String], to article: ReaderArticle) -> ReaderArticle {
        guard !imageURLs.isEmpty else { return article }
        let imgHTML = imageURLs.map { src in
            "<p><img src=\"\(src)\" style=\"max-width:100%; border-radius:12px; margin:12px 0;\"/></p>"
        }.joined()
        // Insert images inside the tweet-post div, after the body text
        let updatedContent = article.content.replacingOccurrences(
            of: "</div>",
            with: "\(imgHTML)</div>",
            options: .backwards  // Replace the last closing div (the tweet-post wrapper)
        )
        return ReaderArticle(
            title: article.title,
            byline: article.byline,
            siteName: article.siteName,
            content: updatedContent,
            excerpt: article.excerpt,
            url: article.url,
            extractedAt: article.extractedAt
        )
    }

    private func buildPostHeaderHTML(authorName: String, authorHandle: String, time: String) -> String {
        var header = "<div style=\"font-size: 0.9em; font-weight: 600; margin-bottom: 6px; color: var(--fg-muted, #536471);\">"
        if !authorName.isEmpty   { header += "<span>\(Self.htmlEscape(authorName))</span> " }
        if !authorHandle.isEmpty { header += "<span style=\"font-weight: normal; color: var(--fg-muted, gray);\">\(Self.htmlEscape(authorHandle))</span>" }
        if !time.isEmpty         { header += " · <span style=\"font-weight: normal; color: var(--fg-muted, gray);\">\(Self.htmlEscape(time))</span>" }
        header += "</div>"
        return header
    }

    /// Extracts the display text from the oEmbed HTML payload's `<p>` block.
    public static func extractTextFromOEmbedHTML(_ html: String) -> String {
        guard let pStart = html.range(of: "<p")?.lowerBound,
              let pContentStart = html[pStart...].range(of: ">")?.upperBound,
              let pEnd = html[pContentStart...].range(of: "</p>")?.lowerBound else {
            return ""
        }
        var text = String(html[pContentStart..<pEnd])

        // Convert <br> tags to newlines before stripping remaining HTML
        text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        // Strip remaining HTML tags (links, spans, etc.)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

        // Decode common HTML entities (decode &amp; last to avoid double-decoding)
        let entities: [(String, String)] = [
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&#x27;", "'"),
            ("&#8217;", "'"), ("&rsquo;", "'"), ("&#8216;", "'"), ("&lsquo;", "'"),
            ("&#8220;", "\u{201C}"), ("&ldquo;", "\u{201C}"),
            ("&#8221;", "\u{201D}"), ("&rdquo;", "\u{201D}"),
            ("&lt;", "<"), ("&gt;", ">"), ("&mdash;", "—"), ("&ndash;", "–"),
            ("&hellip;", "…"), ("&nbsp;", " "), ("&#10;", "\n"), ("&amp;", "&")
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        text = text.replacingOccurrences(of: "\n\n+", with: "\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Escapes `<`, `>`, `&`, `"` for safe embedding in HTML text nodes and attributes.
    nonisolated static func htmlEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Script Helpers

    /// Generates the JavaScript IIFE snippet used to extract posts from an X/Twitter DOM.
    ///
    /// Returns `{ title, byline, siteName, content, excerpt, hasText }` when tweet text
    /// is present in the DOM (React has hydrated), or `null` when unhydrated/login-gated.
    ///
    /// Key design decisions:
    /// - Uses `article[data-testid="tweet"]` (stable, avoids SSR loading-skeleton articles).
    /// - `hasText: true` only when actual tweet text is found — images-only content keeps polling.
    /// - Removed dead CSS class selectors (.whitespace-pre-wrap, .break-words) that no
    ///   longer match X.com's obfuscated/hashed CSS class names in production.
    public static func buildTwitterExtractionScript() -> String {
        """
        (function() {
          try {
            var articles = document.querySelectorAll('article[data-testid="tweet"]');
            if (articles.length === 0) return null;

            var threadHtml = [];
            var mainTitle = '';
            var authorName = '';
            var authorHandle = '';
            var rootTime = '';
            var foundText = false;

            for (var i = 0; i < articles.length; i++) {
              var a = articles[i];
              var timeEl = a.querySelector('time');
              var tweetTime = timeEl ? (timeEl.innerText.trim() || timeEl.getAttribute('datetime') || '') : '';

              if (i === 0) {
                rootTime = tweetTime;
                var userNameEl = a.querySelector('[data-testid="User-Name"]');
                if (userNameEl) {
                  var anchors = userNameEl.querySelectorAll('a[href^="/"]');
                  for (var u = 0; u < anchors.length; u++) {
                    var txt = anchors[u].innerText.trim();
                    if (txt.indexOf('@') === 0 && !authorHandle) { authorHandle = txt; }
                    else if (txt && !authorName && txt.indexOf('@') === -1) { authorName = txt; }
                  }
                }
                if (!authorHandle && !authorName) {
                  var userAnchors = a.querySelectorAll('a[href^="/"]');
                  for (var ua = 0; ua < userAnchors.length; ua++) {
                    var utxt = userAnchors[ua].innerText.trim();
                    if (utxt.indexOf('@') === 0 && !authorHandle) { authorHandle = utxt; }
                    else if (utxt && !authorName && utxt.indexOf('@') === -1 && utxt.indexOf('\\n') === -1) { authorName = utxt; }
                  }
                }
              }

              if (i > 0) {
                if (!authorHandle) continue;
                var thisHandle = '';
                var thisNameEl = a.querySelector('[data-testid="User-Name"]');
                if (thisNameEl) {
                  var thisAnchors = thisNameEl.querySelectorAll('a[href^="/"]');
                  for (var tu = 0; tu < thisAnchors.length; tu++) {
                    var ttxt = thisAnchors[tu].innerText.trim();
                    if (ttxt.indexOf('@') === 0) { thisHandle = ttxt; break; }
                  }
                }
                if (!thisHandle) {
                  var fallbackAnchors = a.querySelectorAll('a[href^="/"]');
                  for (var fa = 0; fa < fallbackAnchors.length; fa++) {
                    var ftxt = fallbackAnchors[fa].innerText.trim();
                    if (ftxt.indexOf('@') === 0) { thisHandle = ftxt; break; }
                  }
                }
                if (thisHandle.toLowerCase() !== authorHandle.toLowerCase()) continue;
              }

              var tweetTextEl = a.querySelector('[data-testid="tweetText"]');
              if (!tweetTextEl) {
                var dirAutoList = a.querySelectorAll('div[dir="auto"]');
                for (var d = 0; d < dirAutoList.length; d++) {
                  var candidate = dirAutoList[d];
                  if (candidate.closest('a') || candidate.closest('button')) continue;
                  if (candidate.querySelector('[data-testid]')) continue;
                  var candidateText = candidate.innerText.trim();
                  if (candidateText && candidateText !== authorName && candidateText !== authorHandle && candidateText.length > 3) {
                    tweetTextEl = candidate;
                    break;
                  }
                }
              }

              var tweetText = tweetTextEl ? tweetTextEl.innerHTML : '';
              var rawText   = tweetTextEl ? tweetTextEl.innerText.trim() : '';
              var imgs = a.querySelectorAll('img[src*="pbs.twimg.com/media"]');

              if (!tweetText && !rawText && imgs.length === 0) continue;
              if (rawText) foundText = true;

              if (!mainTitle) {
                mainTitle = rawText ? (rawText.length > 80 ? rawText.substring(0, 77) + '…' : rawText) : ('Post by ' + (authorName || authorHandle));
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

              var bodyHtml = tweetText
                ? '<div class="tweet-body" style="font-size: 1.1em; line-height: 1.5; margin-bottom: 12px; white-space: pre-wrap; word-break: break-word;">' + tweetText + '</div>'
                : '';

              threadHtml.push('<div class="tweet-post" style="margin-bottom: 24px; padding-bottom: 16px; border-bottom: 1px solid var(--divider, rgba(128,128,128,0.2));">'
                + (i > 0 ? '<p style="font-size: 0.85em; color: var(--fg-muted, gray); margin-bottom: 6px;">Thread continuation</p>' : postHeader)
                + bodyHtml + imgHtml + '</div>');
            }

            if (threadHtml.length > 0) {
              var byline = (authorName || '') + (authorHandle ? ' (' + authorHandle + ')' : '') + (rootTime ? ' · ' + rootTime : '');
              return {
                title: mainTitle || document.title || 'Post on X',
                byline: byline.trim(),
                siteName: 'X',
                content: threadHtml.join(''),
                excerpt: mainTitle,
                hasText: foundText
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
              let source = try? String(contentsOf: url, encoding: .utf8) else { return }
        readabilityJS = source
    }
}

// MARK: - Twitter CDN Image Delegate

/// Lightweight WKNavigationDelegate that only scrapes CDN image URLs from an X.com page.
/// CDN images load from `pbs.twimg.com` without authentication; this delegate collects them
/// and resolves quickly (5 polls × 500 ms = 2.5 s max after page load).
@MainActor
private final class TwitterImageDelegate: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<[String], Never>?
    private var onResolve: (() -> Void)?
    private var isResolved = false
    private var timeoutTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var pollCount = 0
    private static let maxPolls = 5
    private static let pollIntervalNanos: UInt64 = 500_000_000  // 500 ms

    /// Collects unique pbs.twimg.com media/card images, excluding profile pics and emoji.
    private static let imageScript = """
    (function() {
      var imgs = document.querySelectorAll('img[src*="pbs.twimg.com"]');
      var seen = {};
      var srcs = [];
      for (var i = 0; i < imgs.length; i++) {
        var src = imgs[i].src || '';
        if (!src || seen[src]) continue;
        if (src.indexOf('profile_images') !== -1) continue;
        if (src.indexOf('emoji') !== -1) continue;
        seen[src] = true;
        srcs.push(src);
      }
      return srcs.length > 0 ? srcs : null;
    })()
    """

    init(continuation: CheckedContinuation<[String], Never>, onResolve: @escaping () -> Void) {
        self.continuation = continuation
        self.onResolve = onResolve
    }

    func startTimeout(seconds: TimeInterval) {
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, !self.isResolved else { return }
            self.resolve(with: [])
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !isResolved, pollTask == nil else { return }
        attemptImageExtraction(in: webView)
    }

    private func attemptImageExtraction(in webView: WKWebView) {
        webView.evaluateJavaScript(Self.imageScript) { [weak self] result, _ in
            guard let self, !self.isResolved else { return }
            if let srcs = result as? [String], !srcs.isEmpty {
                self.resolve(with: srcs)
                return
            }
            self.pollCount += 1
            if self.pollCount < Self.maxPolls {
                self.pollTask = Task { @MainActor [weak self, weak webView] in
                    try? await Task.sleep(nanoseconds: Self.pollIntervalNanos)
                    guard let self, !self.isResolved, let wv = webView else { return }
                    self.pollTask = nil
                    self.attemptImageExtraction(in: wv)
                }
            } else {
                self.resolve(with: [])
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard !isResolved else { return }
        resolve(with: [])
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard !isResolved else { return }
        resolve(with: [])
    }

    private func resolve(with images: [String]) {
        guard !isResolved else { return }
        isResolved = true
        timeoutTask?.cancel(); timeoutTask = nil
        pollTask?.cancel();    pollTask = nil
        continuation?.resume(returning: images)
        continuation = nil
        onResolve?(); onResolve = nil
    }
}

// MARK: - Full Extraction Delegate (WKNavigationDelegate)

/// WKNavigationDelegate used for the full Readability/Twitter DOM extraction path.
/// For non-Twitter sites: accepts any non-empty Readability content.
/// For Twitter (fallback only): requires `hasText: true` to avoid resolving too early
/// with images-only content from the pre-hydration DOM.
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
    private let isTwitterURL: Bool
    private var maxHydrationPolls: Int { isTwitterURL ? 20 : 10 }
    private var pollIntervalNanos: UInt64 { isTwitterURL ? 500_000_000 : 400_000_000 }

    init(url: URL, readabilityJS: String,
         continuation: CheckedContinuation<ReaderArticle, Error>,
         onResolve: @escaping (Result<ReaderArticle, Error>) -> Void) {
        self.url = url
        self.readabilityJS = readabilityJS
        self.continuation = continuation
        self.onResolve = onResolve
        self.isTwitterURL = ReaderExtractor.isTwitterURL(url)
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
                if let errMsg = dict["error"] as? String { self.lastScriptError = errMsg }
                if let content = dict["content"] as? String,
                   !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let hasText = dict["hasText"] as? Bool ?? true
                    if self.isTwitterURL && !hasText {
                        // Images-only on a Twitter fallback page — keep polling for text
                    } else {
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
                }
            } else if let error = error {
                self.lastScriptError = error.localizedDescription
            }

            self.pollCount += 1
            if self.pollCount < self.maxHydrationPolls {
                self.pollTask = Task { @MainActor [weak self, weak webView] in
                    try? await Task.sleep(nanoseconds: self?.pollIntervalNanos ?? 400_000_000)
                    guard let self, !self.isResolved, let wv = webView else { return }
                    self.pollTask = nil
                    self.attemptExtraction(in: wv)
                }
            } else {
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

    private func buildExtractionScript() -> String {
        let twitterScript = ReaderExtractor.buildTwitterExtractionScript()
        return """
        (function() {
          try {
            var host = window.location.hostname || '';
            var isTwitter = host === 'x.com' || host.endsWith('.x.com') || host === 'twitter.com' || host.endsWith('.twitter.com');
            if (isTwitter) { return (\(twitterScript)); }
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
        timeoutTask?.cancel(); timeoutTask = nil
        pollTask?.cancel();    pollTask = nil
        continuation?.resume(with: result)
        continuation = nil
        onResolve?(result); onResolve = nil
    }
}
