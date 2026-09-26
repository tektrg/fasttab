import Foundation

/// Shared URL cleanup for the Emerging feed: strips tracking noise so the same
/// page visited with different query strings (or via a shortener/redirect
/// fragment) collapses to one card instead of many near-duplicates.
enum EmergingURLUtils {
    /// Query keys that never change what page you're looking at.
    private static let trackingParamPrefixes = ["utm_", "fbclid", "gclid", "gclsrc", "mc_", "ref_"]
    private static let trackingParamNames: Set<String> = [
        "ref", "referrer", "source", "si", "spm", "igshid", "mkt_tok", "_hsenc", "_hsmi"
    ]

    /// Collapses a URL to a stable identity for dedupe: lowercased host + path,
    /// with tracking query params dropped and the fragment discarded. Query
    /// params that actually identify content (e.g. YouTube `v=`) are kept.
    static func dedupeKey(_ url: URL) -> String {
        let host = (url.host() ?? "").lowercased()
        var path = url.path()
        if path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        path = path.lowercased()

        let keptParams = keptQueryItems(for: url)
        if keptParams.isEmpty {
            return "\(host)\(path)"
        }
        let sortedQuery = keptParams
            .sorted { $0.name < $1.name }
            .map { "\($0.name)=\($0.value ?? "")" }
            .joined(separator: "&")
        return "\(host)\(path)?\(sortedQuery)"
    }

    private static func keptQueryItems(for url: URL) -> [URLQueryItem] {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else { return [] }
        return items.filter { item in
            let name = item.name.lowercased()
            if trackingParamNames.contains(name) { return false }
            if trackingParamPrefixes.contains(where: { name.hasPrefix($0) }) { return false }
            // Drop obvious session/random-looking ids: long hex/alnum blobs with no
            // semantic name.
            if name == "id" || name == "session" || name == "sid" || name == "token" {
                return false
            }
            return true
        }
    }
}
