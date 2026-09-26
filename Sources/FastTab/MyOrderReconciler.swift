import Foundation
import CommandBarKit

struct PendingSlotClose: Codable, Equatable, Sendable {
    let slotID: UUID
    let browserName: String
    let url: String
    let tabID: Int?
    let createdAt: Date

    init(slotID: UUID, browserName: String, url: String, tabID: Int? = nil, createdAt: Date = Date()) {
        self.slotID = slotID
        self.browserName = browserName
        self.url = url
        self.tabID = tabID
        self.createdAt = createdAt
    }

    func isExpired(at now: Date = Date(), ttl: TimeInterval = 60) -> Bool {
        now.timeIntervalSince(createdAt) > ttl
    }
}

enum MyOrderReconciler {
    /// Two (or more) live slots claiming the same page in the same browser
    /// and profile under different tab IDs. One of them is normally a phantom
    /// twin (stale pre-replacement ID the extension mirror kept next to the
    /// live one); legit same-URL duplicates (two SPA views, two profiles)
    /// are separated by the profile scope and by the browser-side verify step,
    /// never collapsed blindly.
    struct TwinSuspect: Sendable, Equatable {
        let browserName: String
        let canonicalURL: String
        /// Distinct bound tab IDs claiming the page, ascending (oldest first —
        /// the audit verifies the older twins before the newest).
        let tabIDs: [Int]
    }

    /// Finds live slots that need a browser-side existence check: same
    /// browser + profile + canonical URL, distinct bound tab IDs. Pure so the
    /// audit trigger stays testable without IPC.
    static func findTwinSuspects(in slots: [OrderedTabSlot]) -> [TwinSuspect] {
        var idsByKey: [String: (browser: String, canonical: String, ids: Set<Int>)] = [:]
        for slot in slots {
            guard slot.state == .live, let tabID = slot.boundTabID else { continue }
            let canonical = canonicalURL(slot.url)
            guard !canonical.isEmpty else { continue }
            let key = "\(slot.browserName)|\(slot.profileName ?? "")|\(canonical)"
            if idsByKey[key] == nil {
                idsByKey[key] = (slot.browserName, canonical, [])
            }
            idsByKey[key]?.ids.insert(tabID)
        }
        return idsByKey.values
            .filter { $0.ids.count > 1 }
            .map { TwinSuspect(browserName: $0.browser, canonicalURL: $0.canonical, tabIDs: $0.ids.sorted()) }
            .sorted { $0.browserName < $1.browserName }
    }

    static func canonicalURL(_ url: String) -> String {
        var norm = Frecency.normalizeURL(url)
        while norm.count > 1 && norm.hasSuffix("/") {
            norm.removeLast()
        }
        if let r = norm.range(of: "://") {
            norm = String(norm[r.upperBound...])
        }
        return norm
    }

    /// Robust matching between two URLs: handles canonical root trailing slash differences
    /// and HTTP -> HTTPS redirects while preserving distinct paths and queries.
    static func urlsMatch(_ url1: String, _ url2: String) -> Bool {
        if url1 == url2 { return true }
        let c1 = canonicalURL(url1)
        let c2 = canonicalURL(url2)
        return !c1.isEmpty && c1 == c2
    }

    /// Reusable helper for Phase 6 (live-aware bookmark rows) and general matching.
    /// Finds whether an open tab matches the given URL, profile, and browser.
    static func findMatchingLiveTab(
        url: String,
        profileName: String? = nil,
        browserName: String? = nil,
        in liveTabs: [BrowserSearchResult]
    ) -> BrowserSearchResult? {
        return liveTabs.first { tab in
            guard tab.type == .tab else { return false }
            if let browserName, !browserName.isEmpty, tab.browserName != browserName {
                return false
            }
            if let profileName, !profileName.isEmpty, let tabProf = tab.profileName, !tabProf.isEmpty, tabProf != profileName {
                return false
            }
            return urlsMatch(tab.url, url)
        }
    }

    /// Deduplicates pinned slots sharing the same canonical URL within a browser/profile.
    /// Preserves unpinned slots, and for pinned duplicates keeps the highest fidelity slot (live > ghost, recent lastSeenLiveAt).
    static func deduplicatePinnedSlots(_ slots: [OrderedTabSlot]) -> [OrderedTabSlot] {
        var bestByKey: [String: OrderedTabSlot] = [:]
        var slotOrder: [String] = []
        var unpinnedSlots: [OrderedTabSlot] = []

        for slot in slots {
            guard slot.isPinned else {
                unpinnedSlots.append(slot)
                continue
            }
            let key = "\(slot.browserName)|\(slot.profileName ?? "")|\(canonicalURL(slot.url))"
            if let existing = bestByKey[key] {
                let isExistingLive = existing.state == .live
                let isNewLive = slot.state == .live
                if !isExistingLive && isNewLive {
                    bestByKey[key] = slot
                } else if isExistingLive == isNewLive {
                    let existingDate = existing.lastSeenLiveAt ?? .distantPast
                    let newDate = slot.lastSeenLiveAt ?? .distantPast
                    if newDate > existingDate {
                        bestByKey[key] = slot
                    }
                }
            } else {
                bestByKey[key] = slot
                slotOrder.append(key)
            }
        }

        let pinned = slotOrder.compactMap { bestByKey[$0] }
        return pinned + unpinnedSlots
    }

    /// Deduplicates slots:
    /// 1. At most one pinned slot per canonical URL within a browser/profile.
    /// 2. If a pinned slot exists for a canonical URL, drops duplicate unpinned slots for that URL.
    /// 3. Drops duplicate unpinned slots sharing the same boundTabID.
    /// 4. Within a window, collapses duplicate unpinned slots sharing the same canonical URL,
    ///    preferring live slots, newer boundTabIDs, or more recently seen live slots.
    /// 5. For unpinned ghosts without boundTabID, allows at most one ghost slot per canonical URL.
    static func deduplicateSlots(_ slots: [OrderedTabSlot]) -> [OrderedTabSlot] {
        let pinnedDeduplicated = deduplicatePinnedSlots(slots)
        let pinnedKeys = Set(pinnedDeduplicated.filter { $0.isPinned }.map {
            "\($0.browserName)|\($0.profileName ?? "")|\(canonicalURL($0.url))"
        })

        var seenBoundTabIDs = Set<Int>()
        var seenGhostKeys = Set<String>()
        var bestUnpinnedIndexByKey: [String: Int] = [:]
        var cleanedSlots: [OrderedTabSlot] = []
        cleanedSlots.reserveCapacity(pinnedDeduplicated.count)

        for slot in pinnedDeduplicated {
            if slot.isPinned {
                if let tabID = slot.boundTabID {
                    seenBoundTabIDs.insert(tabID)
                }
                cleanedSlots.append(slot)
            } else {
                let canonical = canonicalURL(slot.url)
                let baseKey = "\(slot.browserName)|\(slot.profileName ?? "")|\(canonical)"
                if pinnedKeys.contains(baseKey) {
                    continue
                }
                if let tabID = slot.boundTabID {
                    if !seenBoundTabIDs.insert(tabID).inserted {
                        continue
                    }
                }
                if slot.state == .ghost {
                    if !seenGhostKeys.insert(baseKey).inserted {
                        continue
                    }
                }
                if let win = slot.windowIndex {
                    let titleKey = foldForMatching(strippingLeadingCountBadge(slot.title))
                    let windowKey = "\(slot.browserName)|\(slot.profileName ?? "")|\(win)|\(canonical)|\(titleKey)"
                    if let existingIdx = bestUnpinnedIndexByKey[windowKey] {
                        let existing = cleanedSlots[existingIdx]
                        let candidateIsBetter: Bool
                        if existing.state != .live && slot.state == .live {
                            candidateIsBetter = true
                        } else if existing.state == .live && slot.state != .live {
                            candidateIsBetter = false
                        } else if let tabID2 = slot.boundTabID, let tabID1 = existing.boundTabID, tabID2 != tabID1 {
                            candidateIsBetter = tabID2 > tabID1
                        } else {
                            let d1 = existing.lastSeenLiveAt ?? .distantPast
                            let d2 = slot.lastSeenLiveAt ?? .distantPast
                            candidateIsBetter = d2 > d1
                        }
                        if candidateIsBetter {
                            cleanedSlots[existingIdx] = slot
                        }
                        continue
                    } else {
                        bestUnpinnedIndexByKey[windowKey] = cleanedSlots.count
                    }
                }
                cleanedSlots.append(slot)
            }
        }
        return cleanedSlots
    }

    /// Pure reconciliation function.
    static func reconcile(
        currentSlots: [OrderedTabSlot],
        liveTabs: [BrowserSearchResult],
        runningBrowsers: Set<String>,
        pendingCloses: [PendingSlotClose],
        now: Date = Date(),
        maxSlots: Int = 500,
        maxGhosts: Int = 200,
        ghostExpiryDays: Int = 7
    ) -> (slots: [OrderedTabSlot], remainingPendingCloses: [PendingSlotClose]) {
        let dedupedCurrentSlots = deduplicateSlots(currentSlots)
        var unconsumedCloses = pendingCloses.filter { !$0.isExpired(at: now) }
        let availableLiveTabs = liveTabs.filter { $0.type == .tab && !$0.isGhost }

        // Track which live tabs by unique index in availableLiveTabs are bound
        var usedLiveIndices = Set<Int>()

        // Helper to bind a live tab to a slot
        func bind(tabIndex: Int, to slot: inout OrderedTabSlot) {
            let tab = availableLiveTabs[tabIndex]
            usedLiveIndices.insert(tabIndex)
            slot.url = tab.url
            slot.matchKey = Frecency.normalizeURL(tab.url)
            slot.title = tab.title
            slot.browserName = tab.browserName
            // Profile is only known on some paths (AppleScript window-title
            // parse); the extension snapshot reports nil. Never wipe a known
            // profile with an unknown one, or ghost reopen loses its target.
            if let prof = tab.profileName, !prof.isEmpty {
                slot.profileName = prof
            }
            slot.state = .live
            if let tabID = tab.tabID {
                slot.boundTabID = tabID
            }
            slot.windowIndex = tab.windowIndex
            slot.tabIndex = tab.tabIndex
            slot.lastSeenLiveAt = now
            slot.ghostedAt = nil
            // Pin state is 100% app-owned:
            // FastTab manages slot pinning independently. Live tab browser polls
            // (AppleScript, Chrome extension, Safari) never clear or unpin an existing slot.
            if tab.isPinned {
                slot.isPinned = true
                slot.confirmedInBrowser = true
            } else if !slot.isPinned {
                slot.confirmedInBrowser = true
            }
        }

        // Count live tabs per browser for Rung 3 qualification
        var liveCountByBrowser: [String: Int] = [:]
        for tab in availableLiveTabs {
            liveCountByBrowser[tab.browserName, default: 0] += 1
        }
        var currentSlotCountByBrowser: [String: Int] = [:]
        for slot in dedupedCurrentSlots where slot.state != .ghost {
            currentSlotCountByBrowser[slot.browserName, default: 0] += 1
        }

        var reconciledSlots: [OrderedTabSlot?] = Array(repeating: nil, count: dedupedCurrentSlots.count)

        // PASS 1: Bind existing LIVE slots first (so live slots don't lose their tabs to ghosts)
        for i in 0..<dedupedCurrentSlots.count {
            var slot = dedupedCurrentSlots[i]
            guard slot.state != .ghost else { continue }

            let browserRunning = runningBrowsers.contains(slot.browserName)
            if !browserRunning {
                // Quitting a browser freezes its slots
                slot.state = .browserFrozen
                reconciledSlots[i] = slot
                continue
            }

            // Ladder matching for live slot:
            if let matchedIndex = matchTab(for: slot, in: availableLiveTabs, usedIndices: usedLiveIndices, liveCountByBrowser: liveCountByBrowser, currentSlotCountByBrowser: currentSlotCountByBrowser) {
                bind(tabIndex: matchedIndex, to: &slot)
                reconciledSlots[i] = slot
            } else {
                // Slot was live, but tab is no longer present.
                // Consume pending close intent if present
                if let closeIdx = unconsumedCloses.firstIndex(where: { close in
                    close.slotID == slot.slotID ||
                    (close.browserName == slot.browserName && (close.tabID != nil && close.tabID == slot.boundTabID || urlsMatch(close.url, slot.url)))
                }) {
                    unconsumedCloses.remove(at: closeIdx)
                }

                // Ghost effects ONLY apply for pinned tabs!
                if slot.isPinned {
                    slot.state = .ghost
                    slot.ghostedAt = now
                    slot.boundTabID = nil
                    reconciledSlots[i] = slot
                } else {
                    // Unpinned tab closed -> vanishes
                    reconciledSlots[i] = nil
                }
            }
        }

        // PASS 2: Revive GHOST slots before appending new tabs (keeps reopened tabs at original positions)
        for i in 0..<dedupedCurrentSlots.count {
            guard reconciledSlots[i] == nil, dedupedCurrentSlots[i].state == .ghost else { continue }
            var slot = dedupedCurrentSlots[i]

            // Check if matching live tab appeared (e.g. reopened)
            if let matchedIndex = matchTab(for: slot, in: availableLiveTabs, usedIndices: usedLiveIndices, liveCountByBrowser: liveCountByBrowser, currentSlotCountByBrowser: currentSlotCountByBrowser) {
                let matchedTab = availableLiveTabs[matchedIndex]

                // Guard: If this matched tab is currently pending close (e.g. dying phantom tab in flight),
                // do NOT revive the ghost with it.
                let isDyingTab = unconsumedCloses.contains(where: { close in
                    guard close.browserName == matchedTab.browserName else { return false }
                    if let closeTabID = close.tabID, let matchedTabID = matchedTab.tabID {
                        return closeTabID == matchedTabID
                    }
                    return (close.slotID == slot.slotID || close.tabID == nil || matchedTab.tabID == nil) &&
                           (urlsMatch(close.url, matchedTab.url) || urlsMatch(close.url, slot.url))
                })

                if isDyingTab {
                    usedLiveIndices.insert(matchedIndex)
                    slot.isPinned = true
                    reconciledSlots[i] = slot
                    continue
                }

                bind(tabIndex: matchedIndex, to: &slot)
                // Pinned ghost tabs that revive stay pinned in FastTab
                slot.isPinned = dedupedCurrentSlots[i].isPinned
                reconciledSlots[i] = slot
            } else {
                // Still a ghost: check expiry
                if ghostExpiryDays > 0, let ghostedAt = slot.ghostedAt, now.timeIntervalSince(ghostedAt) > Double(ghostExpiryDays) * 86400 {
                    // Expired
                    reconciledSlots[i] = nil
                } else {
                    if let closeIdx = unconsumedCloses.firstIndex(where: { close in
                        close.slotID == slot.slotID ||
                        (close.browserName == slot.browserName && (close.tabID != nil && close.tabID == slot.boundTabID || urlsMatch(close.url, slot.url)))
                    }) {
                        unconsumedCloses.remove(at: closeIdx)
                    }
                    slot.isPinned = true
                    reconciledSlots[i] = slot
                }
            }
        }

        // Collect remaining surviving slots
        var finalSlots: [OrderedTabSlot] = reconciledSlots.compactMap { $0 }

        // PASS 3: Append new tabs that weren't bound to any slot
        for (index, tab) in availableLiveTabs.enumerated() {
            guard !usedLiveIndices.contains(index) else { continue }
            let tabCanonical = canonicalURL(tab.url)
            let browser = tab.browserName

            // Never append a duplicate unpinned slot if this URL is already represented as pinned
            let alreadyHasPinnedSlot = finalSlots.contains(where: { $0.isPinned && $0.browserName == browser && canonicalURL($0.url) == tabCanonical })
            if alreadyHasPinnedSlot {
                continue
            }

            // If a slot with this exact tabID already exists, don't append a duplicate
            if let tabID = tab.tabID, finalSlots.contains(where: { $0.browserName == browser && $0.boundTabID == tabID }) {
                continue
            }

            // For tabs without tabID (e.g. AppleScript polls), prevent duplicate slots for same canonical URL in same window
            let win = tab.windowIndex ?? 1
            if tab.tabID == nil && finalSlots.contains(where: {
                $0.browserName == browser && ($0.windowIndex ?? 1) == win && canonicalURL($0.url) == tabCanonical
            }) {
                continue
            }

            let isPinned = tab.isPinned
            let newSlot = OrderedTabSlot(
                slotID: UUID(),
                url: tab.url,
                matchKey: Frecency.normalizeURL(tab.url),
                title: tab.title,
                browserName: tab.browserName,
                profileName: tab.profileName,
                state: .live,
                boundTabID: tab.tabID,
                windowIndex: tab.windowIndex,
                tabIndex: tab.tabIndex,
                ghostedAt: nil,
                lastSeenLiveAt: now,
                isPinned: isPinned,
                confirmedInBrowser: isPinned
            )
            finalSlots.append(newSlot)
        }

        // Deduplicate slots across finalSlots (guarantees at most 1 pinned slot per canonical URL, and no duplicate slots in same window)
        finalSlots = deduplicateSlots(finalSlots)


        // Pinned tabs are always partitioned to the front of the slot list
        // (the Stack view shows this pinned prefix as its top section)
        let pinnedSlots = finalSlots.filter { $0.isPinned }
        let unpinnedSlots = finalSlots.filter { !$0.isPinned }
        finalSlots = pinnedSlots + unpinnedSlots

        // Enforce ghost cap (oldest ghosts dropped first)
        let ghostIndices = finalSlots.indices.filter { finalSlots[$0].state == .ghost }
        if ghostIndices.count > maxGhosts {
            let sortedGhostIndices = ghostIndices.sorted {
                let d1 = finalSlots[$0].ghostedAt ?? .distantPast
                let d2 = finalSlots[$1].ghostedAt ?? .distantPast
                return d1 < d2
            }
            let excessCount = ghostIndices.count - maxGhosts
            let toRemove = Set(sortedGhostIndices.prefix(excessCount))
            finalSlots = finalSlots.indices.filter { !toRemove.contains($0) }.map { finalSlots[$0] }
        }

        // Enforce total slots cap
        if finalSlots.count > maxSlots {
            finalSlots = Array(finalSlots.prefix(maxSlots))
        }

        return (slots: finalSlots, remainingPendingCloses: unconsumedCloses)
    }

    private static func matchTab(
        for slot: OrderedTabSlot,
        in liveTabs: [BrowserSearchResult],
        usedIndices: Set<Int>,
        liveCountByBrowser: [String: Int],
        currentSlotCountByBrowser: [String: Int]
    ) -> Int? {
        // Rung 1: Browser + stable tab ID, cross-checked against the slot URL.
        // A bare ID match is not trusted on its own: Chromium reuses tab IDs
        // after closes/replacements, and a stale extension record can keep a
        // retired ID alive next to the live one. When the ID-matched tab's URL
        // no longer matches the slot, fall through to Rung 2 so the slot
        // re-binds ("updates") to the correct tab instead of latching onto a
        // phantom or an unrelated tab that recycled the ID.
        if let boundID = slot.boundTabID {
            if let idx = liveTabs.indices.first(where: { !usedIndices.contains($0) && liveTabs[$0].browserName == slot.browserName && liveTabs[$0].tabID == boundID }) {
                let tab = liveTabs[idx]
                if urlsMatch(tab.url, slot.url) || urlsMatch(tab.url, slot.matchKey) {
                    return idx
                }
            }
        }

        // Rung 2: Browser + profile + normalized URL, consume-one in slot order
        if let idx = liveTabs.indices.first(where: { i in
            guard !usedIndices.contains(i) else { return false }
            let tab = liveTabs[i]
            guard tab.browserName == slot.browserName else { return false }
            if let slotProf = slot.profileName, !slotProf.isEmpty, let tabProf = tab.profileName, !tabProf.isEmpty, slotProf != tabProf {
                return false
            }
            return urlsMatch(tab.url, slot.url) || urlsMatch(tab.url, slot.matchKey)
        }) {
            return idx
        }

        // Rung 3: Window + tab position, ONLY when browser tab count is unchanged
        let liveCount = liveCountByBrowser[slot.browserName] ?? 0
        let slotCount = currentSlotCountByBrowser[slot.browserName] ?? 0
        if liveCount > 0, liveCount == slotCount, let win = slot.windowIndex, let tabPos = slot.tabIndex {
            if let idx = liveTabs.indices.first(where: { !usedIndices.contains($0) && liveTabs[$0].browserName == slot.browserName && liveTabs[$0].windowIndex == win && liveTabs[$0].tabIndex == tabPos }) {
                return idx
            }
        }

        return nil
    }
}
