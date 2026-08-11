import AppKit

/// The "open history link in its installed web app" behavioral fork —
/// see `BrowserTabService.activate`'s `.bookmark, .history` case.
extension BrowserTabService {
    /// Routes a bookmark/history open through an installed web app when the
    /// site has one, the click's browser owns it, and the user has enabled
    /// routing for that site. Otherwise (no match, declined, or not yet
    /// asked) opens a normal tab exactly as before — the first click on an
    /// unanswered site is never blocked on the one-time prompt below.
    func openViaWebAppRoutingOrNormally(_ result: BrowserSearchResult) {
        guard let backend = backend(for: result) else { return }

        guard let routeKey = webAppRouteKeyString(for: result.url),
              let match = matchInstalledWebApp(
                  url: result.url,
                  browserName: result.browserName,
                  in: InstalledWebAppCatalog.shared.apps
              ) else {
            Task.detached(priority: .userInitiated) { backend.openURL(result) }
            return
        }

        switch WebAppRoutingStore.shared.decision(for: routeKey) {
        case .enabled:
            Task.detached(priority: .userInitiated) { backend.openInInstalledWebApp(result, app: match) }
        case .declined:
            Task.detached(priority: .userInitiated) { backend.openURL(result) }
        case nil:
            presentWebAppRoutingPrompt(routeKey: routeKey, app: match, result: result, backend: backend)
        }
    }

    /// Asks once, after a short delay so it doesn't compete with the command
    /// bar's own dismiss animation. The site is never asked about again
    /// regardless of the answer — "Not Now" persists as a decline. The link
    /// itself doesn't open until the user answers, so the very click that
    /// triggered the prompt honors the answer instead of always landing as a
    /// normal tab.
    private func presentWebAppRoutingPrompt(
        routeKey: String,
        app: InstalledWebApp,
        result: BrowserSearchResult,
        backend: any BrowserBackend
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let alert = NSAlert()
            alert.messageText = "Always open \(app.name) as an app?"
            alert.informativeText = "FastTab can reuse \(app.name)'s installed app window for links on this site, instead of a new browser tab."
            alert.addButton(withTitle: "Always Open as App")
            alert.addButton(withTitle: "Not Now")
            NSApp.activate(ignoringOtherApps: true)
            let response = alert.runModal()
            let enabled = response == .alertFirstButtonReturn
            WebAppRoutingStore.shared.setDecision(enabled ? .enabled : .declined, for: routeKey)
            Task.detached(priority: .userInitiated) {
                if enabled {
                    backend.openInInstalledWebApp(result, app: app)
                } else {
                    backend.openURL(result)
                }
            }
        }
    }
}
