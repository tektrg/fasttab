import Foundation
import AppKit
import OSLog
import CommandBarKit

@MainActor
final class MyOrderStore: ObservableObject {
    static let shared = MyOrderStore()

    static let slotsKey = "FastTab.myOrder.slots.v1"
    static let pendingClosesKey = "FastTab.myOrder.pendingCloses.v1"
    static let ghostExpiryDaysKey = "FastTab.myOrder.ghostExpiryDays"

    private let logger = Logger(subsystem: "com.trungluong.FastTab", category: "MyOrderStore")
    private let defaults: UserDefaults

    @Published private(set) var slots: [OrderedTabSlot] = []
    @Published var isDragging: Bool = false
    @Published var ghostExpiryDays: Int

    var tabCloser: ((BrowserSearchResult) -> Void)?
    var tabActivator: ((BrowserSearchResult) -> Void)?
    var tabReopener: ((BrowserSearchResult) -> Void)?
    var tabPinner: ((BrowserSearchResult, Bool) -> Void)?
    private var tombstoneCanceller: ((String, String) -> Void)?
    private var tabOrderSyncer: (([OrderedTabSlot]) -> Void)?

    private var pendingCloses: [PendingSlotClose] = []
    private var lastPersistAt: Date = .distantPast
    private var persistTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let savedExpiry = defaults.object(forKey: Self.ghostExpiryDaysKey) as? Int ?? 7
        self.ghostExpiryDays = savedExpiry
        self.slots = Self.loadSlots(from: defaults)
        self.partitionSlots()
        self.pendingCloses = Self.loadPendingCloses(from: defaults)
        logger.info("MyOrderStore initialized. loadedSlots=\(self.slots.count)")
    }

    func bindToService(
        closer: @escaping (BrowserSearchResult) -> Void,
        activator: @escaping (BrowserSearchResult) -> Void,
        reopener: ((BrowserSearchResult) -> Void)? = nil,
        canceller: @escaping (String, String) -> Void,
        tabOrderSyncer: (([OrderedTabSlot]) -> Void)? = nil,
        pinner: ((BrowserSearchResult, Bool) -> Void)? = nil
    ) {
        self.tabCloser = closer
        self.tabActivator = activator
        self.tabReopener = reopener ?? activator
        self.tombstoneCanceller = canceller
        self.tabOrderSyncer = tabOrderSyncer
        self.tabPinner = pinner
    }

    func setGhostExpiryDays(_ days: Int, liveTabs: [BrowserSearchResult]? = nil) {
        guard days != ghostExpiryDays else { return }
        ghostExpiryDays = days
        defaults.set(days, forKey: Self.ghostExpiryDaysKey)
        if let liveTabs {
            reconcile(liveTabs: liveTabs)
        } else {
            reconcile(liveTabs: slots.compactMap { $0.state == .live ? $0.asSearchResult : nil })
        }
    }

    func reconcile(liveTabs: [BrowserSearchResult], runningBrowsers: Set<String>? = nil) {
        guard !isDragging else {
            logger.info("MyOrderStore reconcile skipped during active drag.")
            return
        }

        let running: Set<String>
        if let runningBrowsers {
            running = runningBrowsers
        } else {
            let appNames = Set(NSWorkspace.shared.runningApplications.compactMap { $0.localizedName })
            running = appNames
        }

        let result = MyOrderReconciler.reconcile(
            currentSlots: slots,
            liveTabs: liveTabs,
            runningBrowsers: running,
            pendingCloses: pendingCloses,
            now: Date(),
            ghostExpiryDays: ghostExpiryDays
        )

        self.slots = result.slots
        self.pendingCloses = result.remainingPendingCloses
        schedulePersist()
    }

    func reorderSlot(from sourceIndex: Int, to destinationIndex: Int) {
        guard slots.indices.contains(sourceIndex), slots.indices.contains(destinationIndex), sourceIndex != destinationIndex else {
            return
        }
        let originalPinnedCount = slots.filter { $0.isPinned }.count
        var item = slots.remove(at: sourceIndex)

        // Crossing boundary between pinned and unpinned sections:
        // Pinned section occupies indices 0 ..< originalPinnedCount in the original list.
        if destinationIndex < originalPinnedCount && !item.isPinned {
            item.isPinned = true
            item.confirmedInBrowser = false
            tabPinner?(item.asSearchResult, true)
        } else if destinationIndex >= originalPinnedCount && item.isPinned {
            if item.state == .ghost {
                // Dragging a ghost tab to unpinned section permanently deletes it
                schedulePersist()
                return
            }
            item.isPinned = false
            item.confirmedInBrowser = false
            tabPinner?(item.asSearchResult, false)
        }

        slots.insert(item, at: destinationIndex)
        partitionSlots()
        schedulePersist()
    }

    func closeSlot(_ slotID: UUID) {
        guard let index = slots.firstIndex(where: { $0.slotID == slotID }) else { return }
        let slot = slots[index]

        if slot.state == .ghost {
            // Second close -> permanently delete
            slots.remove(at: index)
            schedulePersist()
            return
        }

        if slot.isPinned {
            // Pinned tab close: record intent and leave a ghost
            let intent = PendingSlotClose(
                slotID: slot.slotID,
                browserName: slot.browserName,
                url: slot.url,
                tabID: slot.boundTabID,
                createdAt: Date()
            )
            pendingCloses.append(intent)

            var updated = slot
            updated.state = .ghost
            updated.ghostedAt = Date()
            updated.boundTabID = nil
            slots[index] = updated

            tabCloser?(slot.asSearchResult)
            schedulePersist()
        } else {
            // Unpinned tab: ghost effects only apply for pinned tabs -> vanishes
            slots.remove(at: index)
            tabCloser?(slot.asSearchResult)
            schedulePersist()
        }
    }

    func reopenSlot(_ slotID: UUID) {
        guard let index = slots.firstIndex(where: { $0.slotID == slotID }) else { return }
        let slot = slots[index]

        pendingCloses.removeAll { $0.slotID == slotID || ($0.browserName == slot.browserName && MyOrderReconciler.urlsMatch($0.url, slot.url)) }
        tombstoneCanceller?(slot.browserName, slot.url)
        tabReopener?(slot.asSearchResult)

        // Optimistically mark live
        var updated = slot
        updated.state = .live
        updated.ghostedAt = nil
        slots[index] = updated
        schedulePersist()
    }

    func reopenSlot(matching result: BrowserSearchResult) {
        if let index = slots.firstIndex(where: { Self.matchesSlot($0, browserName: result.browserName, url: result.url, tabID: result.tabID) }) {
            reopenSlot(slots[index].slotID)
        } else {
            tombstoneCanceller?(result.browserName, result.url)
            tabReopener?(result)
        }
    }

    func deleteGhostSlot(matching result: BrowserSearchResult) {
        if let index = slots.firstIndex(where: { Self.matchesSlot($0, browserName: result.browserName, url: result.url, tabID: result.tabID) }) {
            let slot = slots[index]
            if slot.state == .ghost {
                slots.remove(at: index)
                schedulePersist()
            }
        }
    }

    func togglePinSlot(_ slotID: UUID) {
        guard let index = slots.firstIndex(where: { $0.slotID == slotID }) else { return }
        let slot = slots[index]
        let targetPinned = !slot.isPinned

        if slot.state == .ghost && !targetPinned {
            // Unpinning a ghost permanently deletes it
            slots.remove(at: index)
            schedulePersist()
            return
        }

        var updated = slot
        updated.isPinned = targetPinned
        if !targetPinned {
            updated.confirmedInBrowser = false
        }
        slots[index] = updated
        partitionSlots()

        tabPinner?(slot.asSearchResult, targetPinned)
        schedulePersist()
    }

    nonisolated static func matchesSlot(_ slot: OrderedTabSlot, browserName: String, url: String, tabID: Int?) -> Bool {
        guard slot.browserName == browserName else { return false }
        if let tabID, let slotTabID = slot.boundTabID {
            return slotTabID == tabID
        }
        return MyOrderReconciler.urlsMatch(url, slot.url) || MyOrderReconciler.urlsMatch(url, slot.matchKey)
    }

    func setSlotPinned(browserName: String, url: String, tabID: Int?, isPinned: Bool) {
        let matchingIndex = slots.firstIndex(where: {
            guard $0.browserName == browserName else { return false }
            if let tabID, let slotTabID = $0.boundTabID, slotTabID == tabID { return true }
            return false
        }) ?? slots.firstIndex(where: {
            guard $0.browserName == browserName else { return false }
            return MyOrderReconciler.urlsMatch(url, $0.url) || MyOrderReconciler.urlsMatch(url, $0.matchKey)
        })

        if let index = matchingIndex {
            let slot = slots[index]
            var updated = slot
            if let tabID, slot.boundTabID != tabID {
                updated.boundTabID = tabID
            }

            if slot.isPinned != isPinned {
                if slot.state == .ghost && !isPinned {
                    slots.remove(at: index)
                    schedulePersist()
                    return
                }
                updated.isPinned = isPinned
                if !isPinned {
                    updated.confirmedInBrowser = false
                }
            }
            slots[index] = updated
            partitionSlots()
            schedulePersist()
        } else if isPinned {
            // Tab was pinned from outside existing slots (e.g. search results).
            // Create a new slot in the pinned section so it persists internally.
            let newSlot = OrderedTabSlot(
                slotID: UUID(),
                url: url,
                matchKey: Frecency.normalizeURL(url),
                title: url,
                browserName: browserName,
                profileName: nil,
                state: .live,
                boundTabID: tabID,
                windowIndex: nil,
                tabIndex: nil,
                ghostedAt: nil,
                lastSeenLiveAt: Date(),
                isPinned: true,
                confirmedInBrowser: false
            )
            slots.insert(newSlot, at: 0)
            partitionSlots()
            schedulePersist()
        }
    }

    /// Checks whether an open tab has an active pinned slot in FastTab.
    func isSlotPinned(browserName: String, url: String, tabID: Int?) -> Bool {
        if let tabID, let slot = slots.first(where: { $0.browserName == browserName && $0.boundTabID == tabID }) {
            return slot.isPinned
        }
        guard let slot = slots.first(where: { Self.matchesSlot($0, browserName: browserName, url: url, tabID: tabID) }) else { return false }
        return slot.isPinned
    }

    /// Overlays FastTab's internal pin state onto a list of live browser search results.
    /// FastTab slots are authoritative for pin status; untracked tabs fall back to their browser pin status.
    func overlayPinStatus(on tabs: [BrowserSearchResult]) -> [BrowserSearchResult] {
        Self.overlayPinStatus(on: tabs, using: slots)
    }

    /// Pure helper that overlays FastTab's internal pin state using a given slots snapshot.
    /// Safe to call from background / nonisolated tasks.
    nonisolated static func overlayPinStatus(on tabs: [BrowserSearchResult], using slots: [OrderedTabSlot]) -> [BrowserSearchResult] {
        guard !slots.isEmpty else { return tabs }
        return tabs.map { tab in
            guard tab.type == .tab else { return tab }
            let pinned: Bool
            if let slot = slots.first(where: { matchesSlot($0, browserName: tab.browserName, url: tab.url, tabID: tab.tabID) }) {
                if slot.isPinned {
                    pinned = true
                } else if !slot.confirmedInBrowser {
                    // Explicitly unpinned in FastTab, waiting for browser to confirm
                    pinned = false
                } else {
                    pinned = tab.isPinned
                }
            } else {
                pinned = tab.isPinned
            }
            return pinned != tab.isPinned ? tab.settingPinned(pinned) : tab
        }
    }

    private func partitionSlots() {
        slots = MyOrderReconciler.deduplicatePinnedSlots(slots)
        let pinned = slots.filter { $0.isPinned }
        let unpinned = slots.filter { !$0.isPinned }
        slots = pinned + unpinned
    }

    func recordRemoteClose(browserName: String, url: String, tabID: Int?) {
        if let index = slots.firstIndex(where: { Self.matchesSlot($0, browserName: browserName, url: url, tabID: tabID) }) {
            let slot = slots[index]
            if slot.isPinned {
                let intent = PendingSlotClose(
                    slotID: slot.slotID,
                    browserName: slot.browserName,
                    url: slot.url,
                    tabID: slot.boundTabID,
                    createdAt: Date()
                )
                pendingCloses.append(intent)
                var updated = slot
                updated.state = .ghost
                updated.ghostedAt = Date()
                updated.boundTabID = nil
                slots[index] = updated
                schedulePersist()
            } else {
                slots.remove(at: index)
                schedulePersist()
            }
        }
    }

    func flush() {
        persistTask?.cancel()
        persistTask = nil
        persistNow()
    }

    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.persistNow()
        }
    }

    private func persistNow() {
        if let data = try? JSONEncoder().encode(slots) {
            defaults.set(data, forKey: Self.slotsKey)
        }
        if let closeData = try? JSONEncoder().encode(pendingCloses) {
            defaults.set(closeData, forKey: Self.pendingClosesKey)
        }
        lastPersistAt = Date()
        tabOrderSyncer?(slots)
    }

    private static func loadSlots(from defaults: UserDefaults) -> [OrderedTabSlot] {
        guard let data = defaults.data(forKey: slotsKey),
              let decoded = try? JSONDecoder().decode([OrderedTabSlot].self, from: data) else {
            return []
        }
        return MyOrderReconciler.deduplicateSlots(decoded)
    }

    private static func loadPendingCloses(from defaults: UserDefaults) -> [PendingSlotClose] {
        guard let data = defaults.data(forKey: pendingClosesKey),
              let decoded = try? JSONDecoder().decode([PendingSlotClose].self, from: data) else {
            return []
        }
        let now = Date()
        return decoded.filter { !$0.isExpired(at: now) }
    }
}
