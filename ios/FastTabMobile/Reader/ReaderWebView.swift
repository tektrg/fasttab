import SwiftUI
import WebKit

// MARK: - Message handler names (JS → Swift bridge)

private enum JSMessage: String, CaseIterable {
    case scrollProgress   // { progress: Double }
    case textSelected     // { text: String, range: String }
    case textDeselected   // {}
    case highlightTapped  // { id: String }
    case ready            // fired once template is ready
}

// MARK: - ReaderWebView

/// `UIViewRepresentable` wrapping a `WKWebView` that renders the reader HTML template.
/// Communicates with `ReaderViewModel` via `@Binding` and callbacks.
public struct ReaderWebView: UIViewRepresentable {

    public var viewModel: ReaderViewModel
    public let article: ReaderArticle

    /// Called when the user selects text (show highlight bar)
    public var onTextSelected: ((String, String) -> Void)?
    /// Called when the user deselects text
    public var onTextDeselected: (() -> Void)?
    /// Called when user taps an existing highlight
    public var onHighlightTapped: ((String) -> Void)?

    public init(
        viewModel: ReaderViewModel,
        article: ReaderArticle,
        onTextSelected: ((String, String) -> Void)? = nil,
        onTextDeselected: (() -> Void)? = nil,
        onHighlightTapped: ((String) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.article = article
        self.onTextSelected = onTextSelected
        self.onTextDeselected = onTextDeselected
        self.onHighlightTapped = onHighlightTapped
    }

    // MARK: - UIViewRepresentable

    public func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel, onTextSelected: onTextSelected,
                    onTextDeselected: onTextDeselected, onHighlightTapped: onHighlightTapped)
    }

    public func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        JSMessage.allCases.forEach {
            config.userContentController.add(context.coordinator, name: $0.rawValue)
        }

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        wv.scrollView.contentInsetAdjustmentBehavior = .automatic
        wv.isOpaque = true
        let readerBgColor = DS.Palette.readerPageUIColor
        wv.backgroundColor = readerBgColor
        wv.scrollView.backgroundColor = readerBgColor

        context.coordinator.webView = wv
        loadTemplate(into: wv, coordinator: context.coordinator)
        return wv
    }

    public static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        JSMessage.allCases.forEach {
            uiView.configuration.userContentController.removeScriptMessageHandler(forName: $0.rawValue)
        }
        uiView.navigationDelegate = nil
    }

    public func updateUIView(_ webView: WKWebView, context: Context) {
        // Font-size changes — only push via JS when the font size actually changed
        if context.coordinator.lastAppliedFontSize != viewModel.fontSize {
            context.coordinator.lastAppliedFontSize = viewModel.fontSize
            let js = "document.documentElement.style.setProperty('--reader-font-size', '\(viewModel.fontSize)px');"
            webView.evaluateJavaScript(js, completionHandler: nil)
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
        let initialProgress: Double
        let highlights: [HighlightItem]
    }

    private func loadTemplate(into webView: WKWebView, coordinator: Coordinator) {
        guard let templateURL = Bundle.main.url(forResource: "reader_template", withExtension: "html") ??
                                Bundle.main.url(forResource: "reader_template", withExtension: "html", subdirectory: "Resources"),
              var templateHTML = try? String(contentsOf: templateURL, encoding: .utf8) else {
            return
        }

        let highlightItems = viewModel.highlights.map {
            ArticleBootstrapData.HighlightItem(id: $0.id, range: $0.serializedRange, color: $0.color.cssRGBA)
        }
        let bootstrapData = ArticleBootstrapData(
            title: article.title,
            byline: article.byline,
            siteName: article.siteName,
            content: article.content,
            fontSize: viewModel.fontSize,
            initialProgress: viewModel.scrollProgress,
            highlights: highlightItems
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

        // Load from article URL origin so relative images and links resolve properly
        webView.loadHTMLString(templateHTML, baseURL: article.url)
    }
}

// MARK: - Coordinator

public final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    weak var webView: WKWebView?
    var lastAppliedFontSize: Int?
    private let viewModel: ReaderViewModel
    private let onTextSelected: ((String, String) -> Void)?
    private let onTextDeselected: (() -> Void)?
    private let onHighlightTapped: ((String) -> Void)?

    init(viewModel: ReaderViewModel,
         onTextSelected: ((String, String) -> Void)?,
         onTextDeselected: (() -> Void)?,
         onHighlightTapped: ((String) -> Void)?) {
        self.viewModel = viewModel
        self.lastAppliedFontSize = viewModel.fontSize
        self.onTextSelected = onTextSelected
        self.onTextDeselected = onTextDeselected
        self.onHighlightTapped = onHighlightTapped
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
            case .ready:
                break
            }
        }
    }

    // MARK: - WKNavigationDelegate

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
