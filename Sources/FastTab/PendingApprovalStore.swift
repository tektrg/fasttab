import Foundation
import OSLog
import FastTabSync

public struct PendingApprovalItem: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let commandID: String
    public let kind: SyncCommandKind
    public let browserName: String
    public let title: String
    public let url: String
    public let profileName: String?
    public let bookmarkID: String?
    public let sourceDeviceName: String
    public let requestedAt: Date
    public let expiresAt: Date

    public init(
        id: String = UUID().uuidString,
        commandID: String,
        kind: SyncCommandKind,
        browserName: String,
        title: String,
        url: String,
        profileName: String? = nil,
        bookmarkID: String? = nil,
        sourceDeviceName: String,
        requestedAt: Date = Date(),
        expiresAt: Date = Date().addingTimeInterval(7 * 24 * 3600) // 7-day TTL
    ) {
        self.id = id
        self.commandID = commandID
        self.kind = kind
        self.browserName = browserName
        self.title = title
        self.url = url
        self.profileName = profileName
        self.bookmarkID = bookmarkID
        self.sourceDeviceName = sourceDeviceName
        self.requestedAt = requestedAt
        self.expiresAt = expiresAt
    }
}

@MainActor
final class PendingApprovalStore: ObservableObject {
    static let shared = PendingApprovalStore()

    @Published private(set) var items: [PendingApprovalItem] = []

    private let logger = Logger(subsystem: "com.trungluong.FastTab", category: "PendingApprovalStore")
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let fastTabDir = appSupport.appendingPathComponent("com.trungluong.FastTab", isDirectory: true)
            try? FileManager.default.createDirectory(at: fastTabDir, withIntermediateDirectories: true)
            self.fileURL = fastTabDir.appendingPathComponent("pending-approvals.json")
        }
        loadFromDisk()
    }

    // MARK: - Disk Persistence

    func reloadFromDisk() {
        loadFromDisk()
    }

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            items = []
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let loaded = try JSONDecoder().decode([PendingApprovalItem].self, from: data)
            let now = Date()
            self.items = loaded.filter { $0.expiresAt > now }
            logger.info("Loaded \(self.items.count) pending approvals from disk")
        } catch {
            logger.error("Failed to load pending-approvals.json: \(error.localizedDescription, privacy: .public)")
            self.items = []
        }
    }

    private func saveToDisk() {
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: fileURL, options: .atomic)
            logger.info("Saved \(self.items.count) pending approvals to disk")
        } catch {
            logger.error("Failed to save pending-approvals.json: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Management

    @discardableResult
    func add(command: SyncCommand) -> PendingApprovalItem? {
        guard command.kind == .deleteBookmark || command.kind == .deleteHistoryItem else {
            return nil
        }

        // Avoid duplicates
        if let existing = items.first(where: { $0.commandID == command.id }) {
            return existing
        }

        let now = Date()
        if command.expiresAt <= now {
            logger.info("Ignoring expired delete command id=\(command.id, privacy: .public)")
            return nil
        }

        guard let payloadData = command.payloadJSON.data(using: .utf8) else {
            return nil
        }

        let item: PendingApprovalItem
        switch command.kind {
        case .deleteBookmark:
            guard let payload = try? JSONDecoder().decode(DeleteBookmarkPayload.self, from: payloadData) else {
                return nil
            }
            item = PendingApprovalItem(
                commandID: command.id,
                kind: .deleteBookmark,
                browserName: payload.browserName,
                title: payload.url,
                url: payload.url,
                profileName: payload.profileName,
                bookmarkID: payload.bookmarkID,
                sourceDeviceName: command.sourceDeviceName,
                requestedAt: command.issuedAt,
                expiresAt: now.addingTimeInterval(7 * 24 * 3600)
            )

        case .deleteHistoryItem:
            guard let payload = try? JSONDecoder().decode(DeleteHistoryItemPayload.self, from: payloadData) else {
                return nil
            }
            item = PendingApprovalItem(
                commandID: command.id,
                kind: .deleteHistoryItem,
                browserName: payload.browserName,
                title: payload.url,
                url: payload.url,
                profileName: nil,
                bookmarkID: nil,
                sourceDeviceName: command.sourceDeviceName,
                requestedAt: command.issuedAt,
                expiresAt: now.addingTimeInterval(7 * 24 * 3600)
            )

        default:
            return nil
        }

        items.append(item)
        saveToDisk()
        logger.info("Added pending approval item id=\(item.id, privacy: .public) for command=\(command.id, privacy: .public)")
        return item
    }

    func approve(item: PendingApprovalItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items.remove(at: index)
        saveToDisk()

        // Execute deletion
        executeDeletion(item)

        // Push .done status
        let cmd = SyncCommand(
            id: item.commandID,
            kind: item.kind,
            targetDeviceID: "",
            sourceDeviceName: item.sourceDeviceName,
            issuedAt: item.requestedAt,
            expiresAt: item.expiresAt,
            payloadJSON: "",
            status: .done,
            statusReason: "Approved on Mac",
            completedAt: Date()
        )
        SyncService.shared.pushCommandResult(cmd)
        logger.info("Approved pending deletion id=\(item.id, privacy: .public)")
    }

    func dismiss(item: PendingApprovalItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items.remove(at: index)
        saveToDisk()

        // Push .refused status
        let cmd = SyncCommand(
            id: item.commandID,
            kind: item.kind,
            targetDeviceID: "",
            sourceDeviceName: item.sourceDeviceName,
            issuedAt: item.requestedAt,
            expiresAt: item.expiresAt,
            payloadJSON: "",
            status: .refused,
            statusReason: "Dismissed by user on Mac",
            completedAt: Date()
        )
        SyncService.shared.pushCommandResult(cmd)
        logger.info("Dismissed pending deletion id=\(item.id, privacy: .public)")
    }

    func approveAll() {
        let snapshot = items
        for item in snapshot {
            approve(item: item)
        }
    }

    func dismissAll() {
        let snapshot = items
        for item in snapshot {
            dismiss(item: item)
        }
    }

    func pruneExpired() {
        let now = Date()
        let initialCount = items.count
        items.removeAll { $0.expiresAt <= now }
        if items.count != initialCount {
            saveToDisk()
            logger.info("Pruned \(initialCount - self.items.count) expired pending approvals")
        }
    }

    private func executeDeletion(_ item: PendingApprovalItem) {
        // Try extension bridge first if Chromium and connected
        if item.browserName.contains("Chrome") || item.browserName.contains("Brave") || item.browserName.contains("Edge") {
            if item.kind == .deleteBookmark {
                var payload: [String: Any] = ["url": item.url]
                if let bmID = item.bookmarkID { payload["bookmarkId"] = bmID }
                if ExtensionBridge.shared.sendBrowserCommand(appName: item.browserName, type: "deleteBookmark", payload: payload) {
                    logger.info("Executed bookmark deletion via extension for url=\(item.url, privacy: .public)")
                    return
                }
            } else if item.kind == .deleteHistoryItem {
                if ExtensionBridge.shared.sendBrowserCommand(appName: item.browserName, type: "deleteHistoryItem", payload: ["url": item.url]) {
                    logger.info("Executed history deletion via extension for url=\(item.url, privacy: .public)")
                    return
                }
            }
        }

        // Fallback to backend deletion
        let dummyResult = BrowserSearchResult(
            title: item.title,
            url: item.url,
            browserName: item.browserName,
            type: item.kind == .deleteBookmark ? .bookmark : .history,
            timestamp: Date(),
            bookmarkID: item.bookmarkID,
            profileName: item.profileName
        )
        let backend = BrowserTabService.shared.backend(for: item.browserName)
        if item.kind == .deleteBookmark {
            backend?.deleteBookmark(dummyResult)
        } else if item.kind == .deleteHistoryItem {
            backend?.deleteHistoryItem(dummyResult)
        }
    }
}
