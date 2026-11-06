import Foundation
import OSLog

/// The user's saved custom views, in swipe order. Local-only (UserDefaults
/// JSON) for v1; `CustomView` is Codable so iPhone sync can be layered on.
@MainActor
final class CustomViewStore: ObservableObject {
    static let shared = CustomViewStore()

    static let defaultsKey = "FastTab.customViews.v1"

    /// In swipe order (after Recent and Stack, before "＋ New View").
    @Published private(set) var views: [CustomView]

    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.trungluong.FastTab", category: "CustomViewStore")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.views = Self.load(from: defaults)
    }

    func view(id: UUID) -> CustomView? {
        views.first { $0.id == id }
    }

    // MARK: Mutation

    /// Appends `view` (at the end of the swipe order). Replaces in place if
    /// its id already exists.
    func add(_ view: CustomView) {
        if let index = views.firstIndex(where: { $0.id == view.id }) {
            views[index] = view
        } else {
            views.append(view)
        }
        persist()
    }

    /// Replaces the view with the same id; no-op when it doesn't exist.
    func update(_ view: CustomView) {
        guard let index = views.firstIndex(where: { $0.id == view.id }), views[index] != view else { return }
        views[index] = view
        persist()
    }

    func delete(id: UUID) {
        guard views.contains(where: { $0.id == id }) else { return }
        views.removeAll { $0.id == id }
        persist()
    }

    /// Same contract as SwiftUI's `move(fromOffsets:toOffset:)` (`onMove`):
    /// `destination` is an index in the array *before* the move.
    func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let valid = offsets.filter { views.indices.contains($0) }
        guard !valid.isEmpty else { return }
        let moving = valid.map { views[$0] }
        var remaining = views
        for index in valid.reversed() { remaining.remove(at: index) }
        let clamped = min(max(destination, 0), views.count)
        let insertAt = clamped - valid.filter { $0 < clamped }.count
        remaining.insert(contentsOf: moving, at: insertAt)
        guard remaining != views else { return }
        views = remaining
        persist()
    }

    // MARK: Persistence

    private func persist() {
        do {
            defaults.set(try JSONEncoder().encode(views), forKey: Self.defaultsKey)
        } catch {
            logger.error("custom views encode failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Decodes element by element, so one malformed entry drops only itself
    /// rather than the user's whole list.
    private static func load(from defaults: UserDefaults) -> [CustomView] {
        guard let data = defaults.data(forKey: defaultsKey),
              let entries = try? JSONDecoder().decode([LossyView].self, from: data) else { return [] }
        return entries.compactMap(\.view)
    }

    private struct LossyView: Decodable {
        let view: CustomView?
        init(from decoder: Decoder) throws {
            view = try? CustomView(from: decoder)
        }
    }
}
