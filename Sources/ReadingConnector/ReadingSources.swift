import FastTabReader
import FastTabSync
import Foundation

/// Where the reading connector reads from: the files the FastTab app keeps current. Every
/// read is a fresh read of the file (the app is another process), and nothing here writes.
public struct ReadingSources: Sendable {
    /// `~/Library/Application Support/com.trungluong.FastTab` (or a test folder).
    public let supportDirectory: URL
    /// The FastTab List (read-later items, synced with the phone).
    public var listFile: URL { supportDirectory.appendingPathComponent("FastTabList/list.json") }
    /// The phone's reading activity (any page read, listed or not).
    public var activityFile: URL { ReadingActivityMirror.fileURL(supportDirectory: supportDirectory) }
    /// The phone's highlights + comment threads.
    public var readerDirectory: URL { ReaderMirror.directory(supportDirectory: supportDirectory) }

    public init(supportDirectory: URL) {
        self.supportDirectory = supportDirectory
    }

    /// The app's folder; `FASTTAB_SUPPORT_DIR` overrides it (tests, a second profile).
    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> ReadingSources {
        if let override = environment["FASTTAB_SUPPORT_DIR"], !override.isEmpty {
            return ReadingSources(supportDirectory: URL(fileURLWithPath: override, isDirectory: true))
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ReadingSources(supportDirectory: support.appendingPathComponent("com.trungluong.FastTab", isDirectory: true))
    }

    /// List items as last written by the app (read-only: no legacy-defaults migration).
    func listItems() -> [SavedOnIPhoneLink] {
        guard let data = try? Data(contentsOf: listFile) else { return [] }
        return (try? JSONDecoder().decode([SavedOnIPhoneLink].self, from: data)) ?? []
    }

    func activities() -> [ReadingActivity] {
        ReadingActivityMirror.load(fileURL: activityFile)
    }

    var readerLibrary: ReaderLibrary { ReaderLibrary(directory: readerDirectory) }
}
