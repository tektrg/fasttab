import Foundation
import GRDB

/// One searchable thing: a List page, a highlight, a highlight's comments, a bookmark, a
/// history visit, or fetched article text.
public struct IndexDocument: Hashable, Sendable {
    public let source: String
    public let id: String
    public let url: String
    public let title: String
    public let body: String
    /// Ranking lift (0 = none): the user's own highlights and comments rank above plain pages.
    public let boost: Double
    /// When the user last touched it (shown, not ranked).
    public let date: Date?

    public init(source: String, id: String, url: String, title: String, body: String, boost: Double = 0, date: Date? = nil) {
        self.source = source
        self.id = id
        self.url = url
        self.title = title
        self.body = body
        self.boost = boost
        self.date = date
    }
}

/// Where index documents come from. `signature` is cheap (file modified-times and sizes);
/// `documents` is the full read, only done when the signature changed.
public struct IndexSource: Sendable {
    public let name: String
    public let signature: @Sendable () -> String
    public let documents: @Sendable () async -> [IndexDocument]

    public init(name: String, signature: @escaping @Sendable () -> String,
                documents: @escaping @Sendable () async -> [IndexDocument]) {
        self.name = name
        self.signature = signature
        self.documents = documents
    }

    /// Modified-time + size of each file, and of every file directly inside each folder.
    public static func fileSignature(_ urls: [URL]) -> String {
        let fm = FileManager.default
        func stamp(_ url: URL) -> String {
            guard let attributes = try? fm.attributesOfItem(atPath: url.path) else { return "\(url.lastPathComponent):-" }
            let date = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            return "\(url.lastPathComponent):\(date):\(size)"
        }
        return urls.map { url in
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return stamp(url) }
            let children = ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            return ([stamp(url)] + children.map(stamp)).joined(separator: ",")
        }.joined(separator: "|")
    }
}

public struct SearchHit: Hashable, Sendable {
    public let source: String
    public let id: String
    public let url: String
    public let title: String
    public let snippet: String
    public let date: Date?
}

/// The connector's search index: SQLite FTS5 (BM25) in its own file, rebuilt per source when
/// that source's files changed. No daemon: freshness is checked on every search.
public final class ReadingIndex: Sendable {
    private let queue: DatabaseQueue
    public let fileURL: URL

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        queue = try DatabaseQueue(path: fileURL.path, configuration: configuration)
        try Self.migrator.migrate(queue)
    }

    public static func fileURL(supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent("ReadingIndex", isDirectory: true).appendingPathComponent("index.sqlite")
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE VIRTUAL TABLE docs USING fts5(
                    source UNINDEXED, doc_id UNINDEXED, url UNINDEXED, title, body,
                    boost UNINDEXED, date UNINDEXED,
                    tokenize = 'unicode61 remove_diacritics 2');
                CREATE TABLE sources (name TEXT PRIMARY KEY, signature TEXT NOT NULL, indexed_at REAL NOT NULL);
                """)
        }
        return migrator
    }

    /// Re-indexes every source whose signature changed. Returns the names re-indexed.
    @discardableResult
    public func refresh(_ sources: [IndexSource]) async throws -> [String] {
        var refreshed: [String] = []
        for source in sources {
            let signature = source.signature()
            let stored = try await queue.read { db in
                try String.fetchOne(db, sql: "SELECT signature FROM sources WHERE name = ?", arguments: [source.name])
            }
            guard stored != signature else { continue }
            let documents = await source.documents()
            try await queue.write { db in
                try db.execute(sql: "DELETE FROM docs WHERE source = ?", arguments: [source.name])
                for doc in documents {
                    try db.execute(
                        sql: "INSERT INTO docs (source, doc_id, url, title, body, boost, date) VALUES (?, ?, ?, ?, ?, ?, ?)",
                        arguments: [doc.source, doc.id, doc.url, doc.title, doc.body, doc.boost, doc.date?.timeIntervalSince1970])
                }
                try db.execute(
                    sql: "INSERT OR REPLACE INTO sources (name, signature, indexed_at) VALUES (?, ?, ?)",
                    arguments: [source.name, signature, Date().timeIntervalSince1970])
            }
            refreshed.append(source.name)
        }
        return refreshed
    }

    /// Deletes the index files (history turned off or its window shortened): FTS5 keeps
    /// deleted terms in its pages until a merge, so the file goes, and the next search rebuilds.
    public static func deleteFiles(supportDirectory: URL) {
        let url = fileURL(supportDirectory: supportDirectory)
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }

    /// Drops a source's rows (history turned off): nothing of it stays searchable.
    public func remove(source name: String) async throws {
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM docs WHERE source = ?", arguments: [name])
            try db.execute(sql: "DELETE FROM sources WHERE name = ?", arguments: [name])
        }
    }

    /// BM25 (title weighted 4×; lower is better) minus each document's boost, added so it still
    /// lifts when a common word gives BM25 almost nothing; every word must match (prefix).
    public func search(_ query: String, sources: Set<String>? = nil, limit: Int = 20) async throws -> [SearchHit] {
        guard let match = Self.matchExpression(query) else { return [] }
        let names = sources.map { Array($0).sorted() }
        return try await queue.read { db in
            var sql = """
                SELECT source, doc_id, url, title, date,
                       snippet(docs, 4, '', '', '…', 16) AS snip,
                       bm25(docs, 0.0, 0.0, 0.0, 4.0, 1.0, 0.0, 0.0) - boost AS score
                FROM docs WHERE docs MATCH ?
                """
            var arguments: StatementArguments = [match]
            if let names {
                guard !names.isEmpty else { return [] }
                sql += " AND source IN (\(names.map { _ in "?" }.joined(separator: ",")))"
                for name in names { arguments += [name] }
            }
            sql += " ORDER BY score, doc_id LIMIT ?"
            arguments += [max(1, limit)]
            return try Row.fetchAll(db, sql: sql, arguments: arguments).map { row in
                SearchHit(source: row["source"], id: row["doc_id"], url: row["url"], title: row["title"],
                          snippet: row["snip"], date: (row["date"] as Double?).map(Date.init(timeIntervalSince1970:)))
            }
        }
    }

    /// Each word as a quoted prefix term, ANDed: user text never reaches FTS5 syntax.
    static func matchExpression(_ query: String) -> String? {
        let terms = query.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "") + "\"*" }
        return terms.isEmpty ? nil : terms.joined(separator: " AND ")
    }
}
