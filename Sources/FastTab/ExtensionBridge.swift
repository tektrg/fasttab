import Foundation
import OSLog

/// Shared well-known Unix socket path between FastTab.app and the native host.
/// The host target declares the same literal (separate executables, no shared
/// library) — see `FastTabNativeHost/main.swift`. Keep the two in sync.
enum ExtensionSocketPath {
    static var value: String {
        NSHomeDirectory() + "/Library/Application Support/com.trungluong.FastTab/extension-bridge.sock"
    }
}

/// Beta gate: the browser extension is an opt-in experiment, off by default.
/// When off, the bridge still listens (so flipping the toggle connects
/// immediately), but no decorator serves from it — FastTab behaves exactly as
/// today.
enum ExtensionBetaPreference {
    static let defaultsKey = "FastTab.extensionBeta.enabled.v1"

    static var isEnabled: Bool {
        if UserDefaults.standard.object(forKey: defaultsKey) == nil {
            return true // Promoted out of beta, enabled by default
        }
        return UserDefaults.standard.bool(forKey: defaultsKey)
    }

    static func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: defaultsKey)
    }
}

/// A tab from the extension snapshot, mapped to the app's 1-based window/tab
/// indexing (front window = 1) and carrying the extension's richer state.
struct ExtensionTabRecord: Sendable {
    let tabID: Int
    let windowIndex: Int
    let tabIndex: Int
    let title: String
    let url: String
    let windowName: String
    let isActive: Bool
    let isAudible: Bool
    let isMuted: Bool
    let isPinned: Bool
    let isDiscarded: Bool
    let groupTitle: String?
    let lastAccessed: Date?

    init(
        tabID: Int,
        windowIndex: Int,
        tabIndex: Int,
        title: String,
        url: String,
        windowName: String,
        isActive: Bool,
        isAudible: Bool,
        isMuted: Bool,
        isPinned: Bool,
        isDiscarded: Bool,
        groupTitle: String?,
        lastAccessed: Date? = nil
    ) {
        self.tabID = tabID
        self.windowIndex = windowIndex
        self.tabIndex = tabIndex
        self.title = title
        self.url = url
        self.windowName = windowName
        self.isActive = isActive
        self.isAudible = isAudible
        self.isMuted = isMuted
        self.isPinned = isPinned
        self.isDiscarded = isDiscarded
        self.groupTitle = groupTitle
        self.lastAccessed = lastAccessed
    }
}

/// Synchronous, immutable snapshot read the decorator uses on the hot path.
/// Produced under the bridge's lock so a `BrowserBackend` call never waits on
/// the network.
struct ExtensionSnapshotView: Sendable {
    let tabs: [ExtensionTabRecord]
    let activationTimes: [Int: Date]
}

/// What the enrichment decorator needs from the bridge. Protocol so the
/// decorator's selection logic is testable with a mock.
protocol ExtensionBridgeServing: Sendable {
    func snapshotView(for appName: String, profileCount: Int) -> ExtensionSnapshotView?
    func isConnected(appName: String) -> Bool
    func sendCommand(appName: String, type: String, tabID: Int, extraPayload: [String: Any], timeout: TimeInterval) -> Bool
    func sendBrowserCommand(appName: String, type: String, payload: [String: Any], timeout: TimeInterval) -> Bool
    func deleteBookmark(appName: String, id: String?, url: String?) -> Bool
}

extension ExtensionBridgeServing {
    /// Convenience for commands that only need `tabId` (activate/close) — no
    /// extra payload fields.
    func sendCommand(appName: String, type: String, tabID: Int, timeout: TimeInterval) -> Bool {
        sendCommand(appName: appName, type: type, tabID: tabID, extraPayload: [:], timeout: timeout)
    }

    /// Convenience for backward compatibility with [String: Bool] payloads.
    func sendCommand(appName: String, type: String, tabID: Int, extraPayload: [String: Bool], timeout: TimeInterval) -> Bool {
        var anyPayload: [String: Any] = [:]
        for (k, v) in extraPayload { anyPayload[k] = v }
        return sendCommand(appName: appName, type: type, tabID: tabID, extraPayload: anyPayload, timeout: timeout)
    }

    func sendBrowserCommand(appName: String, type: String, payload: [String: Any], timeout: TimeInterval) -> Bool {
        return false
    }

    func deleteBookmark(appName: String, id: String?, url: String?) -> Bool {
        var payload: [String: Any] = [:]
        if let id {
            payload["bookmarkId"] = id
            payload["id"] = id
        }
        if let url { payload["url"] = url }
        return sendBrowserCommand(appName: appName, type: "deleteBookmark", payload: payload, timeout: 2.0)
    }
}

/// UI-facing per-browser connection status for Settings / onboarding.
struct ExtensionConnectionStatus: Sendable, Equatable, Identifiable {
    var id: String { appName }
    let appName: String
    let isConnected: Bool
    let versionMismatch: Bool
}

/// Thread-safe box for a single command's reply. Lives in the command registry
/// (under the bridge lock) and is fulfilled by the connection reader thread.
private final class CommandWaiter: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let resultLock = NSLock()
    private var result: Bool = false

    func wait(timeout: TimeInterval) -> Bool {
        _ = semaphore.wait(timeout: .now() + timeout)
        return resultLock.withLock { result }
    }

    func fulfill(_ value: Bool) {
        resultLock.withLock { result = value }
        semaphore.signal()
    }
}

/// Mutable per-connection state. Value type; all mutations happen inside the
/// bridge's `OSAllocatedUnfairLock`, so nothing here crosses threads except
/// through the lock.
struct ConnectionState {
    var appName: String = ""
    var extensionVersion: String = ""
    var isProtocolMismatch: Bool = false
    var lastContactAt: Date = .distantPast
    var lastSeq: UInt64 = 0
    var tabs: [Int: ExtensionTabRecord] = [:]
    var activationTimes: [Int: Date] = [:]
    var outboundQueue: [Data] = []
    /// Signaled whenever a frame is enqueued, or the connection is torn down,
    /// so `writeLoop` wakes immediately instead of polling on a fixed sleep.
    /// A `let` reference type: copying `ConnectionState` in and out of the
    /// registry dictionary still shares the one semaphore for this fd's
    /// lifetime.
    let outboundSignal = DispatchSemaphore(value: 0)
}

private struct PendingCommand {
    let ownerFD: Int32
    let waiter: CommandWaiter
    let commandType: String
    let tabID: Int?
}

private struct BridgeRegistry {
    var connections: [Int32: ConnectionState] = [:]
    var nextRequestID: UInt64 = 0
    var pendingCommands: [UInt64: PendingCommand] = [:]
}

/// Owns the Unix socket between FastTab.app and the native-messaging host, and
/// the per-browser tab snapshot the extension maintains.
///
/// `@unchecked Sendable` is justified: every mutable field is behind
/// `lock` (an `OSAllocatedUnfairLock`), and `status` is only written from the
/// main thread (via `publishStatus`). The decorator reads the snapshot
/// synchronously through `snapshotView(for:profileCount:)` — never awaiting,
/// so "always prioritize speed" holds even if the extension is slow.
final class ExtensionBridge: ObservableObject, ExtensionBridgeServing, @unchecked Sendable {
    static let shared = ExtensionBridge()

    @Published private(set) var status: [ExtensionConnectionStatus] = []

    /// Fired the instant the extension reports a real tab activation —
    /// (appName, url, activatedAt) — in any window, not just the front one.
    /// Lets frecency ranking react immediately instead of waiting for the
    /// slower front-tab poll. May be called from any thread; the handler
    /// (set by `BrowserTabService`) is responsible for hopping to the main
    /// actor before touching UI-facing state.
    var onTabActivated: (@Sendable (String, Int, String, Date) -> Void)?
    var onTabRemoved: (@Sendable (String, Int, String?) -> Void)?
    var onTabUpserted: (@Sendable (String, ExtensionTabRecord) -> Void)?
    var onSnapshotReceived: (@Sendable (String, [ExtensionTabRecord]) -> Void)?

    private let logger = Logger(subsystem: "com.trungluong.FastTab", category: "ExtensionBridge")
    private let lock = OSAllocatedUnfairLock(initialState: BridgeRegistry())
    private let socketPath = ExtensionSocketPath.value
    /// Protocol version in the `{v,type,seq,payload}` envelope. App and
    /// extension ship independently; a mismatch on this major version means the
    /// bridge refuses to serve and the app silently uses the AppleScript path.
    private let protocolVersion = 1
    /// A connection older than this between inbound messages is considered
    /// stale (worker died silently) and stops serving until it reconnects.
    /// The extension's own keepalive alarm fires at most once a minute (the
    /// Chrome-enforced floor for packed extensions), so this needs enough
    /// margin above that plus round-trip time — not just above the 20s ping.
    private let freshWindow: TimeInterval = 90
    private let pingInterval: TimeInterval = 20
    private var started = false
    private var pingTimer: Timer?

    private init() {}

    func start() {
        guard !started else { return }
        started = true

        let dir = (socketPath as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            logger.error("socket dir create failed: \(String(describing: error), privacy: .public)")
        }
        // A stale socket file from a previous run blocks bind; the app's own
        // copy can't exist while this process is starting, so removing it is safe.
        try? FileManager.default.removeItem(atPath: socketPath)

        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else {
            logger.error("socket() failed: \(String(cString: strerror(errno)), privacy: .public)")
            return
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let sunPathSize = MemoryLayout.size(ofValue: addr.sun_path)
        socketPath.withCString { pathCString in
            withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
                _ = strlcpy(sunPath, pathCString, sunPathSize)
            }
        }
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(listener, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            logger.error("bind() failed: \(String(cString: strerror(errno)), privacy: .public)")
            close(listener)
            return
        }
        guard listen(listener, 8) == 0 else {
            logger.error("listen() failed: \(String(cString: strerror(errno)), privacy: .public)")
            close(listener)
            return
        }

        Thread.detachNewThread { [weak self] in
            self?.acceptLoop(listener)
        }

        let timer = Timer(timeInterval: pingInterval, repeats: true) { [weak self] _ in
            self?.sendPings()
        }
        timer.tolerance = 2.0
        RunLoop.main.add(timer, forMode: .common)
        pingTimer = timer
        logger.info("extension bridge listening at \(self.socketPath, privacy: .public)")
    }

    // MARK: - Decorator-facing API (synchronous, never blocks on the network)

    /// Returns the aggregated tab snapshot for `appName` only when every
    /// on-disk profile of that browser is connected and fresh. A partial
    /// profile set would silently hide tabs, so it falls back to AppleScript
    /// instead (correctness over speed).
    func snapshotView(for appName: String, profileCount: Int) -> ExtensionSnapshotView? {
        lock.withLock { registry in
            let connections = registry.connections.values.filter { $0.appName == appName }
            let now = Date()
            let activeConnections: [ConnectionState]
            switch Self.servableConnections(
                Array(connections), profileCount: profileCount, freshWindow: freshWindow, now: now
            ) {
            case .serve(let kept, let dropped):
                if dropped > 0 {
                    logger.info("dropped ghost connections. app=\(appName, privacy: .public) connected=\(connections.count, privacy: .public) kept=\(kept.count, privacy: .public)")
                }
                activeConnections = kept

            case .reject(let reason):
                logger.info("gate reject (\(reason, privacy: .public)). app=\(appName, privacy: .public) connections=\(connections.count, privacy: .public) required=\(profileCount, privacy: .public)")
                return nil
            }
            var activationTimes: [Int: Date] = [:]
            for connection in activeConnections {
                activationTimes.merge(connection.activationTimes) { $1 }
            }
            let tabs = Self.dedupedTabs(from: activeConnections.map { Array($0.tabs.values) })
            return ExtensionSnapshotView(tabs: tabs, activationTimes: activationTimes)
        }
    }

    /// Merges per-connection tab lists into one, collapsing entries that share
    /// both `tabID` and `url`. A service-worker restart (sleep/wake, idle
    /// timeout, extension reload) opens a fresh socket before the old one's
    /// read loop notices EOF, so two connections for the same profile can
    /// briefly both be "fresh" and both report the same tab. Connections carry
    /// no profile identity to catch that directly, so this dedupes by content
    /// instead: the same physical tab reported twice always shares both
    /// `tabID` and `url`, while two genuinely different profiles that happen
    /// to reuse a raw `tabID` almost never also share a URL, so real tabs from
    /// distinct profiles are never collapsed together.
    static func dedupedTabs(from tabsByConnection: [[ExtensionTabRecord]]) -> [ExtensionTabRecord] {
        var merged: [String: ExtensionTabRecord] = [:]
        for tabs in tabsByConnection {
            for tab in collapsingSameSlotTabs(tabs) {
                merged["\(tab.tabID)|\(MyOrderReconciler.canonicalURL(tab.url))"] = tab
            }
        }
        return Array(merged.values)
    }

    /// Collapses records from one profile that claim the same window slot — same
    /// `windowIndex` *and* `tabIndex` — while showing the same URL. A window
    /// holds exactly one tab per position, so two such records can never be two
    /// real tabs; they are one physical tab reported under two IDs, which is what
    /// Chromium's `tabs.onReplaced` produces when it swaps a tab's ID (waking a
    /// discarded "sleeping" tab, prerender activation) and the extension's mirror
    /// keeps the pre-swap ID. Left in, the stale twin shows up as a duplicate tab
    /// the user does not have. The URL has to match too: a stale record whose
    /// slot is now occupied by a *different* page is a different tab, and
    /// dropping it would hide a real one. The live record wins over the discarded
    /// one, since it carries current title/audio state.
    ///
    /// Also collapses discarded (sleeping) tabs within the same window when an active
    /// counterpart exists for the same canonical URL, even if their `tabIndex` shifted
    /// while the tab was asleep.
    ///
    /// Scoped to a single connection on purpose — `windowIndex` is numbered per
    /// profile, so the same slot in two profiles is two different windows.
    static func collapsingSameSlotTabs(_ tabs: [ExtensionTabRecord]) -> [ExtensionTabRecord] {
        var keptBySlot: [String: ExtensionTabRecord] = [:]
        var slotOrder: [String] = []

        // Pass 1: Collapse exact slot matches (same window, same tab index, same canonical URL)
        for tab in tabs {
            let canonical = MyOrderReconciler.canonicalURL(tab.url)
            let slot = "\(tab.windowIndex)|\(tab.tabIndex)|\(canonical)"
            guard let kept = keptBySlot[slot] else {
                keptBySlot[slot] = tab
                slotOrder.append(slot)
                continue
            }
            if kept.isDiscarded && !tab.isDiscarded {
                keptBySlot[slot] = tab
            } else if kept.isDiscarded == tab.isDiscarded && tab.tabID > kept.tabID {
                keptBySlot[slot] = tab
            }
        }
        let slotCollapsed = slotOrder.compactMap { keptBySlot[$0] }

        // Pass 2: Within each window and canonical URL:
        // A discarded (sleeping) tab cannot coexist with an active tab for the same URL in the same window.
        // If an active tab exists, drop any discarded twin for that canonical URL.
        // If multiple discarded tabs exist for the same canonical URL in the same window, keep only the newest tabID.
        let activeKeys = Set(slotCollapsed.filter { !$0.isDiscarded }.map {
            "\($0.windowIndex)|\(MyOrderReconciler.canonicalURL($0.url))"
        })

        var seenDiscardedKeys = Set<String>()
        var finalTabs: [ExtensionTabRecord] = []
        let sortedForDiscarded = slotCollapsed.sorted { $0.tabID > $1.tabID }

        for tab in sortedForDiscarded {
            let windowCanonical = "\(tab.windowIndex)|\(MyOrderReconciler.canonicalURL(tab.url))"
            if !tab.isDiscarded {
                finalTabs.append(tab)
            } else {
                if activeKeys.contains(windowCanonical) {
                    continue
                }
                if !seenDiscardedKeys.insert(windowCanonical).inserted {
                    continue
                }
                finalTabs.append(tab)
            }
        }

        return finalTabs.sorted {
            if $0.windowIndex != $1.windowIndex {
                return $0.windowIndex < $1.windowIndex
            }
            return $0.tabIndex < $1.tabIndex
        }
    }


    /// Caps `connections` to the `limit` most recently contacted, when there
    /// are more than `limit`. A browser's real profile count bounds how many
    /// connections should ever exist for it at once; any excess is a stale
    /// connection whose owning process hasn't been torn down yet, so its
    /// (possibly frozen, still-within-`freshWindow`) tabs are excluded rather
    /// than merged in as if it were a genuine extra profile. `limit <= 0` is
    /// treated as "no reliable profile count" and left uncapped.
    static func freshestConnections(_ connections: [ConnectionState], limit: Int) -> [ConnectionState] {
        guard limit > 0, connections.count > limit else { return connections }
        return Array(connections.sorted { $0.lastContactAt > $1.lastContactAt }.prefix(limit))
    }

    enum GateDecision {
        case serve(connections: [ConnectionState], droppedGhosts: Int)
        case reject(reason: String)
    }

    /// Decides whether `connections` (already filtered to one browser) can serve
    /// a snapshot, and which of them to serve from.
    ///
    /// **Ghosts are dropped before the freshness check, not after.** A socket
    /// whose owning profile window is gone stays open — the relay process
    /// outlives the profile, so the read loop never sees EOF — and its
    /// `lastContactAt` then climbs forever. Checking freshness across *all*
    /// connections first made a single such ghost permanently unsatisfiable:
    /// the browser fell back to AppleScript for the rest of the app's lifetime,
    /// no matter how healthy the real profiles were.
    ///
    /// Dropping first preserves the safety property that motivated the gate —
    /// `profileCount` connections must still be present and fresh, so a partial
    /// profile set can never silently hide tabs — while letting a ghost be
    /// discarded as the extra connection it actually is.
    static func servableConnections(
        _ connections: [ConnectionState],
        profileCount: Int,
        freshWindow: TimeInterval,
        now: Date
    ) -> GateDecision {
        guard !connections.isEmpty else { return .reject(reason: "no connections") }

        let candidates = freshestConnections(connections, limit: profileCount)
        let droppedGhosts = connections.count - candidates.count

        guard candidates.allSatisfy({ !$0.isProtocolMismatch }) else {
            return .reject(reason: "protocol mismatch")
        }
        guard candidates.allSatisfy({ now.timeIntervalSince($0.lastContactAt) < freshWindow }) else {
            let ages = candidates.map { Int(now.timeIntervalSince($0.lastContactAt)) }
            return .reject(reason: "stale ageSecs=\(ages.description)")
        }
        guard candidates.count >= profileCount else {
            return .reject(reason: "incomplete profile coverage")
        }
        return .serve(connections: candidates, droppedGhosts: droppedGhosts)
    }

    func isConnected(appName: String) -> Bool {
        lock.withLock { registry in
            registry.connections.values.contains { $0.appName == appName }
        }
    }

    /// Sends an activate/close/setMuted/delete command to the extension owning
    /// `tabID` (or any connection for `appName`) and blocks for the reply (with timeout).
    /// Returns whether the extension confirmed. Blocks the caller — only call from a background
    /// thread. `extraPayload` carries command-specific fields beyond `requestID`/`tabId`.
    func sendCommand(appName: String, type: String, tabID: Int, extraPayload: [String: Any] = [:], timeout: TimeInterval = 2.0) -> Bool {
        let waiter = CommandWaiter()
        let requestID = lock.withLockUnchecked { registry -> UInt64? in
            guard let fd = registry.connections.first(where: { $0.value.appName == appName && $0.value.tabs[tabID] != nil })?.key ??
                           registry.connections.first(where: { $0.value.appName == appName })?.key else {
                return nil
            }
            registry.nextRequestID += 1
            let requestID = registry.nextRequestID
            registry.pendingCommands[requestID] = PendingCommand(ownerFD: fd, waiter: waiter, commandType: type, tabID: tabID)
            var payload: [String: Any] = ["requestID": requestID, "tabId": tabID]
            for (key, value) in extraPayload { payload[key] = value }
            let frame = Self.encode([
                "v": protocolVersion,
                "type": type,
                "seq": 0,
                "payload": payload
            ])
            if var connection = registry.connections[fd] {
                connection.outboundQueue.append(frame)
                connection.outboundSignal.signal()
                registry.connections[fd] = connection
            }
            if type == "closeTab" {
                for key in registry.connections.keys {
                    registry.connections[key]?.tabs.removeValue(forKey: tabID)
                    registry.connections[key]?.activationTimes.removeValue(forKey: tabID)
                }
            }
            return requestID
        }
        guard let requestID else { return false }
        let result = waiter.wait(timeout: timeout)
        _ = lock.withLock { registry in registry.pendingCommands.removeValue(forKey: requestID) }
        return result
    }

    /// Sends a browser-level command (e.g. `deleteBookmark`, `deleteHistoryItem`, `getBookmarks`, `searchHistory`)
    /// without requiring a specific `tabID`.
    func sendBrowserCommand(appName: String, type: String, payload: [String: Any], timeout: TimeInterval = 2.0) -> Bool {
        let waiter = CommandWaiter()
        let requestID = lock.withLockUnchecked { registry -> UInt64? in
            guard let fd = registry.connections.first(where: { $0.value.appName == appName })?.key else {
                return nil
            }
            registry.nextRequestID += 1
            let requestID = registry.nextRequestID
            registry.pendingCommands[requestID] = PendingCommand(ownerFD: fd, waiter: waiter, commandType: type, tabID: nil)
            var fullPayload: [String: Any] = ["requestID": requestID]
            for (key, value) in payload { fullPayload[key] = value }
            let frame = Self.encode([
                "v": protocolVersion,
                "type": type,
                "seq": 0,
                "payload": fullPayload
            ])
            if var connection = registry.connections[fd] {
                connection.outboundQueue.append(frame)
                connection.outboundSignal.signal()
                registry.connections[fd] = connection
            }
            return requestID
        }
        guard let requestID else { return false }
        let result = waiter.wait(timeout: timeout)
        _ = lock.withLock { registry in registry.pendingCommands.removeValue(forKey: requestID) }
        return result
    }

    func moveBookmark(appName: String, id: String, parentId: String?, index: Int?) -> Bool {
        var payload: [String: Any] = ["id": id]
        if let parentId { payload["parentId"] = parentId }
        if let index { payload["index"] = index }
        return sendBrowserCommand(appName: appName, type: "moveBookmark", payload: payload)
    }

    func createBookmarkFolder(appName: String, parentId: String?, title: String, index: Int?) -> Bool {
        var payload: [String: Any] = ["title": title]
        if let parentId { payload["parentId"] = parentId }
        if let index { payload["index"] = index }
        return sendBrowserCommand(appName: appName, type: "createFolder", payload: payload)
    }

    func updateBookmark(appName: String, id: String, title: String?, url: String?) -> Bool {
        var payload: [String: Any] = ["id": id]
        if let title { payload["title"] = title }
        if let url { payload["url"] = url }
        return sendBrowserCommand(appName: appName, type: "updateBookmark", payload: payload)
    }

    func deleteBookmark(appName: String, id: String?, url: String?) -> Bool {
        var payload: [String: Any] = [:]
        if let id {
            payload["bookmarkId"] = id
            payload["id"] = id
        }
        if let url { payload["url"] = url }
        return sendBrowserCommand(appName: appName, type: "deleteBookmark", payload: payload)
    }

    // MARK: - Socket plumbing

    private func acceptLoop(_ listener: Int32) {
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                break
            }
            handleNewConnection(client)
        }
        close(listener)
    }

    private func handleNewConnection(_ fd: Int32) {
        lock.withLock { registry in
            registry.connections[fd] = ConnectionState()
        }
        logger.info("extension connection opened fd=\(fd)")
        publishStatus()
        Thread.detachNewThread { [self] in readLoop(fd) }
        Thread.detachNewThread { [self] in writeLoop(fd) }
    }

    private func readLoop(_ fd: Int32) {
        while let frame = Self.readFrame(fd: fd) {
            handleInbound(fd, frame)
        }
        lock.withLock { registry in
            // Wake a `writeLoop` blocked waiting for outbound work so it can
            // notice the connection is gone and exit, instead of sitting on
            // its wait timeout.
            registry.connections[fd]?.outboundSignal.signal()
            registry.connections.removeValue(forKey: fd)
            // Fail only this connection's in-flight commands; another
            // connection's pending reply must be left alone.
            registry.pendingCommands = registry.pendingCommands.filter { _, pending in
                if pending.ownerFD == fd {
                    pending.waiter.fulfill(false)
                    return false
                }
                return true
            }
        }
        close(fd)
        logger.info("extension connection closed fd=\(fd)")
        publishStatus()
    }

    /// Drains `connection.outboundQueue` as frames arrive. Blocks on the
    /// connection's `outboundSignal` between frames rather than polling on a
    /// fixed sleep — every enqueue (and teardown) signals it, so this wakes
    /// on demand instead of 20 times a second per connected browser whether
    /// or not there's anything to send. The wait still carries a timeout as a
    /// backstop against a signal getting missed, not as the normal wake path.
    private func writeLoop(_ fd: Int32) {
        guard let outboundSignal = lock.withLock({ registry in registry.connections[fd]?.outboundSignal }) else { return }
        while true {
            let frame = lock.withLock { registry -> Data? in
                guard var connection = registry.connections[fd], !connection.outboundQueue.isEmpty else { return nil }
                let frame = connection.outboundQueue.removeFirst()
                // ConnectionState is a value type: write the drained copy back,
                // or the queue never empties and this loop spins forever.
                registry.connections[fd] = connection
                return frame
            }
            guard let frame else {
                if !lock.withLock({ registry in registry.connections[fd] != nil }) { return }
                _ = outboundSignal.wait(timeout: .now() + 2.0)
                continue
            }
            if !Self.writeAll(fd: fd, frame) {
                _ = lock.withLock { registry in registry.connections.removeValue(forKey: fd) }
                close(fd)
                publishStatus()
                return
            }
        }
    }

    private func handleInbound(_ fd: Int32, _ frame: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }
        let payload = json["payload"] as? [String: Any] ?? [:]
        let seq = (json["seq"] as? NSNumber)?.uint64Value ?? 0
        let versionMismatch = (json["v"] as? Int) != protocolVersion
        let now = Date()

        // Resolve command replies first, in their own lock scope. The decoded
        // message below also carries the command result, but the switch treats
        // it as a no-op — resolution happens here.
        let parsedRequestID = (payload["requestID"] as? NSNumber)?.uint64Value ?? (payload["requestID"] as? UInt64) ?? (payload["requestID"] as? Int).map(UInt64.init)
        if type == "commandResult", let requestID = parsedRequestID {
            let ok = payload["ok"] as? Bool ?? false
            let errorMsg = payload["error"] as? String ?? ""
            lock.withLock { registry in
                if let cmd = registry.pendingCommands.removeValue(forKey: requestID) {
                    cmd.waiter.fulfill(ok)
                    if let tabID = cmd.tabID {
                        let isNoTab = !ok && (errorMsg.contains("No tab with id") || errorMsg.contains("not found"))
                        let isClose = cmd.commandType == "closeTab"
                        if isClose || isNoTab {
                            for key in registry.connections.keys {
                                registry.connections[key]?.tabs.removeValue(forKey: tabID)
                                registry.connections[key]?.activationTimes.removeValue(forKey: tabID)
                            }
                        }
                    }
                }
            }
        }

        // Parse fully into Sendable values before entering the lock — the lock
        // body is @Sendable and cannot capture non-Sendable [String: Any].
        let message = Self.decodeInboundMessage(type: type, payload: payload, now: now)

        let (connectionChanged, activation, removed, upserted, snapshot) = lock.withLock { registry -> (Bool, (appName: String, tabID: Int, url: String, at: Date)?, (appName: String, tabID: Int, url: String?)?, (appName: String, tab: ExtensionTabRecord)?, (appName: String, tabs: [ExtensionTabRecord])?) in
            guard var connection = registry.connections[fd] else { return (false, nil, nil, nil, nil) }

            connection.lastContactAt = now

            if versionMismatch {
                connection.isProtocolMismatch = true
            } else if Self.shouldRequestResnapshot(lastSeq: connection.lastSeq, incomingSeq: seq, type: type) {
                // Missed a delta → ask for a fresh snapshot rather than patching blind.
                connection.outboundQueue.append(Self.encode([
                    "v": protocolVersion, "type": "resnapshot", "seq": 0, "payload": [:]
                ]))
                connection.outboundSignal.signal()
            }
            if seq > 0 { connection.lastSeq = max(connection.lastSeq, seq) }

            var connectionAddedOrNamed = false
            var activationEvent: (appName: String, tabID: Int, url: String, at: Date)?
            var removedEvent: (appName: String, tabID: Int, url: String?)?
            var upsertedEvent: (appName: String, tab: ExtensionTabRecord)?
            var snapshotEvent: (appName: String, tabs: [ExtensionTabRecord])?
            switch message {
            case .hello(let appName, let extensionVersion):
                connection.appName = appName
                connection.extensionVersion = extensionVersion
                connection.isProtocolMismatch = connection.isProtocolMismatch || versionMismatch
                connectionAddedOrNamed = true

            case .snapshot(let tabs):
                Self.applySnapshot(&connection, tabs: tabs)
                snapshotEvent = (appName: connection.appName, tabs: tabs)

            case .tabUpsert(let tab):
                // Evict any stale predecessor in the same window sharing the canonical URL
                // if the existing tab is discarded or this is a newer/active tab
                let canonical = MyOrderReconciler.canonicalURL(tab.url)
                for (oldID, oldTab) in connection.tabs {
                    if oldID != tab.tabID && oldTab.windowIndex == tab.windowIndex && MyOrderReconciler.canonicalURL(oldTab.url) == canonical {
                        if oldTab.isDiscarded || (!tab.isDiscarded && oldID < tab.tabID) {
                            connection.tabs.removeValue(forKey: oldID)
                            connection.activationTimes.removeValue(forKey: oldID)
                        }
                    }
                }
                connection.tabs[tab.tabID] = tab
                if let lastAccessed = tab.lastAccessed {
                    connection.activationTimes[tab.tabID] = lastAccessed
                }
                upsertedEvent = (appName: connection.appName, tab: tab)

            case .tabRemoved(let tabID):
                let removedURL = connection.tabs[tabID]?.url
                connection.tabs.removeValue(forKey: tabID)
                connection.activationTimes.removeValue(forKey: tabID)
                removedEvent = (appName: connection.appName, tabID: tabID, url: removedURL)

            case .tabActivated(let tabID, let at):
                connection.activationTimes[tabID] = at
                activationEvent = Self.activationEvent(appName: connection.appName, tabs: connection.tabs, tabID: tabID, at: at)

            case .commandResult, .contactOnly, .ignore:
                break
            }

            registry.connections[fd] = connection
            return (connectionAddedOrNamed, activationEvent, removedEvent, upsertedEvent, snapshotEvent)
        }

        if connectionChanged {
            publishStatus()
        }
        if let activation, let onTabActivated {
            onTabActivated(activation.appName, activation.tabID, activation.url, activation.at)
        }
        if let removed, let onTabRemoved {
            onTabRemoved(removed.appName, removed.tabID, removed.url)
        }
        if let upserted, let onTabUpserted {
            onTabUpserted(upserted.appName, upserted.tab)
        }
        if let snapshot, let onSnapshotReceived {
            onSnapshotReceived(snapshot.appName, snapshot.tabs)
        }
    }


    /// Decoded form of an inbound message; all fields Sendable so it can cross
    /// into the bridge lock. Parsing happens outside the lock.
    enum InboundMessage: Sendable {
        case hello(appName: String, extensionVersion: String)
        case snapshot(tabs: [ExtensionTabRecord])
        case tabUpsert(ExtensionTabRecord)
        case tabRemoved(Int)
        case tabActivated(tabID: Int, at: Date)
        case commandResult(requestID: UInt64, ok: Bool)
        case contactOnly
        case ignore
    }

    /// True when `incomingSeq` proves a delta was missed and a fresh snapshot
    /// should be requested. Snapshots/hellos reset the sequence and responses
    /// carry seq 0, so none of those can signal a gap.
    static func shouldRequestResnapshot(lastSeq: UInt64, incomingSeq: UInt64, type: String) -> Bool {
        guard incomingSeq > 0 else { return false }
        guard lastSeq > 0 else { return false }
        guard incomingSeq != lastSeq + 1 else { return false }
        return !["hello", "snapshot", "commandResult", "pong"].contains(type)
    }

    static func decodeInboundMessage(type: String, payload: [String: Any], now: Date) -> InboundMessage {
        switch type {
        case "hello":
            let appRaw = payload["app"] as? String ?? ""
            let appName = ChromiumBrowserSpec.all.first(where: { $0.source.rawValue == appRaw })?.appName ?? ""
            return .hello(appName: appName, extensionVersion: payload["extensionVersion"] as? String ?? "")

        case "snapshot":
            var tabs: [ExtensionTabRecord] = []
            if let tabDicts = payload["tabs"] as? [[String: Any]] {
                for dict in tabDicts {
                    if let tab = decodeTab(dict) {
                        tabs.append(tab)
                    }
                }
            }
            return .snapshot(tabs: tabs)

        case "tabCreated", "tabUpdated", "tabMoved":
            if let tab = decodeTab(payload["tab"] as? [String: Any]) {
                return .tabUpsert(tab)
            }
            return .ignore

        case "tabRemoved":
            if let tabID = payload["tabId"] as? Int {
                return .tabRemoved(tabID)
            }
            return .ignore

        case "tabActivated":
            if let tabID = payload["tabId"] as? Int {
                return .tabActivated(tabID: tabID, at: date(fromEpochMS: payload["at"]) ?? now)
            }
            return .ignore

        case "commandResult":
            let parsedRequestID = (payload["requestID"] as? NSNumber)?.uint64Value ?? (payload["requestID"] as? UInt64) ?? (payload["requestID"] as? Int).map(UInt64.init)
            if let requestID = parsedRequestID {
                return .commandResult(requestID: requestID, ok: payload["ok"] as? Bool ?? false)
            }
            return .ignore

        default:
            return .contactOnly // pong, windowFocusChanged, tabGroupUpdated
        }
    }

    private func sendPings() {
        let ping = Self.encode(["v": protocolVersion, "type": "ping", "seq": 0, "payload": [:]])
        lock.withLock { registry in
            for fd in registry.connections.keys {
                guard var connection = registry.connections[fd] else { continue }
                connection.outboundQueue.append(ping)
                connection.outboundSignal.signal()
                registry.connections[fd] = connection
            }
        }
    }

    private func publishStatus() {
        let snapshot = lock.withLock { registry -> [ExtensionConnectionStatus] in
            var byName: [String: ConnectionState] = [:]
            for connection in registry.connections.values where byName[connection.appName] == nil {
                byName[connection.appName] = connection
            }
            return ChromiumBrowserSpec.all.map { spec in
                let connection = byName[spec.appName]
                return ExtensionConnectionStatus(
                    appName: spec.appName,
                    isConnected: connection != nil,
                    versionMismatch: connection?.isProtocolMismatch ?? false
                )
            }
        }
        DispatchQueue.main.async {
            self.status = snapshot
        }
    }

    // MARK: - Wire helpers (same framing as the native host: 4-byte LE length + JSON)

    static func applySnapshot(_ connection: inout ConnectionState, tabs: [ExtensionTabRecord]) {
        var newTabs: [Int: ExtensionTabRecord] = [:]
        for tab in tabs {
            newTabs[tab.tabID] = tab
            if let lastAccessed = tab.lastAccessed {
                if let existing = connection.activationTimes[tab.tabID] {
                    if lastAccessed > existing {
                        connection.activationTimes[tab.tabID] = lastAccessed
                    }
                } else {
                    connection.activationTimes[tab.tabID] = lastAccessed
                }
            }
        }
        connection.tabs = newTabs
        // Drop activation times for tabs that no longer exist.
        connection.activationTimes = connection.activationTimes.filter { newTabs[$0.key] != nil }
    }

    /// The `onTabActivated` payload for a raw activation, or nil when it's
    /// not yet usable for ranking — the connection hasn't sent `hello` yet,
    /// or the activated tab's URL isn't in the snapshot yet (a `tabActivated`
    /// that raced ahead of the tab's own `tabCreated`/`snapshot` data).
    static func activationEvent(
        appName: String,
        tabs: [Int: ExtensionTabRecord],
        tabID: Int,
        at: Date
    ) -> (appName: String, tabID: Int, url: String, at: Date)? {
        guard !appName.isEmpty, let url = tabs[tabID]?.url, !url.isEmpty else { return nil }
        return (appName, tabID, url, at)
    }

    static func decodeTab(_ dict: [String: Any]?) -> ExtensionTabRecord? {
        guard let dict else { return nil }
        guard let tabID = dict["id"] as? Int else { return nil }
        let url = dict["url"] as? String ?? ""
        guard !url.isEmpty else { return nil }
        return ExtensionTabRecord(
            tabID: tabID,
            windowIndex: dict["windowIndex"] as? Int ?? 1,
            tabIndex: dict["tabIndex"] as? Int ?? 1,
            title: dict["title"] as? String ?? "",
            url: url,
            windowName: dict["windowName"] as? String ?? "",
            isActive: dict["active"] as? Bool ?? false,
            isAudible: dict["audible"] as? Bool ?? false,
            isMuted: dict["muted"] as? Bool ?? false,
            isPinned: dict["pinned"] as? Bool ?? false,
            isDiscarded: dict["discarded"] as? Bool ?? false,
            groupTitle: dict["groupTitle"] as? String,
            lastAccessed: Self.date(fromEpochMS: dict["lastAccessed"])
        )
    }

    private static func date(fromEpochMS value: Any?) -> Date? {
        if let ms = (value as? NSNumber)?.doubleValue {
            return Date(timeIntervalSince1970: ms / 1000)
        }
        if let ms = value as? Double {
            return Date(timeIntervalSince1970: ms / 1000)
        }
        if let ms = value as? Int {
            return Date(timeIntervalSince1970: Double(ms) / 1000)
        }
        if let ms = value as? Int64 {
            return Date(timeIntervalSince1970: Double(ms) / 1000)
        }
        return nil
    }

    private static func encode(_ object: [String: Any]) -> Data {
        var frame = Data()
        if let payload = try? JSONSerialization.data(withJSONObject: object) {
            var length = UInt32(payload.count).littleEndian
            withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
            frame.append(payload)
        }
        return frame
    }

    static func readFrame(fd: Int32) -> Data? {
        var lengthBytes = [UInt8](repeating: 0, count: 4)
        let gotLength = lengthBytes.withUnsafeMutableBytes { ptr in
            readExact(fd: fd, into: ptr.baseAddress!, count: 4)
        }
        guard gotLength else { return nil }
        let length = Int(lengthBytes[0])
            | (Int(lengthBytes[1]) << 8)
            | (Int(lengthBytes[2]) << 16)
            | (Int(lengthBytes[3]) << 24)
        guard length >= 0, length <= 64 * 1024 * 1024 else { return nil }
        var payload = [UInt8](repeating: 0, count: length)
        let gotPayload = payload.withUnsafeMutableBytes { ptr in
            readExact(fd: fd, into: ptr.baseAddress!, count: length)
        }
        guard gotPayload else { return nil }
        // The socket carries Chrome's native-messaging framing (4-byte LE length
        // + JSON payload). Return only the payload — callers parse it as JSON,
        // and a stray length prefix would make JSONSerialization fail.
        return Data(payload)
    }

    private static func readExact(fd: Int32, into buffer: UnsafeMutableRawPointer, count: Int) -> Bool {
        var offset = 0
        while offset < count {
            let n = read(fd, buffer.advanced(by: offset), count - offset)
            if n <= 0 { return false }
            offset += n
        }
        return true
    }

    private static func writeAll(fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, !data.isEmpty else { return true }
            var offset = 0
            while offset < data.count {
                let n = write(fd, base.advanced(by: offset), data.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }
}
