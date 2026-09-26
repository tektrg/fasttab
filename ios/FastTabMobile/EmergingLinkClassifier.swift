import Foundation
import OSLog
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Answers "is this a page worth reading, or a tool/workspace shortcut?" for
/// the Emerging feed, using Apple's on-device model when available. Results
/// are cached per link (by its dedupe key) so a page is only ever classified
/// once. When no on-device model is available, every link is treated as
/// eligible — the user's own "Not a read" dismissals do the filtering instead
/// of a hard-coded site list.
@MainActor
public final class EmergingLinkClassifier {
    public static let shared = EmergingLinkClassifier()

    private let logger = Logger(subsystem: "app.theindie.FastTab", category: "EmergingLinkClassifier")
    private static let defaultsKey = "FastTabMobile.emergingLinkClassificationV1"

    /// dedupeKey -> isRead. Persisted so a restart doesn't re-ask the model.
    private var cache: [String: Bool] = [:]
    private var inFlight: Set<String> = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: Bool].self, from: data) {
            cache = decoded
        }
    }

    public static var isModelAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    /// Cached, synchronous read. Returns `nil` when nothing is known yet
    /// (caller should treat that as "eligible" and optionally kick off
    /// `classify(title:url:)` in the background).
    public func cachedIsRead(url: URL) -> Bool? {
        cache[EmergingURLUtils.dedupeKey(url)]
    }

    /// A plain snapshot of the cache, safe to hand to a `nonisolated`
    /// context (e.g. the feed's ranking pass on a detached task).
    public func cacheSnapshot() -> [String: Bool] {
        cache
    }

    /// Classifies a single link and stores the result. Safe to call
    /// repeatedly — it no-ops once cached or while a request is already in
    /// flight for the same link.
    public func classify(title: String, url: URL) async {
        let key = EmergingURLUtils.dedupeKey(url)
        guard cache[key] == nil, !inFlight.contains(key) else { return }
        guard Self.isModelAvailable else { return }
        inFlight.insert(key)
        defer { inFlight.remove(key) }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let host = url.host() ?? ""
            let prompt = """
            A page titled "\(title)" at \(host)\(url.path()). Is this something a \
            person would sit down and READ (an article, blog post, essay, video, \
            forum thread, documentation page) — or is it a TOOL they'd use \
            (a dashboard, spreadsheet, form, workspace, sign-in page, inbox, \
            search results, or admin panel)? Answer with exactly one word: \
            "read" or "tool".
            """
            do {
                let session = LanguageModelSession(model: .default)
                let response = try await session.respond(to: prompt)
                let answer = response.content.lowercased()
                let isRead = answer.contains("read") && !answer.contains("tool")
                cache[key] = isRead
                persist()
            } catch {
                logger.warning("Link classification failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        #endif
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}
