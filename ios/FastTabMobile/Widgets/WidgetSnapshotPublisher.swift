import Foundation
import Combine
import OSLog
import UIKit
import WidgetKit

/// Keeps `WidgetSnapshot` on disk in step with the app and asks WidgetKit to redraw.
///
/// Sources: synced tabs (`LocalCache`), saved links (`RecentAddedProvider`), reading progress,
/// the reading log (reloaded when the recorder's writes land) and the Shuffle deck's top card
/// (pushed by `RandomLinksView`). Bursts of changes are coalesced into one write + one reload
/// (`debounceInterval`), and an unchanged snapshot is never rewritten, so a sync storm costs
/// WidgetKit's reload budget nothing.
@MainActor
final class WidgetSnapshotPublisher {
    static let shared = WidgetSnapshotPublisher()

    static let debounceInterval: TimeInterval = 1.5
    /// Longest side of the Shuffle thumbnail, in pixels: enough for a large widget, a few dozen KB.
    static let thumbnailMaxPixelSize: CGFloat = 600

    private var snapshot = WidgetSnapshotStore.load()
    private var subscriptions = Set<AnyCancellable>()
    private var pendingWrite: DispatchWorkItem?
    private var readingReload: Task<Void, Never>?
    private var hasStarted = false
    private let calendar = Calendar.current
    private let logger = Logger(subsystem: "app.theindie.FastTabMobile", category: "WidgetSnapshot")

    private init() {}

    /// Subscribes to the app's data. Idempotent; call once the app's UI is up.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        LocalCache.shared.$state
            .map(\.tabs)
            .removeDuplicates()
            .sink { [weak self] tabs in self?.update { $0.openTabs = WidgetSnapshotBuilder.openTabs(from: tabs) } }
            .store(in: &subscriptions)
        // Up next depends on both the saved list and how far each link has been read.
        RecentAddedProvider.shared.$items
            .combineLatest(ReaderReadingProgress.shared.objectWillChange.prepend(()))
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] items, _ in
                self?.update {
                    $0.upNext = WidgetSnapshotBuilder.upNext(from: items) { ReaderReadingProgress.shared.progress(for: $0) }
                }
            }
            .store(in: &subscriptions)
        ReadingStatsRecorder.shared.writesLanded
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] in self?.reloadReading() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .map { _ in ReadingGoal.dailyWords }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.reloadReading() }
            .store(in: &subscriptions)

        reloadReading()
    }

    /// Call when the Shuffle deck's top card changes (nil when the deck is empty).
    func shuffleTopCardChanged(_ card: RandomCardItem?) {
        guard let card else {
            update { $0.shuffle = nil }
            return
        }
        let fileName = WidgetSnapshotBuilder.thumbnailFileName(for: card)
        let hasThumbnail = FileManager.default.fileExists(atPath: WidgetSnapshotStore.thumbnailURL(named: fileName).path)
        update { $0.shuffle = WidgetSnapshotBuilder.shuffle(from: card, thumbnailFileName: hasThumbnail ? fileName : nil) }
        guard !hasThumbnail else { return }

        Task {
            let preview = await LinkPreviewLoader.shared.preview(for: card.url)
            guard let image = preview.image, saveThumbnail(image, named: fileName) else { return }
            // The deck may have moved on while the preview loaded.
            guard snapshot.shuffle?.item.url == card.url else { return }
            update { $0.shuffle = WidgetSnapshotBuilder.shuffle(from: card, thumbnailFileName: fileName) }
        }
    }

    /// Re-reads the reading log for the ring. Also run when the app comes to the foreground,
    /// so a new day is reflected even if nothing was read.
    func reloadReading() {
        readingReload?.cancel()
        readingReload = Task {
            let recorder = ReadingStatsRecorder.shared
            await recorder.waitForPendingWrites()
            let events = (try? await recorder.log.loadEvents()) ?? []
            guard !Task.isCancelled else { return }
            let reading = WidgetSnapshotBuilder.reading(
                from: events, dailyWordGoal: ReadingGoal.dailyWords, now: Date(), calendar: calendar
            )
            update { $0.reading = reading }
        }
    }

    // MARK: - Writing

    private func update(_ change: (inout WidgetSnapshot) -> Void) {
        var next = snapshot
        change(&next)
        next.writtenAt = snapshot.writtenAt
        guard next != snapshot else { return }
        snapshot = next
        scheduleWrite()
    }

    /// Writes a pending change right away. Call when the app goes to the background, where a
    /// debounced write might never get to run.
    func flushPendingWrite() {
        guard let pendingWrite else { return }
        pendingWrite.cancel()
        self.pendingWrite = nil
        writeNow()
    }

    private func scheduleWrite() {
        pendingWrite?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.writeNow() }
        pendingWrite = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceInterval, execute: work)
    }

    private func writeNow() {
        pendingWrite = nil
        snapshot.writtenAt = Date()
        do {
            try WidgetSnapshotStore.save(snapshot)
            pruneThumbnails(keeping: snapshot.shuffle?.thumbnailFileName)
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            logger.error("Widget snapshot write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Thumbnails

    private func saveThumbnail(_ image: UIImage, named fileName: String) -> Bool {
        let longest = max(image.size.width * image.scale, image.size.height * image.scale)
        let scale = min(1, Self.thumbnailMaxPixelSize / max(longest, 1))
        let size = CGSize(width: image.size.width * image.scale * scale, height: image.size.height * image.scale * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let data = resized.jpegData(compressionQuality: 0.75) else { return false }
        do {
            try FileManager.default.createDirectory(at: WidgetSnapshotStore.thumbnailDirectoryURL, withIntermediateDirectories: true)
            try data.write(to: WidgetSnapshotStore.thumbnailURL(named: fileName), options: .atomic)
            return true
        } catch {
            logger.error("Widget thumbnail write failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Only the current card's thumbnail is ever needed.
    private func pruneThumbnails(keeping fileName: String?) {
        let directory = WidgetSnapshotStore.thumbnailDirectoryURL
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for file in files where file != fileName {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
        }
    }
}
