import SwiftUI
import WebKit

/// A lightweight, non-interactive web view that loads and displays live webpage content
/// for a tab in the iOS App Switcher deck.
struct TabWebPreviewView: UIViewRepresentable {
    let url: URL
    let isVisible: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsAirPlayForMediaPlayback = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all

        // Prefer mobile viewport rendering
        let preferences = WKWebpagePreferences()
        preferences.preferredContentMode = .mobile
        configuration.defaultWebpagePreferences = preferences

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isUserInteractionEnabled = false
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.allowsBackForwardNavigationGestures = false
        webView.navigationDelegate = context.coordinator
        webView.alpha = 0
        webView.backgroundColor = .clear
        webView.isOpaque = false
        webView.scrollView.backgroundColor = .clear

        context.coordinator.webView = webView

        // Don't load here — let updateUIView handle it in one place
        // to avoid double-loading (makeUIView fires before url is set
        // on uiView, so the uiView.url == nil check would re-fire).
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        guard isVisible else {
            // Card left the active viewport — stop loading.
            if uiView.isLoading {
                uiView.stopLoading()
            }
            uiView.alpha = 0
            return
        }

        // Only load if we haven't loaded this URL yet (or the URL changed).
        if context.coordinator.currentURL != url {
            context.coordinator.currentURL = url
            let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 12)
            uiView.load(request)
        }
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        // Immediately release WebKit resources when the view is removed
        // from the hierarchy (card scrolled out of ±1 window).
        uiView.stopLoading()
        uiView.navigationDelegate = nil
        coordinator.webView = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        /// Tracks the last URL dispatched to `load()` so we don't re-load
        /// on every SwiftUI `updateUIView` call.
        var currentURL: URL?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            UIView.animate(withDuration: 0.25) {
                webView.alpha = 1.0
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            webView.alpha = 0
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            webView.alpha = 0
        }
    }
}
