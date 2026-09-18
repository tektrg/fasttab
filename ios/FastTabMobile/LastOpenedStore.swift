import Foundation
import SwiftUI

public struct LastOpenedItem: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let url: String
    public let title: String
    public let domain: String
    public let openedAt: Date
    /// Reading scroll progress [0.0 – 1.0]. Defaults to 0 for backward compatibility.
    public var readingProgress: Double

    public init(
        id: String = UUID().uuidString,
        url: String,
        title: String,
        domain: String? = nil,
        openedAt: Date = Date(),
        readingProgress: Double = 0.0
    ) {
        self.id = id
        self.url = url
        self.title = title.isEmpty ? (URL(string: url)?.host() ?? url) : title
        self.domain = domain ?? (URL(string: url)?.host() ?? "")
        self.openedAt = openedAt
        self.readingProgress = readingProgress
    }

    public var parsedURL: URL? {
        URL(string: url)
    }

    // Provide explicit CodingKeys so missing `readingProgress` in old data decodes as 0
    enum CodingKeys: String, CodingKey {
        case id, url, title, domain, openedAt, readingProgress
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id               = try c.decode(String.self, forKey: .id)
        url              = try c.decode(String.self, forKey: .url)
        title            = try c.decode(String.self, forKey: .title)
        domain           = try c.decode(String.self, forKey: .domain)
        openedAt         = try c.decode(Date.self, forKey: .openedAt)
        readingProgress  = (try? c.decode(Double.self, forKey: .readingProgress)) ?? 0.0
    }
}

/// Local-only persistence for items opened on iPhone in `InAppBrowserView`.
/// Sits in `UserDefaults.standard` under `"FastTabMobile.lastOpenedReadingHistoryV1"`,
/// maintaining an LRU cap of 50 items.
@MainActor
public final class LastOpenedStore: ObservableObject {
    public static let shared = LastOpenedStore()

    @Published public private(set) var items: [LastOpenedItem] = []

    private static let defaultsKey = "FastTabMobile.lastOpenedReadingHistoryV1"
    private static let maxStoredItems = 50

    private init() {
        loadFromDisk()
    }

    public func loadFromDisk() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([LastOpenedItem].self, from: data) else {
            self.items = []
            return
        }
        self.items = decoded.sorted { $0.openedAt > $1.openedAt }
    }

    public func recordOpened(url: URL, title: String? = nil) {
        let normalizedURLString = url.absoluteString
        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let existingTitle = items.first(where: { $0.url.lowercased() == normalizedURLString.lowercased() })?.title
        let displayTitle: String
        if !cleanTitle.isEmpty {
            displayTitle = cleanTitle
        } else if let existingTitle, !existingTitle.isEmpty {
            displayTitle = existingTitle
        } else {
            displayTitle = url.host() ?? normalizedURLString
        }
        let domain = url.host() ?? ""

        // Preserve any existing reading progress so reopening does not reset progress to 0
        let existingProgress = items.first(where: { $0.url.lowercased() == normalizedURLString.lowercased() })?.readingProgress
            ?? ReaderReadingProgress.shared.progress(for: url)

        // Remove any prior entry for the same canonical URL so it moves to top
        items.removeAll { $0.url.lowercased() == normalizedURLString.lowercased() }

        let newItem = LastOpenedItem(
            url: normalizedURLString,
            title: displayTitle,
            domain: domain,
            openedAt: Date(),
            readingProgress: existingProgress
        )
        items.insert(newItem, at: 0)

        if items.count > Self.maxStoredItems {
            items = Array(items.prefix(Self.maxStoredItems))
        }

        saveToDisk()
    }

    public func remove(id: String) {
        items.removeAll { $0.id == id }
        saveToDisk()
    }

    public func clear() {
        items.removeAll()
        saveToDisk()
    }

    /// Updates the stored reading progress for an existing entry without changing its position.
    public func updateProgress(url: URL, progress: Double) {
        let key = url.absoluteString.lowercased()
        guard let idx = items.firstIndex(where: { $0.url.lowercased() == key }) else { return }
        items[idx].readingProgress = max(0, min(1, progress))
        saveToDisk()
    }

    private func saveToDisk() {
        if let encoded = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(encoded, forKey: Self.defaultsKey)
        }
    }
}
