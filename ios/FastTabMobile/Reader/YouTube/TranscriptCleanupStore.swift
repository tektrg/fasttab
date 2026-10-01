import CryptoKit
import Foundation

/// One video's saved clean-up: per paragraph, the text the Clean view shows (cleaned, or the
/// original kept for good), nil while not done yet.
struct TranscriptCleanupRecord: Codable, Equatable {
    /// Digest of the original paragraphs; a different transcript (new captions, other
    /// language) no longer matches and is cleaned afresh.
    var sourceDigest: String
    var texts: [String?]
    /// `TranscriptCleanup.instructionVersion` it was made with; nil = before versions (1).
    var instructionVersion: Int?
}

/// Saved clean-ups, one JSON file per video in Application Support (not Caches: highlights made
/// in the Clean view anchor to this exact text, so it must not be purged and regenerated).
struct TranscriptCleanupStore: Sendable {
    let directory: URL

    static let shared = TranscriptCleanupStore(directory: URL.applicationSupportDirectory
        .appending(path: "FastTabTranscriptCleanups", directoryHint: .isDirectory))

    /// The saved record for these originals, or nil (none, unreadable, or another transcript).
    func record(videoID: String, originals: [String]) -> TranscriptCleanupRecord? {
        guard let data = try? Data(contentsOf: fileURL(videoID)),
              let record = try? JSONDecoder().decode(TranscriptCleanupRecord.self, from: data),
              record.sourceDigest == Self.digest(originals),
              (record.instructionVersion ?? 1) == TranscriptCleanup.instructionVersion,
              record.texts.count == originals.count else { return nil }
        return record
    }

    func save(_ record: TranscriptCleanupRecord, videoID: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(record).write(to: fileURL(videoID), options: .atomic)
        } catch {
            // Best effort: the next open cleans again.
        }
    }

    static func digest(_ originals: [String]) -> String {
        SHA256.hash(data: Data(originals.joined(separator: "\u{1F}").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private func fileURL(_ videoID: String) -> URL {
        let safe = videoID.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return directory.appending(path: "\(safe.isEmpty ? "video" : safe).json")
    }
}
