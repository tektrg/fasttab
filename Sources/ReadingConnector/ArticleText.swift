import CryptoKit
import FastTabSync
import Foundation

/// Gets a page's bytes. The real one is `URLSession`; tests pass fixtures. The only network
/// the connector ever uses, and only when an agent asks for `fetch_text`.
public protocol PageFetching: Sendable {
    func fetch(_ url: URL) async throws -> (data: Data, status: Int, contentType: String?)
}

public struct URLSessionPageFetcher: PageFetching {
    public static let maxBytes = 5 * 1_024 * 1_024

    public struct Refused: Error, LocalizedError {
        public let errorDescription: String?
    }

    /// One ephemeral session (no cookies, no cache) for every fetch; redirects are checked.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration, delegate: RedirectGuard(), delegateQueue: nil)
    }()

    public init() {}

    public func fetch(_ url: URL) async throws -> (data: Data, status: Int, contentType: String?) {
        guard PublicHost.isPublic(url) else {
            throw Refused(errorDescription: "only public web pages are fetched, not local or private network addresses")
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) "
                         + "Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await Self.session.bytes(for: request)
        let http = response as? HTTPURLResponse
        if let final = response.url, !PublicHost.isPublic(final) {
            throw Refused(errorDescription: "the page redirected to a local or private network address")
        }
        // Stop reading at the cap: a huge or endless body never fills memory.
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= Self.maxBytes { break }
        }
        return (data, http?.statusCode ?? 200, http?.value(forHTTPHeaderField: "Content-Type"))
    }

    /// Refuses a redirect to a non-public host or from https down to http.
    final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            guard let target = request.url, PublicHost.isPublic(target) else { return nil }
            if response.url?.scheme?.lowercased() == "https", target.scheme?.lowercased() != "https" { return nil }
            return request
        }
    }
}

/// Whether a URL points at the public internet: http(s), and every address its host resolves
/// to is outside loopback, private, link-local, CGNAT, multicast and unique-local ranges
/// (no `localhost`, `.local`, `192.168.x.x`, `169.254.x.x`, `::1`, `fc00::/7`, ...).
public enum PublicHost {
    public static func isPublic(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host()?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")), !host.isEmpty else {
            return false
        }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".internal")
            || !host.contains(".") && !host.contains(":") {
            return false
        }
        let addresses = resolve(host)
        return !addresses.isEmpty && addresses.allSatisfy(isPublicAddress)
    }

    /// Numeric addresses for `host` (IPv4 as 4 bytes, IPv6 as 16).
    static func resolve(_ host: String) -> [[UInt8]] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return [] }
        defer { freeaddrinfo(first) }
        var out: [[UInt8]] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            if info.pointee.ai_family == AF_INET, let address = info.pointee.ai_addr {
                address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { v4 in
                    out.append(withUnsafeBytes(of: v4.pointee.sin_addr.s_addr) { Array($0) })
                }
            } else if info.pointee.ai_family == AF_INET6, let address = info.pointee.ai_addr {
                address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { v6 in
                    out.append(withUnsafeBytes(of: v6.pointee.sin6_addr) { Array($0) })
                }
            }
            cursor = info.pointee.ai_next
        }
        return out
    }

    static func isPublicAddress(_ bytes: [UInt8]) -> Bool {
        if bytes.count == 4 {
            let (a, b) = (bytes[0], bytes[1])
            return !(a == 0 || a == 10 || a == 127 || a >= 224
                || (a == 169 && b == 254) || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168)
                || (a == 100 && (64...127).contains(b)) || (a == 192 && b == 0 && bytes[2] == 0)
                || (a == 198 && (18...19).contains(b)))
        }
        guard bytes.count == 16 else { return false }
        if bytes.allSatisfy({ $0 == 0 }) || bytes[0..<15].allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return false }  // :: and ::1
        if bytes[0] & 0xFE == 0xFC { return false }                 // fc00::/7 unique local
        if bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80 { return false }  // fe80::/10 link local
        if bytes[0] == 0xFF { return false }                        // multicast
        // IPv4-mapped (::ffff:a.b.c.d): judge the IPv4 address.
        if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xFF && bytes[11] == 0xFF {
            return isPublicAddress(Array(bytes[12..<16]))
        }
        return true
    }
}

/// A page's readable text as fetched on demand, kept in the text cache.
public struct FetchedText: Codable, Hashable, Sendable {
    public let url: String
    public let title: String?
    public let text: String
    public let fetchedAt: Date

    /// The first ~2 sentences (context_pack's summary line).
    public var lead: String {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sentence, _, _, stop in
            if let sentence = sentence?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty {
                sentences.append(sentence)
            }
            if sentences.count == 2 { stop = true }
        }
        let lead = sentences.joined(separator: " ")
        return lead.count > 400 ? String(lead.prefix(399)) + "…" : lead
    }
}

/// Fetching, cleaning and caching page text. Pages are only ever fetched when asked
/// (`article(url, fetch_text: true)`); only fetched pages enter search (`text` source).
/// The cache is capped (default 200 MB), least recently used first out.
public struct ArticleTextStore: Sendable {
    public enum Outcome: Sendable, Equatable {
        case text(FetchedText)
        /// Paywall, login wall, not HTML, too short, or the fetch failed: metadata only.
        case unavailable(reason: String)
    }

    public static let defaultCacheLimit = 200 * 1_024 * 1_024
    /// Less readable text than this is a wall, not an article.
    static let minimumCharacters = 400

    public let directory: URL
    public let cacheLimit: Int
    public let fetcher: PageFetching
    public let now: @Sendable () -> Date

    public init(directory: URL, cacheLimit: Int = ArticleTextStore.defaultCacheLimit,
                fetcher: PageFetching = URLSessionPageFetcher(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.cacheLimit = cacheLimit
        self.fetcher = fetcher
        self.now = now
    }

    public static func directory(supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent("ReadingIndex/text", isDirectory: true)
    }

    /// Fetches the page now (never served from the cache: the agent asked for it), caches it.
    public func fetch(_ urlString: String) async -> Outcome {
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            return .unavailable(reason: "not a web page URL")
        }
        let response: (data: Data, status: Int, contentType: String?)
        do { response = try await fetcher.fetch(url) } catch {
            return .unavailable(reason: "could not load the page (\(error.localizedDescription))")
        }
        if [401, 402, 403, 407, 429, 451].contains(response.status) {
            return .unavailable(reason: "the site refused (HTTP \(response.status); likely a login or paywall)")
        }
        guard (200..<400).contains(response.status) else { return .unavailable(reason: "HTTP \(response.status)") }
        if let type = response.contentType?.lowercased(), !type.contains("html"), !type.contains("text/plain") {
            return .unavailable(reason: "not a web page (\(type))")
        }
        let html = String(decoding: response.data, as: UTF8.self)
        let extracted = HTMLText.extract(html)
        guard extracted.text.count >= Self.minimumCharacters, !HTMLText.looksLikeWall(extracted.text) else {
            return .unavailable(reason: "no readable article text (likely a login or paywall)")
        }
        let fetched = FetchedText(url: urlString, title: extracted.title, text: extracted.text, fetchedAt: now())
        save(fetched)
        return .text(fetched)
    }

    public func cached(_ urlString: String) -> FetchedText? {
        let file = fileURL(for: urlString)
        guard let data = try? Data(contentsOf: file), let text = try? JSONDecoder().decode(FetchedText.self, from: data) else {
            return nil
        }
        return text
    }

    public func all() -> [FetchedText] {
        files().compactMap { try? JSONDecoder().decode(FetchedText.self, from: Data(contentsOf: $0.url)) }
    }

    /// Cache file per canonical URL.
    func fileURL(for urlString: String) -> URL {
        let key = URL(string: urlString)?.readerCanonicalKey ?? urlString
        let name = SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".json")
    }

    private func save(_ fetched: FetchedText) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(fetched).write(to: fileURL(for: fetched.url), options: .atomic)
            evict()
        } catch {
            // A cache miss next time only means a re-fetch.
        }
    }

    private func files() -> [(url: URL, date: Date, size: Int)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        return ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? [])
            .filter { $0.pathExtension == "json" }
            .map { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return (url, values?.contentModificationDate ?? .distantPast, values?.fileSize ?? 0)
            }
    }

    /// Oldest written first out until the cache fits (a re-fetch refreshes a page's date).
    func evict() {
        var entries = files().sorted { $0.date < $1.date }
        var total = entries.reduce(0) { $0 + $1.size }
        while total > cacheLimit, entries.count > 1 {
            let oldest = entries.removeFirst()
            try? FileManager.default.removeItem(at: oldest.url)
            total -= oldest.size
        }
    }

    /// Fetched pages as a search source.
    public var indexSource: IndexSource {
        let store = self
        return IndexSource(
            name: "text",
            signature: { IndexSource.fileSignature([store.directory]) },
            documents: {
                store.all().map { page in
                    IndexDocument(source: "text", id: page.url, url: page.url, title: page.title ?? page.url,
                                  body: page.text, boost: 0, date: page.fetchedAt)
                }
            })
    }

    /// Page text for an agent, fenced as data. The closing marker can't appear inside.
    public static func wrapped(_ text: String, url: String, limit: Int) -> String {
        var body = text.count > limit ? String(text.prefix(limit)) + "\n[… truncated at \(limit) characters]" : text
        body = body.replacingOccurrences(of: "</untrusted_page_text", with: "<\\/untrusted_page_text", options: .caseInsensitive)
            .replacingOccurrences(of: "<untrusted_page_text", with: "<\\untrusted_page_text", options: .caseInsensitive)
        let safeURL = url.replacingOccurrences(of: "\"", with: "%22").replacingOccurrences(of: ">", with: "%3E")
        return "<untrusted_page_text url=\"\(safeURL)\">\n\(body)\n</untrusted_page_text>"
    }
}

/// Plain readable text from HTML, without a browser: scripts, styles and page chrome dropped,
/// the `<article>` (else `<main>`, else `<body>`) kept, block tags become line breaks.
enum HTMLText {
    static func extract(_ html: String) -> (title: String?, text: String) {
        var source = html
        for tag in ["script", "style", "noscript", "svg", "template", "iframe", "nav", "header", "footer", "aside", "form"] {
            source = source.replacingOccurrences(
                of: "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)\\s*>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        source = source.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: " ", options: .regularExpression)
        let title = firstMatch(#"<title\b[^>]*>([\s\S]*?)</title\s*>"#, in: html).map { clean(decode(stripTags($0))) }
        let region = firstMatch(#"<article\b[^>]*>([\s\S]*)</article\s*>"#, in: source)
            ?? firstMatch(#"<main\b[^>]*>([\s\S]*)</main\s*>"#, in: source)
            ?? firstMatch(#"<body\b[^>]*>([\s\S]*)</body\s*>"#, in: source)
            ?? source
        let blocks = region.replacingOccurrences(
            of: #"</?(p|div|br|li|h[1-6]|blockquote|pre|tr|section|ul|ol|table|figure|figcaption)\b[^>]*>"#,
            with: "\n", options: [.regularExpression, .caseInsensitive])
        let lines = decode(stripTags(blocks)).components(separatedBy: .newlines).map(clean).filter { !$0.isEmpty }
        return (title?.isEmpty == false ? title : nil, lines.joined(separator: "\n"))
    }

    static func looksLikeWall(_ text: String) -> Bool {
        guard text.count < 2_500 else { return false }
        let lower = text.lowercased()
        return ["subscribe to continue", "subscribe to read", "sign in to continue", "log in to continue",
                "create a free account to continue", "this content is for subscribers", "already a subscriber"]
            .contains { lower.contains($0) }
    }

    static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    static func stripTags(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    }

    static func clean(_ line: String) -> String {
        line.replacingOccurrences(of: "[ \\t\\u{00A0}]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func decode(_ text: String) -> String {
        var out = text
        for (entity, value) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'",
                                "&apos;": "'", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…", "&rsquo;": "’",
                                "&lsquo;": "‘", "&rdquo;": "”", "&ldquo;": "“"] {
            out = out.replacingOccurrences(of: entity, with: value)
        }
        guard let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") else { return out }
        var result = ""
        var last = out.startIndex
        for match in regex.matches(in: out, range: NSRange(out.startIndex..., in: out)) {
            guard let range = Range(match.range, in: out), let hexRange = Range(match.range(at: 1), in: out),
                  let numberRange = Range(match.range(at: 2), in: out) else { continue }
            result += out[last..<range.lowerBound]
            let radix = out[hexRange].isEmpty ? 10 : 16
            if let code = UInt32(out[numberRange], radix: radix), let scalar = Unicode.Scalar(code) {
                result.unicodeScalars.append(scalar)
            }
            last = range.upperBound
        }
        return result + out[last...]
    }
}
