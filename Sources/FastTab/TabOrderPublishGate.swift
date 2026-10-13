import Foundation

/// When a changed tab order goes to iCloud. A change to the list itself (order, URLs, state,
/// pins) goes at once; a change to titles alone waits until `titleOnlyInterval` has passed
/// since the last publish. Why: a tab that flashes its title (Google Chat's "X messaged you"
/// while unread) changed the order every ~2s, so the Mac saved it nonstop and CKSyncEngine,
/// always mid-send, rarely fetched — phone changes reached the Mac many minutes late.
struct TabOrderPublishGate {
    enum Decision: Equatable {
        case publishNow
        /// Titles only: publish the latest order at this time (unless something else does).
        case publishAt(Date)
    }

    static let titleOnlyInterval: TimeInterval = 30

    private(set) var lastStructure: String?
    private(set) var lastPublishedAt: Date?

    func decision(for slots: [OrderedTabSlot], now: Date) -> Decision {
        guard let lastStructure, let lastPublishedAt, Self.structure(of: slots) == lastStructure else {
            return .publishNow
        }
        let due = lastPublishedAt.addingTimeInterval(Self.titleOnlyInterval)
        return due <= now ? .publishNow : .publishAt(due)
    }

    mutating func didPublish(_ slots: [OrderedTabSlot], at date: Date) {
        lastStructure = Self.structure(of: slots)
        lastPublishedAt = date
    }

    mutating func reset() {
        lastStructure = nil
        lastPublishedAt = nil
    }

    /// Everything the phone shows except titles.
    static func structure(of slots: [OrderedTabSlot]) -> String {
        slots.map { slot in
            [slot.slotID.uuidString, slot.url, slot.matchKey, slot.browserName, slot.profileName ?? "",
             slot.state.rawValue, slot.isPinned ? "p" : "", slot.ghostedAt.map { String($0.timeIntervalSince1970) } ?? ""]
                .joined(separator: "\u{1F}")
        }
        .joined(separator: "\u{1E}")
    }
}
