import FastTabSync
import Foundation
import IndieSharing

/// Uploads a built snapshot: changed article bodies first (by `contentHash`), removed ones
/// deleted, then the snapshot itself under a new, strictly higher version.
/// The ledger (last version + uploaded article hashes) lives in one JSON file.
@MainActor
public final class WebSnapshotUploader {
    struct Ledger: Codable, Equatable {
        var version: Int = 0
        var articleHashes: [String: String] = [:]
    }

    private let api: any WebReaderAPI
    private let ledgerURL: URL
    private let now: () -> Date
    private(set) var ledger: Ledger

    public init(api: any WebReaderAPI, ledgerURL: URL, now: @escaping () -> Date = Date.init) {
        self.api = api
        self.ledgerURL = ledgerURL
        self.now = now
        ledger = (try? JSONDecoder().decode(Ledger.self, from: Data(contentsOf: ledgerURL))) ?? Ledger()
    }

    public var lastVersion: Int { ledger.version }

    public struct Result: Equatable, Sendable {
        public var version: Int
        public var articlesUploaded: Int
        public var articlesDeleted: Int
    }

    /// Recipients = the user's paired browsers. None paired: nothing to encrypt for, no upload.
    @discardableResult
    public func upload(_ build: WebSnapshotBuild, to recipients: [WebReaderCrypto.Recipient]) async throws -> Result? {
        guard !recipients.isEmpty else { return nil }
        var uploaded = 0
        var deleted = 0
        for article in build.snapshot.articles where ledger.articleHashes[article.id] != article.contentHash {
            guard let body = build.articleBodies[article.id] else { continue }
            let blob = try WebReaderCrypto.seal(body, kind: .article(id: article.id), for: recipients)
            try await api.putArticle(id: article.id, blob: blob)
            ledger.articleHashes[article.id] = article.contentHash
            uploaded += 1
            save()
        }
        let kept = Set(build.snapshot.articles.map(\.id))
        for id in ledger.articleHashes.keys.sorted() where !kept.contains(id) {
            try await api.deleteArticle(id: id)
            ledger.articleHashes.removeValue(forKey: id)
            deleted += 1
            save()
        }
        let version = max(ledger.version + 1, Int(now().timeIntervalSince1970 * 1000))
        let plaintext = try WebReaderJSON.encoder.encode(build.snapshot)
        let blob = try WebReaderCrypto.seal(plaintext, kind: .snapshot, for: recipients)
        try await api.putSnapshot(version: version, blob: blob)
        ledger.version = version
        save()
        return Result(version: version, articlesUploaded: uploaded, articlesDeleted: deleted)
    }

    /// The paired-browser set changed: every article must be re-wrapped for the new set.
    public func forgetUploadedArticles() {
        ledger.articleHashes.removeAll()
        save()
    }

    /// After `DELETE /v1/snapshots/fasttab` (toggle off). Keeps the version so it only goes up.
    public func reset() {
        ledger.articleHashes.removeAll()
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: ledgerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(ledger).write(to: ledgerURL, options: .atomic)
    }
}

/// Where imported web highlights and progress land (the app: `ReaderMirror` + FastTab List).
@MainActor
public protocol WebInboxSink: AnyObject {
    /// False when it could not be stored (the item is then not acked and comes back).
    func importHighlight(_ highlight: SyncedReaderHighlight) -> Bool
    /// Keep the newest by `updatedAt`.
    func applyProgress(url: String, fraction: Double, updatedAt: Date)
}

/// Pulls the browser's highlights/progress inbox, opens each item with this Mac's device key,
/// hands it to the sink, then acks so the server deletes it.
@MainActor
public enum WebInboxImporter {
    public struct Summary: Equatable, Sendable {
        public var highlights = 0
        public var progress = 0
        /// Unreadable or unknown items: acked too, so one bad item never blocks the inbox.
        public var skipped = 0
    }

    public static func run(api: any WebReaderAPI, deviceID: String, keyPair: DeviceKeyPair,
                           sink: any WebInboxSink, maxPages: Int = 20) async throws -> Summary {
        var summary = Summary()
        var cursor: String?
        for _ in 0..<maxPages {
            let page = try await api.pendingInbox(after: cursor)
            var acks: [String] = []
            for item in page.items {
                switch open(item, deviceID: deviceID, keyPair: keyPair) {
                case .highlight(let highlight):
                    guard let synced = syncedHighlight(id: item.id, from: highlight) else {
                        summary.skipped += 1; acks.append(item.id); continue
                    }
                    guard sink.importHighlight(synced) else { continue }
                    summary.highlights += 1
                case .progress(let progress):
                    let fraction = min(1, max(0, progress.fraction))
                    sink.applyProgress(url: progress.url, fraction: fraction,
                                       updatedAt: WebReaderJSON.date(progress.updatedAt) ?? Date())
                    summary.progress += 1
                case .unreadable:
                    summary.skipped += 1
                }
                acks.append(item.id)
            }
            try await api.ackInbox(ids: acks)
            guard let next = page.cursor, !page.items.isEmpty else { break }
            cursor = next
        }
        return summary
    }

    enum Opened: Equatable {
        case highlight(WebHighlight)
        case progress(WebProgress)
        case unreadable
    }

    static func open(_ item: WebInboxItem, deviceID: String, keyPair: DeviceKeyPair) -> Opened {
        guard let ciphertext = try? Base64URL.decode(item.ciphertext),
              let plaintext = try? WebReaderCrypto.open(
                WebSealedBlob(suite: item.suite, wraps: item.wraps, ciphertext: ciphertext),
                kind: .highlight(id: item.id), deviceID: deviceID, keyPair: keyPair)
        else { return .unreadable }
        struct Schema: Decodable { let schema: String }
        switch (try? JSONDecoder().decode(Schema.self, from: plaintext))?.schema {
        case WebHighlight.schemaID:
            return (try? JSONDecoder().decode(WebHighlight.self, from: plaintext)).map(Opened.highlight) ?? .unreadable
        case WebProgress.schemaID:
            return (try? JSONDecoder().decode(WebProgress.self, from: plaintext)).map(Opened.progress) ?? .unreadable
        default:
            return .unreadable
        }
    }

    /// The phone's `ReaderHighlight` JSON (same keys and encoder), so it syncs to the iPhone
    /// like any highlight. `serializedRange` carries the quote and its context (no offsets:
    /// the phone re-anchors by text). The web note is not carried in v1.
    static func syncedHighlight(id: String, from web: WebHighlight) -> SyncedReaderHighlight? {
        guard let url = URL(string: web.url), !web.quote.isEmpty else { return nil }
        struct Range: Encodable { let text: String; let cb: String; let ca: String }
        struct Payload: Encodable {
            let id: String, urlKey: String, selectedText: String, color: String, serializedRange: String
            let createdAt: Date, urlString: String, tags: [String]
        }
        let colors: Set<String> = ["yellow", "green", "blue", "pink"]
        guard let rangeData = try? WebReaderJSON.encoder.encode(Range(text: web.quote, cb: web.prefix, ca: web.suffix))
        else { return nil }
        let urlKey = url.readerCanonicalKey
        let payload = Payload(
            id: id, urlKey: urlKey, selectedText: web.quote,
            color: colors.contains(web.color) ? web.color : "yellow",
            serializedRange: String(decoding: rangeData, as: UTF8.self),
            createdAt: WebReaderJSON.date(web.createdAt) ?? Date(),
            urlString: web.url, tags: [])
        guard let data = try? ReaderSyncBridge.encoder.encode(payload) else { return nil }
        return SyncedReaderHighlight(id: id, urlKey: urlKey, payload: data)
    }
}
