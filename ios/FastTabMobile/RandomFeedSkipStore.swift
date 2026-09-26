import Foundation
import OSLog

/// Which links the Shuffle tab has swiped past today.
///
/// Deliberately resets every calendar day and is never synced to the Mac: a
/// skip only means "not interested right now," not "remove this bookmark," so
/// it has no business travelling further than this phone.
private struct RandomFeedSkipRecord: Codable {
    var day: String
    var skippedIDs: Set<String>
}

@MainActor
public final class RandomFeedSkipStore: ObservableObject {
    public static let shared = RandomFeedSkipStore()

    @Published private var skippedIDs: Set<String> = []

    private let logger = Logger(subsystem: "app.theindie.FastTab", category: "RandomFeedSkipStore")
    private let fileURL: URL

    private static let fileName = "random_feed_skips.json"

    public init(customFileURL: URL? = nil) {
        self.fileURL = customFileURL ?? AppGroupContainer.fileURL(forFileNamed: Self.fileName)
        loadFromDisk()
    }

    public func isSkipped(_ id: String) -> Bool {
        skippedIDs.contains(id)
    }

    public func skip(_ id: String) {
        skippedIDs.insert(id)
        saveToDisk()
    }

    public func resetToday() {
        guard !skippedIDs.isEmpty else { return }
        skippedIDs.removeAll()
        saveToDisk()
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL),
              let record = try? JSONDecoder().decode(RandomFeedSkipRecord.self, from: data) else {
            return
        }
        guard record.day == Self.todayKey() else { return }
        skippedIDs = record.skippedIDs
    }

    private func saveToDisk() {
        let record = RandomFeedSkipRecord(day: Self.todayKey(), skippedIDs: skippedIDs)
        do {
            let dir = fileURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(record)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Failed to save random feed skip store: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func todayKey() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter.string(from: Date())
    }
}
