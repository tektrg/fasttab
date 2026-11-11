import CryptoKit
import Foundation
import os

let readerSummaryLog = Logger(subsystem: "app.theindie.FastTabMobile", category: "ReaderSummary")

/// One saved summary. Valid only for the exact text and prompt it was made from.
struct ReaderSummaryRecord: Codable, Equatable {
    var textDigest: String
    /// Hash of the person's custom instruction; "" = the server's default prompt.
    var instructionHash: String
    var summary: String
    var model: String
    var createdAt: Date
    /// Server's default-prompt version when made (informational; a newer default never invalidates it).
    var defaultInstructionVersion: Int?
    /// The server said the summary hit its length limit; shown with a note. nil on older records.
    var truncated: Bool?
}

/// Saved summaries, one JSON file per article in Application Support (not Caches: a summary costs
/// money, so the system must not purge it). Reopening never pays twice.
struct ReaderSummaryStore: Sendable {
    let directory: URL

    static let shared = ReaderSummaryStore(directory: URL.applicationSupportDirectory
        .appending(path: "FastTabReaderSummaries", directoryHint: .isDirectory))

    /// The saved summary for this article text and prompt, or nil (none, unreadable, or the page changed).
    func record(urlKey: String, textDigest: String, instructionHash: String) -> ReaderSummaryRecord? {
        guard let record = anyRecord(urlKey: urlKey, textDigest: textDigest),
              record.instructionHash == instructionHash else { return nil }
        return record
    }

    /// The saved summary for this article text made with ANY prompt (an edited prompt keeps showing
    /// the old summary, marked, until the person asks for a new one).
    func anyRecord(urlKey: String, textDigest: String) -> ReaderSummaryRecord? {
        guard let data = try? Data(contentsOf: fileURL(urlKey)),
              let record = try? JSONDecoder().decode(ReaderSummaryRecord.self, from: data),
              record.textDigest == textDigest else { return nil }
        return record
    }

    func save(_ record: ReaderSummaryRecord, urlKey: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(record).write(to: fileURL(urlKey), options: .atomic)
        } catch {
            // Best effort: the next open asks again.
        }
    }

    static func digest(_ text: String) -> String { hash(text) }

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func fileURL(_ urlKey: String) -> URL {
        directory.appending(path: "\(Self.hash(urlKey)).json")
    }
}
