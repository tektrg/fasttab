import AppKit

/// Reports the live keyboard modifier state while the panel is visible, so the
/// cycle can see the moment ⌥ is released.
///
/// It polls `NSEvent.modifierFlags` (the class property) on a short timer
/// rather than listening for flagsChanged events: AgentBar is a non-activating
/// accessory app, so a local monitor sees nothing until the panel is key, and a
/// global monitor needs the Accessibility permission. The class property is
/// readable with no permission from any app state, and a 20 ms poll only runs
/// while the panel is open.
@MainActor
final class ModifierReleaseWatcher {
    static let pollIntervalSeconds: TimeInterval = 0.02

    private var timer: Timer?
    private let onFlags: @MainActor (NSEvent.ModifierFlags) -> Void

    init(onFlags: @escaping @MainActor (NSEvent.ModifierFlags) -> Void) {
        self.onFlags = onFlags
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.pollIntervalSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        onFlags(NSEvent.modifierFlags)
    }
}
