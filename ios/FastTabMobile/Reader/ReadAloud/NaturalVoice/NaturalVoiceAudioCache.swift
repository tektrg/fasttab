import CryptoKit
import Foundation

/// On-device cache of natural-voice MP3s, so replaying a sentence never calls the server.
/// Least-recently-used eviction: a hit refreshes the file's modification date, and each
/// write trims the oldest files until the folder is back under `capacityBytes`.
final class NaturalVoiceAudioCache: @unchecked Sendable {
    static let defaultCapacityBytes = 100 * 1024 * 1024
    /// Bump when the server's audio for the same request changes (voice model, format).
    static let engineVersion = "google-tts-v1"

    private let directory: URL
    private let capacityBytes: Int
    private let fileManager = FileManager.default
    private let lock = NSLock()

    init(directory: URL? = nil, capacityBytes: Int = defaultCapacityBytes) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NaturalVoice", isDirectory: true)
        self.capacityBytes = capacityBytes
        try? fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    static func key(for request: NaturalVoiceRequest) -> String {
        let material = [
            request.text, request.languageCode, request.voice ?? "",
            String(format: "%.2f", request.speakingRate), engineVersion,
        ].joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func audio(forKey key: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        let url = fileURL(key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return data
    }

    func store(_ audio: Data, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        try? audio.write(to: fileURL(key), options: .atomic)
        evictOverCapacity()
    }

    private func fileURL(_ key: String) -> URL { directory.appendingPathComponent(key + ".mp3") }

    private func evictOverCapacity() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let files = ((try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? [])
            .compactMap { url -> (url: URL, lastUsed: Date, bytes: Int)? in
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
                return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
            }
            .sorted { $0.lastUsed < $1.lastUsed }
        var totalBytes = files.reduce(0) { $0 + $1.bytes }
        for file in files where totalBytes > capacityBytes {
            try? fileManager.removeItem(at: file.url)
            totalBytes -= file.bytes
        }
    }
}
