import Foundation

/// Site identity used to decide whether a URL belongs to an installed web
/// app: scheme + host + port, deliberately ignoring path. Two apps that
/// happen to share a host (e.g. `docs.google.com`) are disambiguated by path
/// only where they actually collide — see `matchInstalledWebApp`.
struct WebAppRouteKey: Hashable {
    let scheme: String
    let host: String
    let port: Int
}

private func defaultPort(forScheme scheme: String) -> Int {
    scheme == "https" ? 443 : 80
}

func webAppRouteKey(for urlString: String) -> WebAppRouteKey? {
    guard let components = URLComponents(string: urlString),
          let scheme = components.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          let host = components.host?.lowercased() else {
        return nil
    }
    let port = components.port ?? defaultPort(forScheme: scheme)
    return WebAppRouteKey(scheme: scheme, host: host, port: port)
}

/// Stable string form of `webAppRouteKey(for:)`, used as the persistence key
/// in `WebAppRoutingStore` (a plain struct can't be a `Codable` dictionary key
/// without extra ceremony; a canonical string is simpler and human-readable
/// in the stored defaults).
func webAppRouteKeyString(for urlString: String) -> String? {
    guard let key = webAppRouteKey(for: urlString) else { return nil }
    return "\(key.scheme)://\(key.host):\(key.port)"
}

private func firstPathSegment(of urlString: String) -> String? {
    guard let components = URLComponents(string: urlString) else { return nil }
    return components.path.split(separator: "/").first.map(String.init)
}

/// Picks the one candidate matching `targetURL`'s first path segment, when
/// more than one candidate shares the same route key (e.g. three installed
/// apps all on `docs.google.com`, or two of that app's own windows open at
/// once). Ambiguous input returns nil rather than guessing — used both to
/// resolve which installed app a clicked link belongs to, and which of that
/// app's currently-open windows to steer.
private func disambiguateByPathSegment<Candidate>(
    among candidates: [Candidate],
    matching targetURL: String,
    urlOf: (Candidate) -> String
) -> Candidate? {
    guard candidates.count > 1 else { return candidates.first }
    guard let targetSegment = firstPathSegment(of: targetURL) else { return nil }
    let bySegment = candidates.filter { firstPathSegment(of: urlOf($0)) == targetSegment }
    return bySegment.count == 1 ? bySegment.first : nil
}

/// Matches a history/bookmark URL clicked from `browserName` against the
/// installed web apps that share its site identity and owning browser
/// (cross-browser routing is out of scope — an app can only be reached from
/// the browser that owns it).
///
/// Most sites resolve to at most one installed app. When several installed
/// apps share a host (three Google apps all on `docs.google.com`), the first
/// path segment breaks the tie; if that's still ambiguous, returns nil rather
/// than guessing — the caller falls back to opening a normal tab.
func matchInstalledWebApp(
    url: String,
    browserName: String,
    in apps: [InstalledWebApp]
) -> InstalledWebApp? {
    guard let targetKey = webAppRouteKey(for: url) else { return nil }

    let sameSite = apps.filter { app in
        app.browserAppName == browserName && webAppRouteKey(for: app.homeURL) == targetKey
    }

    return disambiguateByPathSegment(among: sameSite, matching: url, urlOf: \.homeURL)
}

/// Picks which of `app`'s currently-open fingerprinted windows to steer, when
/// more than one shares `app`'s route key (e.g. a Docs window and a Sheets
/// window both open at once, both on `docs.google.com`). Mirrors
/// `matchInstalledWebApp`'s tie-break so live window selection is never less
/// precise than the catalog match that chose `app` in the first place.
func selectWindow<Window>(
    for app: InstalledWebApp,
    among windows: [Window],
    urlOf: (Window) -> String
) -> Window? {
    guard let targetKey = webAppRouteKey(for: app.homeURL) else { return nil }
    let sameSite = windows.filter { webAppRouteKey(for: urlOf($0)) == targetKey }
    return disambiguateByPathSegment(among: sameSite, matching: app.homeURL, urlOf: urlOf)
}
