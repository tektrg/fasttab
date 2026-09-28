import WidgetKit

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

/// One provider for every widget: they all read the same snapshot file.
///
/// The app reloads timelines whenever it writes the snapshot. The only thing that changes without
/// the app is the date, so the timeline adds an entry at the next midnight (the Reading ring
/// empties) and asks for a fresh timeline after it.
struct SnapshotTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        let snapshot = WidgetSnapshotStore.load()
        completion(SnapshotEntry(date: Date(), snapshot: context.isPreview && snapshot == .empty ? .preview : snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let now = Date()
        let snapshot = WidgetSnapshotStore.load()
        let midnight = Calendar.current.nextDate(
            after: now, matching: DateComponents(hour: 0, minute: 0), matchingPolicy: .nextTime
        ) ?? now.addingTimeInterval(24 * 3600)
        completion(Timeline(
            entries: [SnapshotEntry(date: now, snapshot: snapshot), SnapshotEntry(date: midnight, snapshot: snapshot)],
            policy: .after(midnight)
        ))
    }
}
