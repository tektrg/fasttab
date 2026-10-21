import SwiftUI
import WebKit

/// The reader window's content: the article, a spinner while it loads, or a friendly failure
/// with a way out to the browser. "Open in Browser" sits in the toolbar either way.
struct MacReaderView: View {
    @ObservedObject var model: MacReaderModel

    var body: some View {
        contentView
            .frame(minWidth: 420, minHeight: 360)
            .navigationTitle(model.title)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { model.openInBrowser() } label: {
                        Label("Open in Browser", systemImage: "safari")
                    }
                    .help("Open this page in your browser")
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                }
            }
    }

    @ViewBuilder private var contentView: some View {
        switch model.content {
        case .loading:
            ProgressView("Getting the article ready…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .article(let html, let baseURL):
            MacReaderWebView(html: html, baseURL: baseURL, progressSink: model.progressSink)
        case .failed:
            failureView
        }
    }

    private var failureView: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("This page can't be shown in the reader")
                .font(.title3.weight(.semibold))
            Text("Some pages (logins, apps, videos) don't have an article FastTab can pull out.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open in Browser") { model.openInBrowser() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The article page. Links open in the browser; the page's scroll reports go to the sink.
struct MacReaderWebView: NSViewRepresentable {
    let html: String
    let baseURL: URL
    let progressSink: MacReaderProgressSink

    /// Every message name the shared template posts. Unused ones still need a handler.
    static let messageNames = ["scrollProgress", "contentFitsViewport", "ready", "textSelected", "textDeselected",
                               "highlightTapped", "readAloudTap", "transcriptVisible", "videoSize", "videoVisibility"]

    func makeCoordinator() -> Coordinator { Coordinator(progressSink: progressSink) }

    func makeNSView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        let handler = WeakMessageHandler(context.coordinator)
        Self.messageNames.forEach { controller.add(handler, name: $0) }
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.loadHTMLString(html, baseURL: baseURL)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        messageNames.forEach { webView.configuration.userContentController.removeScriptMessageHandler(forName: $0) }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let progressSink: MacReaderProgressSink

        init(progressSink: MacReaderProgressSink) { self.progressSink = progressSink }

        func handle(_ message: WKScriptMessage) {
            let body = message.body as? [String: Any] ?? [:]
            switch message.name {
            case "scrollProgress":
                if let progress = body["progress"] as? Double {
                    progressSink.receive(progress: progress, immediate: body["immediate"] as? Bool ?? false)
                }
            case "contentFitsViewport":
                progressSink.contentFitsViewport(body["fits"] as? Bool ?? false)
            default:
                break
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}

/// `WKUserContentController` retains its handlers; this keeps the coordinator out of that cycle.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: MacReaderWebView.Coordinator?

    init(_ target: MacReaderWebView.Coordinator) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { target?.handle(message) }
    }
}
