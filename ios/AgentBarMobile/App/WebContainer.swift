import AgentBarCore
import SwiftUI
import WebKit

/// Full-screen WKWebView on the PWA. Persistent data store (cookies, service worker, storage).
struct WebContainer: UIViewRepresentable {
    @ObservedObject var shell: WebShellModel

    func makeCoordinator() -> Coordinator { Coordinator(shell: shell) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        let refresh = UIRefreshControl()
        refresh.addTarget(context.coordinator, action: #selector(Coordinator.pulledToRefresh(_:)), for: .valueChanged)
        webView.scrollView.refreshControl = refresh
        context.coordinator.webView = webView
        if shell.target == nil { shell.open() }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.loadIfRequested(shell.loadRequest)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let shell: WebShellModel
        weak var webView: WKWebView?
        private var handledRequest = 0
        /// Last silent sign-in; a second redirect to the login page within this window means
        /// the fresh cookie didn't work, so stop instead of looping.
        private var lastSignIn = Date.distantPast

        init(shell: WebShellModel) { self.shell = shell }

        func loadIfRequested(_ request: Int) {
            guard request != handledRequest, let target = shell.target, let webView else { return }
            handledRequest = request
            lastSignIn = .distantPast  // an explicit open/retry may sign in again
            webView.load(URLRequest(url: target))
        }

        @objc func pulledToRefresh(_ control: UIRefreshControl) {
            control.endRefreshing()
            if shell.phase == .ready, webView?.url != nil { webView?.reload() } else { shell.open() }
        }

        // MARK: Navigation policy

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url, let base = shell.base else { return decisionHandler(.allow) }
            let isMainFrame = action.targetFrame?.isMainFrame ?? true
            let isWeb = ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            if isMainFrame, isWeb, !WebRoutes.isSameOrigin(url, base: base) {
                UIApplication.shared.open(url)  // other origins go to Safari
                return decisionHandler(.cancel)
            }
            if isMainFrame, WebRoutes.isLoginPage(url, base: base), action.request.httpMethod != "POST" {
                decisionHandler(.cancel)
                return signInSilently()
            }
            if !isWeb, !["about", "blob", "data"].contains(url.scheme?.lowercased() ?? "") {
                UIApplication.shared.open(url)  // mailto:, tel:, …
                return decisionHandler(.cancel)
            }
            decisionHandler(.allow)
        }

        /// Session expired or never existed: exchange the Keychain token for a cookie, then reload.
        private func signInSilently() {
            guard Date().timeIntervalSince(lastSignIn) > 10 else { shell.phase = .tokenRejected; return }
            lastSignIn = Date()
            guard let api = AgentBarClient.currentAPI(), let store = webView?.configuration.websiteDataStore.httpCookieStore
            else { shell.phase = .tokenRejected; return }
            RemoteSession.signIn(api: api, into: store) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.webView.map { $0.load(URLRequest(url: self.shell.target ?? api.baseURL)) }
                case .failure(.unreachable(let error)):
                    self.shell.phase = .offline(error.localizedDescription)
                case .failure:
                    self.shell.phase = .tokenRejected
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if case .tokenRejected = shell.phase { return }
            shell.phase = .ready
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            showFailure(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            showFailure(error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.reload() }

        private func showFailure(_ error: Error) {
            let ns = error as NSError
            // Cancelled (our own policy cancels) and WebKit "frame load interrupted" are not outages.
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
            if ns.domain == "WebKitErrorDomain" && ns.code == 102 { return }
            shell.phase = .offline(error.localizedDescription)
        }

        // MARK: UI delegate

        /// target=_blank / window.open: same-origin loads here, others open in Safari.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url, let base = shell.base {
                if WebRoutes.isSameOrigin(url, base: base) { webView.load(action.request) } else { UIApplication.shared.open(url) }
            }
            return nil
        }

        /// Microphone/camera for voice notes: granted only to the configured Mac's origin.
        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            guard let base = shell.base else { return decisionHandler(.deny) }
            let ok = WebRoutes.isSameOrigin(scheme: origin.protocol, host: origin.host, port: origin.port, base: base)
            decisionHandler(ok ? .grant : .deny)
        }

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            present(message, actions: [("OK", .default, completionHandler)], fallback: completionHandler)
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            present(message, actions: [("Cancel", .cancel, { completionHandler(false) }),
                                       ("OK", .default, { completionHandler(true) })],
                    fallback: { completionHandler(false) })
        }

        private func present(_ message: String, actions: [(String, UIAlertAction.Style, () -> Void)],
                             fallback: @escaping () -> Void) {
            guard let presenter = webView?.window?.rootViewController?.topmostPresented else { return fallback() }
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            for (title, style, handler) in actions { alert.addAction(UIAlertAction(title: title, style: style) { _ in handler() }) }
            presenter.present(alert, animated: true)
        }
    }
}

private extension UIViewController {
    var topmostPresented: UIViewController { presentedViewController?.topmostPresented ?? self }
}
