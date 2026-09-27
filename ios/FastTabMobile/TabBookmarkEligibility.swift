import Foundation

/// Decides whether an open tab is read-later / revisit content worth an inline
/// "Bookmark into folder" suggestion. Tools and apps (chat, mail, calendars,
/// workspaces, editors, local dev servers, search/login pages) are skipped —
/// bookmarking those is noise. Pure and synchronous so it can gate the row
/// before any scoring work starts.
enum TabBookmarkEligibility {
    /// Hosts (and any subdomain of them) that are apps, not content.
    static let deniedHosts: Set<String> = [
        "slack.com", "chat.google.com", "mail.google.com", "calendar.google.com",
        "meet.google.com", "docs.google.com", "sheets.google.com", "slides.google.com",
        "drive.google.com", "keep.google.com", "zoom.us", "teams.microsoft.com",
        "teams.live.com", "outlook.live.com", "outlook.office.com", "outlook.office365.com",
        "office.com", "sharepoint.com", "discord.com", "discord.gg", "notion.so",
        "notion.site", "linear.app", "atlassian.net", "figma.com", "miro.com",
        "trello.com", "asana.com", "clickup.com", "monday.com", "airtable.com",
        "web.whatsapp.com", "web.telegram.org", "messenger.com", "chat.zalo.me",
        "claude.ai", "chatgpt.com", "gemini.google.com", "console.cloud.google.com",
        "console.aws.amazon.com", "portal.azure.com", "vercel.com", "app.netlify.com"
    ]

    /// Path fragments that mark search results, auth, and inbox-style pages.
    static let deniedPathFragments: [String] = [
        "/search", "/login", "/signin", "/sign-in", "/signup", "/sign-up",
        "/auth", "/oauth", "/sso", "/logout", "/checkout", "/cart", "/inbox", "/settings"
    ]

    /// Query keys that mean "this is a search result page".
    static let searchQueryKeys: Set<String> = ["q", "query", "search_query", "keyword"]

    static func isReadLaterContent(urlString: String) -> Bool {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let rawHost = url.host()?.lowercased(), !rawHost.isEmpty else { return false }
        let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost

        if isLocalHost(host) { return false }
        if deniedHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return false }

        let path = url.path().lowercased()
        if deniedPathFragments.contains(where: { path.hasPrefix($0) || path.contains($0 + "/") }) { return false }
        // Bare homepages are destinations, not something to read later.
        if path.isEmpty || path == "/" { return false }

        let queryKeys = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.map { $0.name.lowercased() } ?? []
        if queryKeys.contains(where: searchQueryKeys.contains) { return false }
        return true
    }

    private static func isLocalHost(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local")
            || host.hasSuffix(".test") || host.hasSuffix(".internal") { return true }
        // Bare IPv4 / IPv6 literals are dev servers or routers, not articles.
        if host.contains(":") { return true }
        return host.split(separator: ".").allSatisfy { Int($0) != nil }
    }
}
