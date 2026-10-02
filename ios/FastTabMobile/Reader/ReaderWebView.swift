import SwiftUI
import WebKit

// MARK: - Message handler names (JS → Swift bridge)

private enum JSMessage: String, CaseIterable {
    case scrollProgress   // { progress: Double }
    case contentFitsViewport // { fits: Bool } — nothing to scroll (short article)
    case textSelected     // { text: String, range: String }
    case textDeselected   // {}
    case highlightTapped  // { id: String }
    case ready            // fired once template is ready
    case videoVisibility  // { visible: Bool } — transcript page opened/closed its corner player
    case videoSize        // { large: Bool } — transcript player switched Corner ↔ Large
    case transcriptVisible // { first: Int, last: Int } — transcript paragraphs on screen
    case readAloudTap     // { text: String, offset: Int } — paragraph tapped (Read Aloud jump)
}

// MARK: - ReaderWebView

/// `UIViewRepresentable` wrapping a `WKWebView` that renders the reader HTML template.
/// Communicates with `ReaderViewModel` via `@Binding` and callbacks.
public struct ReaderWebView: UIViewRepresentable {

    public var viewModel: ReaderViewModel
    public let article: ReaderArticle
    /// Current system appearance from the SwiftUI environment. Changing it
    /// re-triggers `updateUIView`, which re-resolves the `.system` colour scheme.
    public var systemIsDark: Bool

    /// Called when the user selects text (show highlight bar)
    public var onTextSelected: ((String, String) -> Void)?
    /// Called when the user deselects text
    public var onTextDeselected: (() -> Void)?
    /// Called when user taps an existing highlight
    public var onHighlightTapped: ((String) -> Void)?
    /// Called as the user scrolls: `true` to hide the navigation header, `false` to show it.
    public var onHeaderHiddenChanged: ((Bool) -> Void)?
    /// Read Aloud progress to highlight; nil when Read Aloud has never started.
    var readAloud: ReadAloudPageState?
    /// The user started dragging the page (Read Aloud pauses auto-scroll).
    var onUserBeganScrolling: (() -> Void)?
    /// A paragraph was tapped: the page's normalised text + the tapped UTF-16 offset in it.
    var onReadAloudTap: ((String, Int) -> Void)?

    init(
        viewModel: ReaderViewModel,
        article: ReaderArticle,
        systemIsDark: Bool = false,
        onTextSelected: ((String, String) -> Void)? = nil,
        onTextDeselected: (() -> Void)? = nil,
        onHighlightTapped: ((String) -> Void)? = nil,
        onHeaderHiddenChanged: ((Bool) -> Void)? = nil,
        readAloud: ReadAloudPageState? = nil,
        onUserBeganScrolling: (() -> Void)? = nil,
        onReadAloudTap: ((String, Int) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.article = article
        self.systemIsDark = systemIsDark
        self.onTextSelected = onTextSelected
        self.onTextDeselected = onTextDeselected
        self.onHighlightTapped = onHighlightTapped
        self.onHeaderHiddenChanged = onHeaderHiddenChanged
        self.readAloud = readAloud
        self.onUserBeganScrolling = onUserBeganScrolling
        self.onReadAloudTap = onReadAloudTap
    }

    // MARK: - UIViewRepresentable

    public func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel, onTextSelected: onTextSelected,
                    onTextDeselected: onTextDeselected, onHighlightTapped: onHighlightTapped,
                    onHeaderHiddenChanged: onHeaderHiddenChanged)
    }

    public func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Transcript pages embed a small YouTube player that must play in place (not full
        // screen) and start from a timestamp tap.
        config.allowsInlineMediaPlayback = true
        // Only transcript pages: other articles keep the default (no autoplay).
        if article.youtubeVideoID != nil { config.mediaTypesRequiringUserActionForPlayback = [] }
        JSMessage.allCases.forEach {
            config.userContentController.add(context.coordinator, name: $0.rawValue)
        }

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        wv.scrollView.delegate = context.coordinator
        wv.scrollView.contentInsetAdjustmentBehavior = .automatic
        wv.isOpaque = true
        let bgColor = UIColor(readerHex: viewModel.readerSettings.effectiveBackgroundHex(
            systemIsDark: wv.traitCollection.userInterfaceStyle == .dark))
        wv.backgroundColor = bgColor
        wv.scrollView.backgroundColor = bgColor

        context.coordinator.webView = wv
        loadTemplate(into: wv, coordinator: context.coordinator)
        return wv
    }

    public static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        JSMessage.allCases.forEach {
            uiView.configuration.userContentController.removeScriptMessageHandler(forName: $0.rawValue)
        }
        uiView.navigationDelegate = nil
        uiView.scrollView.delegate = nil
        coordinator.invalidate()
    }

    public func updateUIView(_ webView: WKWebView, context: Context) {
        // Reading-settings changes — push the full CSS-var set only when the
        // resolved signature actually changed (avoids IPC churn while scrolling).
        let settings = viewModel.readerSettings
        let theme = ReaderResolvedTheme.resolve(backgroundHex: settings.effectiveBackgroundHex(systemIsDark: systemIsDark))
        let signature = [
            "\(settings.fontSize)", settings.fontFamily.rawValue,
            "\(settings.lineHeight.value)", settings.colorScheme.rawValue,
            theme.backgroundHex
        ].joined(separator: "|")
        if context.coordinator.lastAppliedSettingsSignature != signature {
            context.coordinator.lastAppliedSettingsSignature = signature
            let bgColor = UIColor(readerHex: theme.backgroundHex)
            webView.backgroundColor = bgColor
            webView.scrollView.backgroundColor = bgColor
            webView.evaluateJavaScript(Self.settingsJS(settings: settings, theme: theme), completionHandler: nil)
        }

        if article.youtubeVideoID != nil, context.coordinator.lastVideoVisible != viewModel.isVideoVisible {
            context.coordinator.lastVideoVisible = viewModel.isVideoVisible
            webView.evaluateJavaScript(
                "window.ftSetVideoVisible && ftSetVideoVisible(\(viewModel.isVideoVisible));", completionHandler: nil)
        }

        context.coordinator.onUserBeganScrolling = onUserBeganScrolling
        context.coordinator.onReadAloudTap = onReadAloudTap
        if let readAloud {
            context.coordinator.readAloudSync.webView = webView
            context.coordinator.readAloudSync.apply(readAloud)
        }

        // Transcript clean-up: on a new revision, push the paragraphs whose text or version changed.
        if let cleanup = viewModel.transcriptCleanup, cleanup.revision != context.coordinator.pushedTranscriptRevision {
            context.coordinator.pushedTranscriptRevision = cleanup.revision
            let changed = cleanup.shownTexts.filter { context.coordinator.pushedTranscript[$0.i] != $0 }
            context.coordinator.pushTranscript(changed)
        }

        // If viewModel requests a new highlight, apply it safely via JSON payload
        if let h = viewModel.pendingHighlightToApply {
            let payload: [String: String] = [
                "id": h.id,
                "range": h.serializedRange,
                "color": h.color.cssRGBA
            ]
            if let data = try? JSONEncoder().encode(payload),
               let jsonString = String(data: data, encoding: .utf8) {
                let applyJS = "applyHighlightPayload(\(jsonString));"
                webView.evaluateJavaScript(applyJS, completionHandler: nil)
            }
            DispatchQueue.main.async {
                viewModel.pendingHighlightToApply = nil
            }
        }

        // If viewModel requests highlight removal, remove from DOM
        if let removeID = viewModel.highlightToRemoveID {
            let removeJS = "removeHighlight('\(removeID)');"
            webView.evaluateJavaScript(removeJS, completionHandler: nil)
            DispatchQueue.main.async {
                viewModel.highlightToRemoveID = nil
            }
        }

        // If viewModel requests clearing all highlights
        if viewModel.pendingClearAllHighlights {
            let clearJS = "removeAllHighlights();"
            webView.evaluateJavaScript(clearJS, completionHandler: nil)
            DispatchQueue.main.async {
                viewModel.pendingClearAllHighlights = false
            }
        }
    }

    // MARK: - Template Loading

    private struct ArticleBootstrapData: Encodable {
        struct HighlightItem: Encodable {
            let id: String
            let range: String
            let color: String
        }

        let title: String
        let byline: String
        let siteName: String
        let content: String
        let fontSize: Int
        let fontBody: String
        let fontTitle: String
        let lineHeight: Double
        let theme: String
        let bg: String
        let fg: String
        let fgMuted: String
        let fgMeta: String
        let link: String
        let divider: String
        let codeBg: String
        let initialProgress: Double
        let highlights: [HighlightItem]
        let focusHighlightID: String?
        let youtubeVideoID: String?
        /// Transcript paragraphs shown in their clean version at load (TranscriptCleanupSession).
        let transcriptTexts: [TranscriptCleanupSession.ParagraphText]
        let videoVisible: Bool
        let videoLarge: Bool
    }

    /// JS that applies the full settings-derived CSS-var set. Shared by the live
    /// `updateUIView` path; the bootstrap path applies the same values on load.
    static func settingsJS(settings: ReaderReadingSettings, theme: ReaderResolvedTheme) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        }
        return """
        (function(){var r=document.documentElement.style;
        r.setProperty('--reader-font-size','\(settings.fontSize)px');
        r.setProperty('--reader-font-body','\(esc(settings.fontFamily.cssBodyStack))');
        r.setProperty('--reader-font-title','\(esc(settings.fontFamily.cssTitleStack))');
        r.setProperty('--reader-line-height','\(settings.lineHeight.value)');
        r.setProperty('--bg','\(theme.backgroundHex)');
        r.setProperty('--fg','\(theme.foregroundHex)');
        r.setProperty('--fg-muted','\(theme.mutedHex)');
        r.setProperty('--fg-meta','\(theme.metaHex)');
        r.setProperty('--link','\(theme.linkHex)');
        r.setProperty('--divider','\(theme.dividerRGBA)');
        r.setProperty('--code-bg','\(theme.codeBackgroundRGBA)');
        document.documentElement.dataset.theme='\(theme.isDark ? "dark" : "light")';})();
        """
    }

    private func loadTemplate(into webView: WKWebView, coordinator: Coordinator) {
        coordinator.resetPushedTranscript(viewModel.transcriptCleanup)
        Self.loadTemplate(into: webView, viewModel: viewModel, article: article,
                          focusHighlightID: viewModel.focusHighlightID)
        // Rebuild the full template on demand: iOS kills the WKWebView content
        // process when the screen is locked / app is backgrounded for a while,
        // leaving a blank page. The reload reads fresh progress/highlights/
        // fontSize from the viewModel so scroll position is restored (and skips
        // the one-time focus-highlight jump, which already happened).
        coordinator.reloadHandler = { [weak webView, weak coordinator, viewModel, article] in
            guard let webView else { return }
            coordinator?.resetPushedTranscript(viewModel.transcriptCleanup)
            Self.loadTemplate(into: webView, viewModel: viewModel, article: article,
                              focusHighlightID: nil)
        }
    }

    static func loadTemplate(into webView: WKWebView, viewModel: ReaderViewModel, article: ReaderArticle,
                             focusHighlightID: String? = nil) {
        guard let templateURL = Bundle.main.url(forResource: "reader_template", withExtension: "html") ??
                                Bundle.main.url(forResource: "reader_template", withExtension: "html", subdirectory: "Resources"),
              var templateHTML = try? String(contentsOf: templateURL, encoding: .utf8) else {
            return
        }

        let highlightItems = viewModel.highlights.map {
            ArticleBootstrapData.HighlightItem(id: $0.id, range: $0.serializedRange, color: $0.color.cssRGBA)
        }
        let settings = viewModel.readerSettings
        // Best-known appearance at load time; `updateUIView` corrects it right
        // after if the SwiftUI environment disagrees.
        let systemIsDark = UITraitCollection.current.userInterfaceStyle == .dark
        let theme = ReaderResolvedTheme.resolve(backgroundHex: settings.effectiveBackgroundHex(systemIsDark: systemIsDark))
        let bootstrapData = ArticleBootstrapData(
            title: article.title,
            byline: article.byline,
            siteName: article.siteName,
            content: article.content,
            fontSize: settings.fontSize,
            fontBody: settings.fontFamily.cssBodyStack,
            fontTitle: settings.fontFamily.cssTitleStack,
            lineHeight: settings.lineHeight.value,
            theme: theme.isDark ? "dark" : "light",
            bg: theme.backgroundHex,
            fg: theme.foregroundHex,
            fgMuted: theme.mutedHex,
            fgMeta: theme.metaHex,
            link: theme.linkHex,
            divider: theme.dividerRGBA,
            codeBg: theme.codeBackgroundRGBA,
            initialProgress: viewModel.scrollProgress,
            highlights: highlightItems,
            focusHighlightID: focusHighlightID,
            youtubeVideoID: article.youtubeVideoID,
            transcriptTexts: viewModel.transcriptCleanup?.shownTexts.filter { $0.v == "clean" } ?? [],
            videoVisible: viewModel.isVideoVisible,
            videoLarge: viewModel.isVideoLarge
        )

        var jsonString = "{}"
        if let data = try? JSONEncoder().encode(bootstrapData),
           let str = String(data: data, encoding: .utf8) {
            // Prevent </script> tag breakout in HTML parsing
            jsonString = str.replacingOccurrences(of: "</", with: "<\\/")
        }

        // Inject article data as an embedded JSON data block
        let bootstrap = """
        <script id="fasttab-article-data" type="application/json">
        \(jsonString)
        </script>
        """
        templateHTML = templateHTML.replacingOccurrences(of: "<!-- BOOTSTRAP -->", with: bootstrap)

        webView.loadHTMLString(templateHTML, baseURL: Self.baseURL(for: article))
    }

    /// Embed origin for transcript pages. YouTube rejects embeds (error 152) whose parent page
    /// has no real https origin/Referer of its own; a page posing as youtube.com fails too.
    /// Must match `YT_EMBED_ORIGIN` in reader_template.html.
    static let youtubeEmbedOrigin = URL(string: "https://fasttab.theindie.app/")!

    /// Articles load from their own URL so relative images and links resolve; transcript pages
    /// (no relative resources) load from our own origin so the YouTube player accepts the embed.
    static func baseURL(for article: ReaderArticle) -> URL? {
        article.youtubeVideoID != nil ? youtubeEmbedOrigin : article.url
    }
}

// MARK: - Coordinator

public final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, UIScrollViewDelegate {
    weak var webView: WKWebView?
    var lastAppliedSettingsSignature: String?
    /// Player visibility last pushed to (or reported by) the page.
    var lastVideoVisible = false
    /// Transcript paragraphs as the page shows them, by index (bootstrap, then pushes).
    var pushedTranscript: [Int: TranscriptCleanupSession.ParagraphText] = [:]

    var pushedTranscriptRevision: Int?
    @MainActor lazy var readAloudSync = ReadAloudPageSync()
    var onUserBeganScrolling: (() -> Void)?
    var onReadAloudTap: ((String, Int) -> Void)?
    /// What the page was loaded with (bootstrap). Pushes sent before the page is ready are
    /// lost, so `ready` re-sends whatever differs from this.
    private var loadedTranscript: [Int: TranscriptCleanupSession.ParagraphText] = [:]

    /// The page is about to load with the session's current texts.
    @MainActor func resetPushedTranscript(_ cleanup: TranscriptCleanupSession?) {
        loadedTranscript = Dictionary(uniqueKeysWithValues: (cleanup?.shownTexts ?? []).map { ($0.i, $0) })
        pushedTranscript = loadedTranscript
        pushedTranscriptRevision = cleanup?.revision
    }

    @MainActor func pushTranscript(_ texts: [TranscriptCleanupSession.ParagraphText]) {
        guard let webView, !texts.isEmpty, let data = try? JSONEncoder().encode(texts),
              let json = String(data: data, encoding: .utf8) else { return }
        texts.forEach { pushedTranscript[$0.i] = $0 }
        webView.evaluateJavaScript("window.ftSetTranscriptTexts && ftSetTranscriptTexts(\(json));",
                                   completionHandler: nil)
    }
    private let viewModel: ReaderViewModel
    private let onTextSelected: ((String, String) -> Void)?
    private let onTextDeselected: (() -> Void)?
    private let onHighlightTapped: ((String) -> Void)?
    private let onHeaderHiddenChanged: ((Bool) -> Void)?

    // Scroll-direction tracking for header auto-hide
    private var lastContentOffsetY: CGFloat = 0
    private var isHeaderHidden = false
    /// Small dead zone right at the top where the header always stays visible (bounce, pull-to-refresh).
    private let topRevealThreshold: CGFloat = 8
    /// Rebuilds the reader template after the web content process dies.
    /// Set by `ReaderWebView.loadTemplate(into:coordinator:)`.
    var reloadHandler: (() -> Void)?
    private var activeObserver: NSObjectProtocol?

    init(viewModel: ReaderViewModel,
         onTextSelected: ((String, String) -> Void)?,
         onTextDeselected: (() -> Void)?,
         onHighlightTapped: ((String) -> Void)?,
         onHeaderHiddenChanged: ((Bool) -> Void)? = nil) {
        self.viewModel = viewModel
        self.lastAppliedSettingsSignature = nil
        self.onTextSelected = onTextSelected
        self.onTextDeselected = onTextDeselected
        self.onHighlightTapped = onHighlightTapped
        self.onHeaderHiddenChanged = onHeaderHiddenChanged
        super.init()
        // Safety net: a blank page can survive without the terminate callback
        // (suspended renderer, discarded tiles). Re-check content on foreground.
        activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.recoverIfBlank()
        }
    }

    func invalidate() {
        if let activeObserver {
            NotificationCenter.default.removeObserver(activeObserver)
            self.activeObserver = nil
        }
        reloadHandler = nil
    }

    deinit {
        if let activeObserver {
            NotificationCenter.default.removeObserver(activeObserver)
        }
    }

    /// If the reader body is empty (process died without the terminate
    /// callback firing), rebuild the template. Otherwise do nothing so we
    /// never disturb the user's scroll position.
    private func recoverIfBlank() {
        guard let webView else { return }
        webView.evaluateJavaScript(
            "document.getElementById('reader-body') ? document.getElementById('reader-body').innerHTML.length : -1"
        ) { [weak self] result, _ in
            guard let self else { return }
            if let length = result as? Int, length > 0 { return }
            if let length = result as? NSNumber, length.intValue > 0 { return }
            self.reloadHandler?()
        }
    }

    // MARK: - UIScrollViewDelegate

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating else { return }

        let offsetY = scrollView.contentOffset.y
        let delta = offsetY - lastContentOffsetY
        lastContentOffsetY = offsetY

        if offsetY <= topRevealThreshold {
            setHeaderHidden(false)
        } else if delta > 0 {
            setHeaderHidden(true)
        } else if delta < 0 {
            setHeaderHidden(false)
        }
    }

    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        onUserBeganScrolling?()
    }

    private func setHeaderHidden(_ hidden: Bool) {
        guard hidden != isHeaderHidden else { return }
        isHeaderHidden = hidden
        onHeaderHiddenChanged?(hidden)
    }

    // MARK: - WKScriptMessageHandler

    public func userContentController(_ userContentController: WKUserContentController,
                                       didReceive message: WKScriptMessage) {
        guard let name = JSMessage(rawValue: message.name) else { return }
        let body = message.body as? [String: Any] ?? [:]

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch name {
            case .scrollProgress:
                if let p = body["progress"] as? Double {
                    let immediate = body["immediate"] as? Bool ?? false
                    self.viewModel.updateScrollProgress(p, immediate: immediate)
                }
            case .contentFitsViewport:
                self.viewModel.contentFitsViewportChanged(body["fits"] as? Bool ?? false)
            case .textSelected:
                let text = body["text"] as? String ?? ""
                let range = body["range"] as? String ?? ""
                self.onTextSelected?(text, range)
            case .textDeselected:
                self.onTextDeselected?()
            case .highlightTapped:
                if let id = body["id"] as? String {
                    self.onHighlightTapped?(id)
                }
            case .readAloudTap:
                if let text = body["text"] as? String, let offset = body["offset"] as? Int {
                    self.onReadAloudTap?(text, offset)
                }
            case .videoVisibility:
                let visible = body["visible"] as? Bool ?? false
                self.lastVideoVisible = visible
                self.viewModel.videoVisibilityChanged(visible)
            case .videoSize:
                self.viewModel.videoSizeChanged(large: body["large"] as? Bool ?? false)
            case .transcriptVisible:
                if let first = body["first"] as? Int, let last = body["last"] as? Int {
                    self.viewModel.transcriptParagraphsVisible(first: first, last: last)
                }
            case .ready:
                // A push made while the page was still loading was a no-op there; send what
                // changed since the page's bootstrap now that it can take it.
                if let cleanup = self.viewModel.transcriptCleanup {
                    self.pushedTranscriptRevision = cleanup.revision
                    self.pushTranscript(cleanup.shownTexts.filter { self.loadedTranscript[$0.i] != $0 })
                }
            }
        }
    }

    // MARK: - WKNavigationDelegate

    /// iOS terminates the web content process when the screen is locked / the
    /// app stays backgrounded. Without this the reader stays blank forever.
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        reloadHandler?()
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                          decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Block navigations out of the reader template (links should open in Safari)
        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }
}
