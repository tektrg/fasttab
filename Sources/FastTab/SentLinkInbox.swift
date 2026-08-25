import Foundation
import OSLog
import FastTabSync

@MainActor
final class SentLinkInbox: ObservableObject {
    static let shared = SentLinkInbox()

    @Published private(set) var pendingCommands: [SyncCommand] = []

    private let logger = Logger(subsystem: "com.trungluong.FastTab", category: "SentLinkInbox")
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
            self.fileURL = fastTabDir.appendingPathComponent("inbox.json")
        }
        loadFromDisk()
    }

    // MARK: - Disk Persistence

    func reloadFromDisk() {
        loadFromDisk()
    }

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            pendingCommands = []
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let commands = try JSONDecoder().decode([SyncCommand].self, from: data)
            // Filter out expired or non-pending commands
            let now = Date()
            self.pendingCommands = commands.filter { cmd in
                cmd.status == .pending && cmd.expiresAt > now
            }
            logger.info("Loaded \(self.pendingCommands.count) pending sent links from inbox.json")
        } catch {
            logger.error("Failed to load inbox.json: \(error.localizedDescription, privacy: .public)")
            self.pendingCommands = []
        }
    }

    private func saveToDisk() {
        do {
            let data = try JSONEncoder().encode(pendingCommands)
            try data.write(to: fileURL, options: .atomic)
            logger.info("Saved \(self.pendingCommands.count) pending sent links to inbox.json")
        } catch {
            logger.error("Failed to save inbox.json: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Command Processing

    func receive(command: SyncCommand) {
        guard command.kind == .openOnMac else { return }

        // Ignore if already present
        if pendingCommands.contains(where: { $0.id == command.id }) {
            return
        }

        // Ignore if expired
        if command.expiresAt <= Date() {
            logger.info("Received expired command id=\(command.id, privacy: .public)")
            return
        }

        pendingCommands.append(command)
        saveToDisk()
        logger.info("Received sent link id=\(command.id, privacy: .public) from \(command.sourceDeviceName, privacy: .public)")
    }

    func markOpened(commandID: String) -> SyncCommand? {
        guard let index = pendingCommands.firstIndex(where: { $0.id == commandID }) else {
            return nil
        }

        var cmd = pendingCommands.remove(at: index)
        cmd.status = .done
        cmd.completedAt = Date()
        saveToDisk()
        logger.info("Marked sent link opened id=\(commandID, privacy: .public)")
        return cmd
    }

    func dismiss(commandID: String) -> SyncCommand? {
        guard let index = pendingCommands.firstIndex(where: { $0.id == commandID }) else {
            return nil
        }

        var cmd = pendingCommands.remove(at: index)
        cmd.status = .refused
        cmd.statusReason = "Dismissed on Mac"
        cmd.completedAt = Date()
        saveToDisk()
        logger.info("Dismissed sent link id=\(commandID, privacy: .public)")
        return cmd
    }

    func pruneExpired() {
        let now = Date()
        // Bail out before touching `pendingCommands` at all when there's
        // nothing to prune. `@Published` fires `objectWillChange` on any
        // mutating access — including a no-op `removeAll` — regardless of
        // whether content actually changed. `asSearchResults()` calls this on
        // every search fetch, so an unconditional `removeAll` here created a
        // feedback loop: fetch -> prune -> objectWillChange -> re-fetch,
        // looping continuously and stomping any typed query back to empty.
        guard pendingCommands.contains(where: { $0.expiresAt <= now }) else { return }
        let initialCount = pendingCommands.count
        pendingCommands.removeAll { $0.expiresAt <= now }
        saveToDisk()
        logger.info("Pruned \(initialCount - self.pendingCommands.count) expired sent links")
    }

    // MARK: - Search Result Mapping

    func asSearchResults() -> [BrowserSearchResult] {
        pruneExpired()

        return pendingCommands.compactMap { cmd in
            guard let data = cmd.payloadJSON.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(OpenOnMacPayload.self, from: data) else {
                return nil
            }

            let sourceName = cmd.sourceDeviceName.isEmpty ? "iPhone" : cmd.sourceDeviceName
            let title = payload.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedTitle = (title?.isEmpty ?? true) ? payload.url : title!

            return BrowserSearchResult(
                title: resolvedTitle,
                url: payload.url,
                browserName: sourceName,
                type: .sent,
                timestamp: cmd.issuedAt,
                bookmarkID: cmd.id,
                profileName: payload.preferBrowser
            )
        }
    }
}
