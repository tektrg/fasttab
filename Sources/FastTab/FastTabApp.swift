import SwiftUI
import AppKit
import OSLog
import Combine

private let appLogger = Logger(subsystem: "com.trungluong.FastTab", category: "AppDelegate")
let fastTabCycleShortcutNotification = Notification.Name("FastTabCycleShortcut")
let fastTabPresentLicenseActivationNotification = Notification.Name("FastTabPresentLicenseActivation")

public enum CommandBarOpenTrigger: Sendable, Equatable {
    case shortcut
    case mouse

    public var isMouse: Bool { self == .mouse }
    public var shouldExpandAllTabs: Bool { self == .mouse }
}

@MainActor
class AppState: ObservableObject {
    @Published var isVisible: Bool = false {
        didSet {
            guard isVisible != oldValue else { return }
            // The outside-click dismiss monitor is a *global* event monitor: it
            // wakes this process for every mouse-down anywhere on the Mac. Only
            // keep it installed while the bar is actually visible, otherwise a
            // hidden background app burns energy (and fires a publish storm) on
            // every click the user makes in any other app.
            if isVisible {
                CommandBarPanelController.shared.startOutsideClickMonitoring()
                CommandBarPanelController.shared.startHoverDismissMonitoring()
            } else {
                CommandBarPanelController.shared.stopOutsideClickMonitoring()
                CommandBarPanelController.shared.stopHoverDismissMonitoring()
            }
        }
    }
    /// Mirrors `ContentView`'s search field so the hover-dismiss monitor (an
    /// AppKit service with no view access) can gate on it — see
    /// `CommandBarPanelController.evaluateHoverDismiss`.
    @Published var isSearchTextEmpty: Bool = true {
        didSet {
            guard isSearchTextEmpty != oldValue, isVisible else { return }
            CommandBarPanelController.shared.evaluateHoverDismiss()
        }
    }
    /// Mirrors `ContentView`'s `isShowingAllOpenTabs` so AppKit-side code (no
    /// view access) can read it — `CommandBarPanelController.isCursorOutsideSurface`
    /// sizes the hover-dismiss box off this flag so it matches the taller
    /// expanded panel instead of the small quick-open cap.
    @Published var isShowingAllOpenTabs: Bool = false {
        didSet {
            guard isShowingAllOpenTabs != oldValue, isVisible else { return }
            CommandBarPanelController.shared.evaluateHoverDismiss()
        }
    }
    @Published var selectedIndex: Int = 0
    @Published var isRecordingShortcut: Bool = false
    @Published var wasOpenedByHover: Bool = false
    @Published var wasOpenedByMouse: Bool = false
    @Published var pendingInitialView: CommandBarView? = nil
    @Published var globalShortcutRegistrationIssue: String?
    let browserService = BrowserTabService()

    func recordTypingActivity() {
        CommandBarPanelController.shared.recordTypingActivity()
    }

    func resetTypingActivity() {
        CommandBarPanelController.shared.resetTypingActivity()
    }

    static let shared = AppState()
    private var cancellables = Set<AnyCancellable>()
    private weak var commandWindow: NSWindow?
    private var didHideInitialWindow = false
    private var pendingShowAfterAttach = false
    private var pendingLicenseActivationPresentation = false
    private var pendingOpenTrigger: CommandBarOpenTrigger = .mouse
    private var pendingRevealStyle: EdgeRevealStyle?

    init() {
        browserService.objectWillChange
            .debounce(for: .milliseconds(16), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        SentLinkInbox.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.browserService.refetchCurrent()
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        browserService.prewarmCaches()
        MyOrderStore.shared.bindToService(
            closer: { [weak self] result in self?.browserService.remove(result) },
            activator: { [weak self] result in self?.browserService.activate(result) },
            reopener: { [weak self] result in self?.browserService.openViaWebAppRoutingOrNormally(result) },
            canceller: { [weak self] browser, url in self?.browserService.cancelRecentlyClosedTombstone(browserName: browser, url: url) },
            tabOrderSyncer: { SyncService.shared.updateTabOrder($0) },
            pinner: { [weak self] result, pinned in self?.browserService.togglePin(result, pinned: pinned) }
        )
        SyncService.shared.start()
    }

    func attachCommandWindow(_ window: NSWindow) {
        commandWindow = window

        if !didHideInitialWindow {
            didHideInitialWindow = true
            if !pendingShowAfterAttach {
                window.orderOut(nil)
                isVisible = false
            }
        }

        if pendingShowAfterAttach {
            pendingShowAfterAttach = false
            showCommandBar(
                revealStyle: pendingRevealStyle,
                initialView: pendingInitialView,
                openedBy: pendingOpenTrigger
            )
            pendingRevealStyle = nil
        }
    }

    var hasCommandWindow: Bool { commandWindow != nil }

    var isCommandWindowFrontAndActive: Bool {
        guard let commandWindow else { return false }
        return commandWindow.isVisible && commandWindow.isKeyWindow
    }

    var commandWindowDebugState: String {
        guard let commandWindow else { return "window=nil" }
        return "visible=\(commandWindow.isVisible) key=\(commandWindow.isKeyWindow) main=\(commandWindow.isMainWindow) appActive=\(NSApp.isActive)"
    }

    func syncVisibilityFromCommandWindow() {
        let next = commandWindow?.isVisible ?? false
        // @Published republishes even on same-value assignment, so guard to
        // avoid redundant SwiftUI invalidations on every window key/resign.
        if next != isVisible { isVisible = next }
    }

    func setOpenTrigger(_ trigger: CommandBarOpenTrigger) {
        wasOpenedByMouse = trigger.isMouse
        isShowingAllOpenTabs = trigger.shouldExpandAllTabs
    }

    /// - Parameter revealStyle: non-nil when this open was triggered by the
    ///   notch/edge hover reveal (`EdgeRevealService`), rather than the
    ///   keyboard shortcut or menu-bar icon. Plays a brief grow-from-that-side
    ///   animation instead of appearing instantly.
    /// - Parameter openedBy: Whether triggered via keyboard shortcut or mouse
    ///   (hover, menu bar click, dock icon). Mouse opens expand to the full list of tabs;
    ///   the 5-tab quick-open limit only applies to shortcut opens.
    func showCommandBar(
        revealStyle: EdgeRevealStyle? = nil,
        initialView: CommandBarView? = nil,
        openedBy: CommandBarOpenTrigger = .mouse
    ) {
        pendingInitialView = initialView
        pendingRevealStyle = revealStyle
        pendingOpenTrigger = openedBy
        setOpenTrigger(openedBy)
        LicenseService.shared.refreshTimeSensitiveState()
        SyncService.shared.fetchLatestChanges()
        SentLinkInbox.shared.reloadFromDisk()

        guard let commandWindow else {
            pendingShowAfterAttach = true
            CommandBarPanelController.shared.prepare()

            if commandWindow == nil {
                appLogger.error("showCommandBar: commandWindow is nil and no opener available")
            }
            return
        }

        selectedIndex = -1
        browserService.updateCurrentFlowSourceApp(bundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        commandWindow.configureCommandBarOverlayBehavior()
        commandWindow.fitCommandBarCanvasToVisibleScreen(preferMouseScreen: true)

        // Arm the grow animation before the window is ordered front: it must
        // already be in its shrunk presentation state for the first rendered
        // frame, or the bar flashes at full size for a frame before shrinking.
        if let revealStyle {
            wasOpenedByHover = true
            CommandBarPanelController.shared.playRevealAnimation(from: revealStyle)
        } else {
            wasOpenedByHover = false
            if openedBy == .shortcut {
                CommandBarPanelController.shared.armShortcutOpenGracePeriod()
            }
        }

        commandWindow.orderFrontRegardless()
        commandWindow.makeKey()
        isVisible = commandWindow.isVisible
        presentPendingLicenseActivationIfNeeded()
    }

    func hideCommandBar() {
        guard isVisible || (commandWindow?.isVisible ?? false) else { return }
        // Keep the window on screen and let `ContentView` play the shrink
        // animation; it calls `finishHidingAfterDismissAnimation()` once that
        // finishes, which is what actually orders the window out.
        CommandBarDismissTrigger.shared.fire()
    }

    /// Called by `ContentView` after the shrink-out animation completes.
    func finishHidingAfterDismissAnimation() {
        commandWindow?.orderOut(nil)
        isVisible = false
        wasOpenedByHover = false
        wasOpenedByMouse = false
        isShowingAllOpenTabs = false
        pendingInitialView = nil
        pendingRevealStyle = nil
        pendingOpenTrigger = .mouse
    }

    func toggleCommandBar(openedBy: CommandBarOpenTrigger = .mouse) {
        if isVisible {
            hideCommandBar()
        } else {
            showCommandBar(openedBy: openedBy)
        }
    }

    func requestLicenseActivationPresentation() {
        pendingLicenseActivationPresentation = true
        showCommandBar(openedBy: .mouse)
    }

    private func presentPendingLicenseActivationIfNeeded() {
        guard pendingLicenseActivationPresentation else { return }
        pendingLicenseActivationPresentation = false
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: fastTabPresentLicenseActivationNotification,
                object: nil
            )
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private let hotkeyService = GlobalHotkeyService()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        appLogger.info("Application did finish launching")
        NSApp.setActivationPolicy(.accessory)
        // No idle-sleep-disable / App-Nap-exemption activity token here: the
        // notch/edge hover trigger (`EdgeRevealService`) is invisible
        // `NSTrackingArea` windows, not a continuous global mouse monitor, so
        // detection is delivered on demand by the window server instead of
        // depending on this process staying unthrottled in the background.
        CommandBarPanelController.shared.prepare()
        setupGlobalShortcut()
        EdgeRevealService.shared.start()
        ExtensionBridge.shared.start()
        NativeHostInstaller.shared.installIfNeeded()
        LicenseService.shared.validateForLaunch()
        registerForCloudKitPushes()

        if CommandLine.arguments.contains("--cloudkit-spike") {
            CloudKitSpike.run()
        }

        if OnboardingWindowController.shared.isNeeded {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                OnboardingWindowController.shared.show()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            UpdateService.shared.checkForUpdates(manual: false)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            LicenseService.shared.handleActivationURL(url)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MyOrderStore.shared.flush()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppState.shared.showCommandBar(openedBy: .mouse)
        return true
    }

    // MARK: - CloudKit Push

    /// `CKSyncEngine` already registers the CloudKit-side subscription, so
    /// CloudKit is sending pushes whether or not we ask for them. This is the
    /// only thing standing between those pushes and the app: an unregistered
    /// process just never sees them.
    ///
    /// No `UNUserNotificationCenter` authorization request, deliberately —
    /// these are silent data pushes that never surface a banner, so asking would
    /// put a permission alert in front of the user for nothing.
    private func registerForCloudKitPushes() {
        NSApplication.shared.registerForRemoteNotifications()
    }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        appLogger.info("Registered for CloudKit pushes (token \(deviceToken.count) bytes)")
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Almost always provisioning: the App ID or the signing profile does not
        // carry the Push Notifications capability. Sync still works on its poll,
        // just not instantly — so this is loud in the log and silent in the UI.
        appLogger.error("CloudKit push registration failed: \(error.localizedDescription, privacy: .public)")
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        SyncService.shared.handleRemoteNotification(userInfo)
    }

    private func setupGlobalShortcut() {
        let store = ShortcutStore.shared

        hotkeyService.onHotKeyPressed = { [weak self] hotkeyID in
            Task { @MainActor in
                self?.handleGlobalShortcut(id: hotkeyID)
            }
        }

        applyAllShortcuts()

        Publishers.CombineLatest4(store.$keyCode, store.$modifiers, store.$recentsShortcut, store.$myOrderShortcut)
            .sink { [weak self] _ in
                self?.applyAllShortcuts()
            }
            .store(in: &cancellables)

        store.$bookmarksShortcut
            .sink { [weak self] _ in
                self?.applyAllShortcuts()
            }
            .store(in: &cancellables)

        appLogger.info("Global hotkey service registered shortcuts")
    }

    private func applyAllShortcuts() {
        let store = ShortcutStore.shared

        // ID 1: Primary shortcut
        let result = hotkeyService.registerShortcut(id: 1, keyCode: store.keyCode, modifiers: store.modifiers)
        AppState.shared.globalShortcutRegistrationIssue = result.userMessage
        if let message = result.userMessage {
            appLogger.error("Primary global hotkey registration issue: \(message, privacy: .public)")
        }

        // ID 2: Recents
        if let recents = store.recentsShortcut {
            hotkeyService.registerShortcut(id: 2, keyCode: recents.keyCode, modifiers: recents.modifierFlags)
        } else {
            hotkeyService.unregisterShortcut(id: 2)
        }

        // ID 3: My Order
        if let myOrder = store.myOrderShortcut {
            hotkeyService.registerShortcut(id: 3, keyCode: myOrder.keyCode, modifiers: myOrder.modifierFlags)
        } else {
            hotkeyService.unregisterShortcut(id: 3)
        }

        // ID 4: Bookmarks
        if let bookmarks = store.bookmarksShortcut {
            hotkeyService.registerShortcut(id: 4, keyCode: bookmarks.keyCode, modifiers: bookmarks.modifierFlags)
        } else {
            hotkeyService.unregisterShortcut(id: 4)
        }
    }

    private func handleGlobalShortcut(id: UInt32) {
        let appState = AppState.shared
        let viewStore = CommandBarViewStore.shared

        switch id {
        case 1:
            let shouldCycle = appState.isCommandWindowFrontAndActive
            if shouldCycle {
                NotificationCenter.default.post(name: fastTabCycleShortcutNotification, object: nil)
            } else {
                appState.showCommandBar(openedBy: .shortcut)
            }
        case 2:
            if appState.isCommandWindowFrontAndActive && viewStore.activeView == .recents {
                NotificationCenter.default.post(name: fastTabCycleShortcutNotification, object: nil)
            } else {
                viewStore.selectView(.recents)
                if !appState.isVisible {
                    appState.showCommandBar(initialView: .recents, openedBy: .shortcut)
                }
            }
        case 3:
            if appState.isCommandWindowFrontAndActive && viewStore.activeView == .myOrder {
                NotificationCenter.default.post(name: fastTabCycleShortcutNotification, object: nil)
            } else {
                viewStore.selectView(.myOrder)
                if !appState.isVisible {
                    appState.showCommandBar(initialView: .myOrder, openedBy: .shortcut)
                }
            }
        case 4:
            if appState.isCommandWindowFrontAndActive && viewStore.activeView == .bookmarks {
                NotificationCenter.default.post(name: fastTabCycleShortcutNotification, object: nil)
            } else {
                viewStore.selectView(.bookmarks)
                if !appState.isVisible {
                    appState.showCommandBar(initialView: .bookmarks, openedBy: .shortcut)
                }
            }
        default:
            break
        }
    }
}

@main
struct FastTabApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState.shared
    @StateObject private var updateService = UpdateService.shared
    @StateObject private var licenseService = LicenseService.shared
    @StateObject private var syncService = SyncService.shared
    /// Persisted preference, read/written from Settings.
    @AppStorage(CommandBarAppearance.menuBarIconVisibleKey) private var menuBarIconPreference: Bool = true
    /// What `MenuBarExtra(isInserted:)` actually binds to. Deliberately a
    /// plain `@State`, not the `@AppStorage` above: SwiftUI's internal
    /// `MenuBarExtraController` observes `isInserted` via KVO, and wiring
    /// that directly to `@AppStorage`'s NSUserDefaultsController-backed
    /// storage sends the controller into a self-triggering write/observe
    /// loop (it writes the binding, which notifies itself, which writes
    /// again) that pegs the main thread at ~100% CPU forever. `@State`'s
    /// storage isn't KVO/UserDefaults-based, so the controller can't
    /// re-trigger itself through it — the two `onChange`s below just keep
    /// this mirror in sync with the persisted preference by hand.
    @State private var menuBarIconInserted: Bool = true

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(licenseService)
        }

        // The glyph is intentionally constant. Sync health is reported in the
        // menu's status line and in Settings, never as a badge on the icon:
        // sync starts unconditionally at launch, so a Mac-only user who never
        // signs into iCloud would wear a permanent, undismissable warning.
        MenuBarExtra("FastTab", systemImage: "command", isInserted: $menuBarIconInserted) {
            menuBarContent
        }
        .menuBarExtraStyle(.menu)
        .onChange(of: menuBarIconPreference, initial: true) { _, newValue in
            if menuBarIconInserted != newValue { menuBarIconInserted = newValue }
        }
        .onChange(of: menuBarIconInserted) { _, newValue in
            if menuBarIconPreference != newValue { menuBarIconPreference = newValue }
        }
    }

    /// Live sync state, and the way into the Sync section of Settings. Replaces
    /// the old "Test CloudKit Sync…" developer probe, which wrote to a log file
    /// and told the user nothing.
    @ViewBuilder
    private var syncStatusMenuItem: some View {
        let statusLine = SyncStatusPresentation.menuStatusLine(
            health: syncService.syncHealth,
            lastSuccessfulSyncAt: syncService.lastSuccessfulSyncAt
        )

        SettingsLink {
            if syncService.syncHealth.isBlocked {
                Label(statusLine, systemImage: "exclamationmark.icloud.fill")
            } else {
                Text(statusLine)
            }
        }
    }

    @ViewBuilder
    private var menuBarContent: some View {
        Button(appState.isVisible ? "Hide FastTab" : "Show FastTab") {
            appState.toggleCommandBar(openedBy: .mouse)
        }

        syncStatusMenuItem

        Divider()

        Button("Buy FastTab…") {
            licenseService.openCheckout(source: .menuBar)
        }

        Button("Enter License Key…") {
            appState.requestLicenseActivationPresentation()
        }

        Button("Manage License…") {
            licenseService.openManageLicense()
        }

        Divider()

        SettingsLink {
            Text("Settings…")
        }

        Button("Feedback & Support…") {
            licenseService.openSupport()
        }

        Divider()

        Button("Check for Updates…") {
            updateService.checkForUpdates(manual: true)
        }

        switch updateService.status {
        case .available(let version, _):
            Button("Update to v\(version)") {
                updateService.performPrimaryAction()
            }
        case .readyToRestart(let version):
            Button("Restart to Update v\(version)") {
                updateService.performPrimaryAction()
            }
        default:
            EmptyView()
        }

        Button("Quit") {
            NSApp.terminate(nil)
        }
    }
}

final class CommandBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override var isMovable: Bool {
        get { false }
        set { }
    }
    override var isMovableByWindowBackground: Bool {
        get { false }
        set { }
    }

    /// AppKit's default behavior pushes any window whose frame reaches into the
    /// menu bar strip back down below it. That silently shrank the full-screen
    /// canvas we set in `fitCommandBarCanvasToVisibleScreen`, leaving a
    /// menu-bar-height gap between the notch-anchored bar and the true top of
    /// the display. Returning the rect unchanged keeps the canvas flush.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override func sendEvent(_ event: NSEvent) {
        if event.isMouseDownEvent {
            let screenLocation = convertPoint(toScreen: event.locationInWindow)

            if CommandBarLayout.shouldDismissClick(at: screenLocation, in: frame, anchor: EdgeRevealStyle.commandBarAnchor) {
                AppState.shared.hideCommandBar()
                return
            }
        }

        super.sendEvent(event)
    }
}

@MainActor
private final class CommandBarPanelController: NSObject {
    static let shared = CommandBarPanelController()

    private var panel: CommandBarPanel?
    private weak var observedWindow: NSWindow?
    private var globalMouseDownMonitor: Any?
    private var globalMouseMovedMonitor: Any?
    private var localMouseMovedMonitor: Any?
    private var pendingHoverDismiss: DispatchWorkItem?
    private var lastTypingDate: Date?
    /// Set when the bar opens from the keyboard shortcut/menu-bar icon, i.e.
    /// with no guarantee the cursor is anywhere near the surface. Hover-dismiss
    /// stays fully disarmed until this passes, so a cursor that happens to be
    /// resting outside the surface at open time can't start the dismiss dwell
    /// before the user has even looked at the bar. Hover-triggered opens
    /// (`EdgeRevealService`) skip this — the cursor is already on the surface
    /// there, so there's nothing to guard against.
    private var hoverDismissArmDeadline: Date?

    /// How far the cursor must clear the surface before it counts as "left" —
    /// stops the dwell arming from sub-pixel jitter right at the edge.
    private static let hoverDismissOutset: CGFloat = 6
    /// Long enough that glancing away for a moment doesn't collapse the bar,
    /// short enough that leaving it read as intentional. Slightly longer than
    /// `EdgeRevealService`'s reveal dwell since a false collapse is more
    /// disruptive than a delayed reveal.
    private static let hoverDismissDwell: TimeInterval = 0.35
    /// Grace window after a shortcut/menu-bar open before hover-dismiss can
    /// arm at all — gives the user time to reach for the keyboard and start
    /// typing before an incidentally-outside cursor counts against them.
    private static let shortcutOpenGraceDuration: TimeInterval = 1.0

    func prepare() {
        _ = commandPanel
    }

    /// Called from `AppState.showCommandBar` for shortcut/menu-bar opens
    /// (not hover reveals) to start the grace window before hover-dismiss
    /// can arm — see `hoverDismissArmDeadline`.
    func armShortcutOpenGracePeriod() {
        hoverDismissArmDeadline = Date().addingTimeInterval(Self.shortcutOpenGraceDuration)
    }

    func recordTypingActivity() {
        lastTypingDate = Date()
        pendingHoverDismiss?.cancel()
        pendingHoverDismiss = nil
        if AppState.shared.isVisible, AppState.shared.isSearchTextEmpty {
            evaluateHoverDismiss()
        }
    }

    func resetTypingActivity() {
        lastTypingDate = nil
        pendingHoverDismiss?.cancel()
        pendingHoverDismiss = nil
    }

    private var commandPanel: CommandBarPanel {
        if let panel { return panel }

        let rootView = ContentView()
            .environmentObject(AppState.shared)
            .environmentObject(LicenseService.shared)

        let panel = CommandBarPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier("command-bar-panel")
        panel.title = "Command Bar"
        panel.contentViewController = NSHostingController(rootView: rootView)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        // AppKit plays its own appear animation for panels (a fade plus a ~2%
        // scale-up about the window's centre). This window is the size of the
        // whole screen, so that 2% is ~12pt of displacement at its edges: the
        // reveal's first frames were composited inset from the screen edge and
        // slid flush over ~0.12s, which read as a gap the bar grew out of. The
        // reveal is our own spring — AppKit must not animate the window at all.
        panel.animationBehavior = .none
        panel.configureCommandBarOverlayBehavior()
        panel.fitCommandBarCanvasToVisibleScreen(preferMouseScreen: true)

        installWindowObservers(for: panel)
        AppState.shared.attachCommandWindow(panel)
        AppState.shared.syncVisibilityFromCommandWindow()

        self.panel = panel
        return panel
    }

    private func installWindowObservers(for window: NSWindow) {
        guard observedWindow !== window else { return }

        observedWindow = window

        let center = NotificationCenter.default
        center.removeObserver(self)

        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.willCloseNotification
        ]

        for name in names {
            center.addObserver(
                self,
                selector: #selector(handleObservedWindowChange),
                name: name,
                object: window
            )
        }

        center.addObserver(
            self,
            selector: #selector(handleScreenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func handleObservedWindowChange() {
        AppState.shared.syncVisibilityFromCommandWindow()
    }

    @objc private func handleScreenParametersChanged() {
        guard let observedWindow, observedWindow.isVisible else { return }
        observedWindow.fitCommandBarCanvasToVisibleScreen(preferMouseScreen: false)
    }

    /// Arms the SwiftUI-native grow-from-edge reveal animation (see
    /// `CommandBarRevealTrigger`/`ContentView`) instead of the instant
    /// appearance used by the keyboard shortcut. Must run before the window
    /// is ordered front so the first rendered frame is already in its
    /// shrunk state, matching the same requirement the previous CALayer-based
    /// version had — a raw `CABasicAnimation` on the whole (screen-sized)
    /// content-view layer read as the bar sliding into place rather than
    /// expanding from the edge, since the anchor was applied to the entire
    /// canvas rather than just the visible surface within it.
    func playRevealAnimation(from style: EdgeRevealStyle) {
        CommandBarRevealTrigger.shared.fire(anchor: style)
    }

    func startOutsideClickMonitoring() {
        guard globalMouseDownMonitor == nil else { return }

        let eventMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: eventMask) { _ in
            DispatchQueue.main.async {
                guard AppState.shared.isVisible else { return }
                AppState.shared.hideCommandBar()
            }
        }
    }

    func stopOutsideClickMonitoring() {
        guard let monitor = globalMouseDownMonitor else { return }
        NSEvent.removeMonitor(monitor)
        globalMouseDownMonitor = nil
    }

    /// Auto-collapses the bar when the cursor leaves it while the search field
    /// is empty — an idle, untouched bar shouldn't linger on screen. Gated on
    /// empty search so it never yanks the bar away mid-query.
    ///
    /// Needs both a global and a local mouse-moved monitor for the same reason
    /// `EdgeRevealService` does: the global monitor alone goes quiet while one
    /// of our own windows is frontmost, which is exactly when this needs to
    /// keep tracking the cursor leaving that window.
    func startHoverDismissMonitoring() {
        guard globalMouseMovedMonitor == nil else { return }

        globalMouseMovedMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            DispatchQueue.main.async { self?.evaluateHoverDismiss() }
        }
        localMouseMovedMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.evaluateHoverDismiss()
            return event
        }
    }

    func stopHoverDismissMonitoring() {
        if let monitor = globalMouseMovedMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseMovedMonitor = nil
        }
        if let monitor = localMouseMovedMonitor {
            NSEvent.removeMonitor(monitor)
            localMouseMovedMonitor = nil
        }
        pendingHoverDismiss?.cancel()
        pendingHoverDismiss = nil
        hoverDismissArmDeadline = nil
        lastTypingDate = nil
    }

    /// Re-checked on every mouse move and every time the search field's
    /// empty/non-empty state flips, so it reacts to the search being cleared
    /// while the cursor is already outside just as readily as to the cursor
    /// leaving while already empty.
    func evaluateHoverDismiss() {
        guard AppState.shared.isVisible, AppState.shared.isSearchTextEmpty, panel != nil else {
            pendingHoverDismiss?.cancel()
            pendingHoverDismiss = nil
            return
        }

        if let armDeadline = hoverDismissArmDeadline {
            guard Date() >= armDeadline else { return }
            hoverDismissArmDeadline = nil
        }

        guard isCursorOutsideSurface() else {
            pendingHoverDismiss?.cancel()
            pendingHoverDismiss = nil
            return
        }
        guard pendingHoverDismiss == nil else { return }

        let work = DispatchWorkItem { [weak self] in
            self?.pendingHoverDismiss = nil
            guard AppState.shared.isVisible, AppState.shared.isSearchTextEmpty,
                  self?.isCursorOutsideSurface() == true else { return }
            AppState.shared.hideCommandBar()
        }
        pendingHoverDismiss = work
        let delay = CommandBarLayout.hoverDismissDelay(lastTypingDate: lastTypingDate)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Bounds this against the user's *actual* configured row cap
    /// (`CommandBarAppearance.quickOpenItemLimitKey`), not the global ceiling
    /// `surfaceFrame` defaults to for the click-dismiss test — hover-dismiss
    /// only ever runs while the search field is empty, when the panel can
    /// never grow past that setting, so using the global ceiling there made
    /// the box tall enough to swallow most of the screen's vertical middle,
    /// and leaving the bar by moving straight up or down never registered as
    /// "outside."
    ///
    /// When `AppState.isShowingAllOpenTabs` is set, the panel has expanded
    /// past that configured cap to `expandedAllTabsMaxRows` — using the small
    /// quick-open cap here would draw the box shorter than the actually
    /// rendered (taller) panel, so leaving the panel by crossing out of that
    /// undersized box (while still visibly over the expanded list) fired the
    /// dismiss early.
    private func isCursorOutsideSurface() -> Bool {
        guard let panel else { return true }
        let defaults = UserDefaults.standard
        let rowStyle = ResultRowStyle(rawValue: defaults.string(forKey: CommandBarAppearance.resultRowStyleKey) ?? "") ?? .minimal
        let showFooter = defaults.object(forKey: CommandBarAppearance.helperPanelVisibleKey) as? Bool ?? true
        let limitSetting = defaults.object(forKey: CommandBarAppearance.quickOpenItemLimitKey) as? Int ?? 5
        let maxRows = CommandBarLayout.surfaceMaxRows(
            view: CommandBarViewStore.shared.activeView,
            isShowingAllOpenTabs: AppState.shared.isShowingAllOpenTabs,
            isSearching: false,
            anchor: EdgeRevealStyle.commandBarAnchor,
            rowStyle: rowStyle,
            showFooter: showFooter,
            quickOpenLimit: limitSetting
        )

        let surface = CommandBarLayout.surfaceFrame(
            in: panel.frame,
            anchor: EdgeRevealStyle.commandBarAnchor,
            rowStyle: rowStyle,
            maxRows: maxRows,
            showFooter: showFooter
        )
        return !surface.insetBy(dx: -Self.hoverDismissOutset, dy: -Self.hoverDismissOutset)
            .contains(NSEvent.mouseLocation)
    }
}

private extension NSEvent {
    var isMouseDownEvent: Bool {
        type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
    }
}

extension NSWindow {
    func configureCommandBarOverlayBehavior() {
        styleMask.insert(.nonactivatingPanel)
        // Above the menu bar (`.mainMenu`), not merely `.floating`: the bar now
        // sits flush against the true top of the display, so at `.floating` the
        // menu bar painted over its top strip — invisible with a translucent
        // menu bar, but an opaque band under Reduce Transparency.
        level = .statusBar

        var behavior = collectionBehavior
        behavior.remove(.moveToActiveSpace)
        behavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary, .stationary])
        collectionBehavior = behavior
        isMovable = false
        isMovableByWindowBackground = false
    }

    func fitCommandBarCanvasToVisibleScreen(preferMouseScreen: Bool) {
        // Full screen frame, not `visibleFrame` — `visibleFrame` excludes the
        // menu bar strip, which left a gap between the notch anchor and the
        // true top edge of the display instead of sitting flush against it.
        let displayFrame = preferredCommandBarDisplay(preferMouseScreen: preferMouseScreen)?.frame ?? NSScreen.main?.frame ?? frame
        let canvasFrame = CommandBarLayout.canvasFrame(for: displayFrame)

        setFrame(canvasFrame, display: true, animate: false)
    }

    private func preferredCommandBarDisplay(preferMouseScreen: Bool) -> NSScreen? {
        if preferMouseScreen {
            let mouseLocation = NSEvent.mouseLocation

            if let mouseScreen = NSScreen.containing(mouseLocation) {
                return mouseScreen
            }
        }

        return screen ?? NSScreen.main
    }
}
