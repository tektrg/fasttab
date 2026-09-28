import Foundation
import FastTabSync

/// Picks one of the user's own synced tabs to demo Reader on.
///
/// Reader suits articles, so a guess that lands on an inbox or a spreadsheet
/// would teach the wrong lesson. The rule is deliberately small and
/// conservative: web page, has a path, not a known app/workspace site. When
/// nothing passes, the guide falls back to the bundled sample article.
enum ReaderTryoutPicker {

    /// Sites that are tools or feeds, not things you sit down and read.
    static let appHosts: Set<String> = [
        "mail.google.com", "docs.google.com", "drive.google.com", "calendar.google.com",
        "meet.google.com", "sheets.google.com", "outlook.live.com", "outlook.office.com",
        "github.com", "gitlab.com", "notion.so", "www.notion.so", "figma.com", "www.figma.com",
        "slack.com", "app.slack.com", "linear.app", "trello.com", "web.whatsapp.com",
        "youtube.com", "www.youtube.com", "m.youtube.com", "x.com", "twitter.com",
        "facebook.com", "www.facebook.com", "instagram.com", "www.instagram.com",
        "chatgpt.com", "claude.ai", "localhost",
    ]

    /// Subdomains that almost always mean a web app ("app.example.com", "mail.example.com").
    static let appHostPrefixes = ["app.", "mail.", "docs.", "calendar.", "drive.", "dashboard.", "admin.", "console."]

    static func looksLikeArticle(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        guard let host = url.host()?.lowercased(), host.contains(".") else { return false }
        guard !appHosts.contains(host), !appHostPrefixes.contains(where: host.hasPrefix) else { return false }
        let pathSegments = url.path().split(separator: "/")
        return !pathSegments.isEmpty
    }

    /// Slug-style last path segment ("/blog/why-tabs-pile-up") is the strongest
    /// article signal, so those win over any other qualifying tab.
    static func pick(from tabs: [SyncedTab]) -> SyncedTab? {
        let candidates = tabs.filter { tab in
            guard !tab.title.isEmpty, let url = URL(string: tab.url) else { return false }
            return looksLikeArticle(url)
        }
        return candidates.first(where: hasSlugPath) ?? candidates.first
    }

    private static func hasSlugPath(_ tab: SyncedTab) -> Bool {
        guard let last = URL(string: tab.url)?.path().split(separator: "/").last else { return false }
        return last.contains("-")
    }
}
