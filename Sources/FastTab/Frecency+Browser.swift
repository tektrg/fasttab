import IndieCommandBar
import Foundation

/// Browser-specific keying on top of the kit's frecency scoring: entries are
/// keyed per `(browser, profile, normalizedURL)`.
extension Frecency {
    /// Normalize a URL for stable identity across navigations and minor variants.
    /// - lowercase scheme + host
    /// - keep path (sans trailing slash, except root `/`)
    /// - strip query and fragment
    /// Returns the original string if URL parsing fails.
    static func normalizeURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let comps = URLComponents(string: trimmed),
              let scheme = comps.scheme?.lowercased(),
              !scheme.isEmpty else {
            return trimmed
        }
        let host = (comps.host ?? "").lowercased()
        var path = comps.path
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if host.isEmpty, path.isEmpty {
            return trimmed
        }
        var authority = host
        if let port = comps.port, port != 80, port != 443 {
            authority += ":\(port)"
        }
        return "\(scheme)://\(authority)\(path)"
    }

    /// `browser|profile|normalizedURL`. When profile is nil/empty, collapses
    /// to a sentinel `*` so unknown-profile entries share a bucket per
    /// (browser, URL) but stay separate from known-profile entries.
    static func key(browser: String, profile: String?, url: String) -> String {
        let prof: String = {
            if let p = profile?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
                return p
            }
            return "*"
        }()
        return "\(browser)|\(prof)|\(normalizeURL(url))"
    }
}
