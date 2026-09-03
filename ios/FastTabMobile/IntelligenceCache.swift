import Foundation
import OSLog
import FastTabSync

/// Persistent cache models for Intelligence results.
public struct CachedTopicCluster: Codable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let summary: String?
    public let recentItemIDs: [String]
    public let relatedBookmarkIDs: [String]
    public let suggestedFolderName: String

    public init(
        id: UUID = UUID(),
        name: String,
        summary: String? = nil,
        recentItemIDs: [String],
        relatedBookmarkIDs: [String],
        suggestedFolderName: String
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.recentItemIDs = recentItemIDs
        self.relatedBookmarkIDs = relatedBookmarkIDs
        self.suggestedFolderName = suggestedFolderName
    }
}

public struct CachedFolderSuggestion: Codable, Sendable, Identifiable {
    public let id: UUID
    public let tabID: String
    public let targetDeviceID: String
    public let targetBrowserName: String
    public let targetProfileName: String
    public let folderPath: [String]
    public let confidence: Double
    public let reason: String

    public init(
        id: UUID = UUID(),
        tabID: String,
        targetDeviceID: String = "",
        targetBrowserName: String,
        targetProfileName: String,
        folderPath: [String],
        confidence: Double,
        reason: String
    ) {
        self.id = id
        self.tabID = tabID
        self.targetDeviceID = targetDeviceID
        self.targetBrowserName = targetBrowserName
        self.targetProfileName = targetProfileName
        self.folderPath = folderPath
        self.confidence = confidence
        self.reason = reason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.tabID = try container.decode(String.self, forKey: .tabID)
        self.targetDeviceID = try container.decodeIfPresent(String.self, forKey: .targetDeviceID) ?? ""
        self.targetBrowserName = try container.decode(String.self, forKey: .targetBrowserName)
        self.targetProfileName = try container.decode(String.self, forKey: .targetProfileName)
        self.folderPath = try container.decode([String].self, forKey: .folderPath)
        self.confidence = try container.decode(Double.self, forKey: .confidence)
        self.reason = try container.decode(String.self, forKey: .reason)
    }
}

public struct CachedIntelligenceState: Codable, Sendable {
    public var interestProfile: [String] = []
    public var lastProfileRebuiltAt: Date?
    public var topicClusters: [CachedTopicCluster] = []
    public var folderSuggestions: [CachedFolderSuggestion] = []
    public var computedAt: Date?
    public var dataFingerprint: String = ""

    public init(
        interestProfile: [String] = [],
        lastProfileRebuiltAt: Date? = nil,
        topicClusters: [CachedTopicCluster] = [],
        folderSuggestions: [CachedFolderSuggestion] = [],
        computedAt: Date? = nil,
        dataFingerprint: String = ""
    ) {
        self.interestProfile = interestProfile
        self.lastProfileRebuiltAt = lastProfileRebuiltAt
        self.topicClusters = topicClusters
        self.folderSuggestions = folderSuggestions
        self.computedAt = computedAt
        self.dataFingerprint = dataFingerprint
    }
}

/// Disk cache coordinator for intelligence computations.
@MainActor
public final class IntelligenceCache: ObservableObject {
    public static let shared = IntelligenceCache()

    @Published public private(set) var state: CachedIntelligenceState = CachedIntelligenceState()

    private let logger = Logger(subsystem: "app.theindie.FastTab", category: "IntelligenceCache")
    private let fileURL: URL
    private static let cacheFileName = "intelligence_cache.json"

    public init(customFileURL: URL? = nil) {
        self.fileURL = customFileURL ?? AppGroupContainer.fileURL(forFileNamed: Self.cacheFileName)
        loadFromDisk()
    }

    public func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            self.state = try JSONDecoder().decode(CachedIntelligenceState.self, from: data)
            logger.info("Loaded intelligence cache from disk: \(self.state.topicClusters.count) clusters, \(self.state.folderSuggestions.count) suggestions")
        } catch {
            logger.error("Failed to load intelligence cache: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func saveToDisk() {
        do {
            let dir = fileURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(state)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Failed to save intelligence cache: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func updateState(_ newState: CachedIntelligenceState) {
        self.state = newState
        saveToDisk()
    }

    public func clear() {
        self.state = CachedIntelligenceState()
        saveToDisk()
    }
}
