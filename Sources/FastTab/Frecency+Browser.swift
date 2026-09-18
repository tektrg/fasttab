import CommandBarKit
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

    /// Best-effort profile parse from a Chromium-style window title.
    /// Chrome window titles end with " - <ProfileName>" when multiple profiles
    /// exist. Returns nil when the pattern doesn't match — caller falls back
    /// to the collapsed `(browser, URL)` key.
    static func profileFromWindowTitle(_ windowTitle: String?) -> String? {
        guard let raw = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        guard let range = raw.range(of: " - ", options: .backwards) else { return nil }
        let candidate = raw[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        // Skip suffixes that are obviously not a profile name (e.g. browser
        // app name itself, or a page title fragment with no profile semantics).
        guard !candidate.isEmpty, candidate.count <= 64 else { return nil }
        let lower = candidate.lowercased()
        let appSuffixes: Set<String> = [
            "google chrome",
            "chrome",
            "microsoft edge",
            "edge",
            "brave",
            "arc",
            "safari"
        ]
        if appSuffixes.contains(lower) { return nil }
        return candidate
    }
}
