import AppKit
import Combine
import IndieEdgeReveal

/// Connects IndieLibKit's hover trigger (`EdgeRevealService`: one invisible
/// hover window per screen, a per-style dwell) to FastTab: follows the
/// Settings choice (`EdgeRevealStore`) and opens the command bar with the
/// grow-from-edge reveal. Hover only — FastTab takes no file drops, so the
/// service runs without its drag monitor.
@MainActor
final class EdgeRevealCoordinator {
    static let shared = EdgeRevealCoordinator()

    private let service = EdgeRevealService()
    private var cancellables = Set<AnyCancellable>()

    private init() {
        // The dwell only proves the pointer stayed; skip when the bar is
        // already open (opened another way meanwhile).
        service.isRevealSuppressed = { AppState.shared.isVisible }
        service.onReveal = { trigger in
            AppState.shared.showCommandBar(revealStyle: trigger.style, openedBy: .mouse)
        }
    }

    /// Call once at app launch. Follows Settings changes for the rest of the
    /// app's lifetime — no separate start/stop call needed elsewhere.
    func start() {
        EdgeRevealStore.shared.$style
            .sink { [weak self] style in self?.service.style = style }
            .store(in: &cancellables)
        service.start()
    }
}
