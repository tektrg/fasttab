import AppKit
import Combine

/// Wires AgentBar together: status feed -> panel model, hotkeys -> cycle
/// controller -> panel, activation -> switch, and Settings -> all of them
/// (every setting applies live). Owned by the app delegate.
@MainActor
final class AgentBarCoordinator {
    private let settings = AgentBarSettings()
    private var statusSource: DashboardStatusSource
    private let model: AgentPanelModel
    private let panelController: AgentPanelController
    private let hotkeys = AgentHotkeys()
    private let modifierWatcher: ModifierReleaseWatcher
    private let cycleController: AgentCycleController
    private let switchCoordinator: AgentSwitchCoordinator
    private let cornerTab: CornerTabController
    private let arrivalSounds: ArrivalSoundController
    private var feedTask: Task<Void, Never>?
    private var settingsSubscriptions: Set<AnyCancellable> = []

    private lazy var settingsWindow = SettingsWindowController { [unowned self] in
        SettingsView(
            settings: settings,
            actions: AgentBarSettingsActions(
                changeHotkey: { [unowned self] requested in changeHotkey(to: requested) },
                setHotkeyRecording: { [unowned self] isRecording in setHotkeyRecording(isRecording) }
            ),
            connectionTester: DashboardConnectionTester()
        )
    }

    private lazy var menuBarItem = MenuBarItemController(handlers: .init(
        showPanel: { [unowned self] in showPanel() },
        showSettings: { [unowned self] in showSettings() }
    ))

    init() {
        let endpoint = DashboardEndpoint(baseURL: settings.dashboardBaseURL)
        let statusSource = DashboardStatusSource(endpoint: endpoint)
        self.statusSource = statusSource
        let model = AgentPanelModel(listSettings: settings.list, dashboardAddress: endpoint.displayAddress)
        self.model = model
        model.statusSource = statusSource
        model.workerClient = statusSource
        model.routingAPIKeyStore = KeychainRoutingAPIKeyStore()
        model.applyRouting(settings.routing)
        let settings = settings
        let textInputActivation = TextInputActivation(
            focus: SystemAppFocus(),
            isShortcutModifierHeld: {
                let held = settings.hotkey.modifiers.intersection(.deviceIndependentFlagsMask)
                return !NSEvent.modifierFlags.intersection(held).isEmpty
            }
        )
        let panelController = AgentPanelController(model: model, activation: textInputActivation)
        self.panelController = panelController

        let cycleController = AgentCycleController(
            shortcutModifiers: settings.hotkey.modifiers,
            actions: .init(
                isPanelVisible: { panelController.isVisible },
                openPanel: { panelController.show() },
                moveSelection: { [model] step in
                    model.moveSelection(by: step)
                    return model.selectedAgentID != nil
                },
                commitSelection: { [model] in model.activateSelected() }
            )
        )
        self.cycleController = cycleController
        modifierWatcher = ModifierReleaseWatcher { flags in cycleController.modifiersChanged(flags) }

        switchCoordinator = AgentSwitchCoordinator(
            model: model,
            statusSource: statusSource,
            panel: .init(
                hide: { panelController.hide(restoringFocus: false, isAgentSwitch: true) },   // the switch brings the agent's app forward
                show: { panelController.show() },
                isVisible: { panelController.isVisible }
            )
        )
        cornerTab = CornerTabController(
            isEnabled: settings.showsCornerTab,
            panel: .init(
                open: { panelController.show() },
                summary: { [model] in model.needsYouSummary() }
            ),
            model: model,
            activation: textInputActivation
        )
        arrivalSounds = ArrivalSoundController(settings: { [settings] in settings.sounds })
        wire()
        observeSettings()
    }

    func start() {
        beginFeed(from: statusSource)
        menuBarItem.setVisible(settings.showsMenuBarIcon)
        panelController.show()
    }

    /// Launching the app again (e.g. `open AgentBar.app`) summons the panel;
    /// the fallback when the global shortcut could not be registered.
    func showPanel() {
        panelController.show()
    }

    func showSettings() {
        settingsWindow.show()
    }

    // MARK: - Wiring

    private func wire() {
        model.onActivate = { [switchCoordinator] agent in
            Task { await switchCoordinator.switchTo(agent) }
        }
        panelController.onOpenSettings = { [unowned self] in showSettings() }
        cornerTab.onOpenSettings = { [unowned self] in showSettings() }
        model.onNeedsYouArrival = { [cornerTab] content in cornerTab.arrived(content) }
        model.onNeedsYouReading = { [arrivalSounds, cornerTab] arrivals, needsYou in
            arrivalSounds.observe(arrivals: arrivals, needsYou: needsYou ?? [])
            cornerTab.needsYouChanged(needsYou)
        }
        panelController.onVisibilityChange = { [modifierWatcher, cycleController, cornerTab] isVisible in
            cornerTab.panelVisibilityChanged(isVisible)
            if isVisible {
                modifierWatcher.start()
            } else {
                modifierWatcher.stop()
                cycleController.panelClosed()
            }
        }
        hotkeys.onPressed = { [cycleController] direction in
            cycleController.hotkeyPressed(direction, currentModifiers: NSEvent.modifierFlags)
        }
        reportHotkeyIssue(hotkeys.register(settings.hotkey), for: settings.hotkey)
    }

    /// Settings edits reach the running app here. `dropFirst` skips the value
    /// each property already has at subscription time.
    private func observeSettings() {
        settings.$list
            .dropFirst()
            .sink { [model] list in model.apply(list) }
            .store(in: &settingsSubscriptions)
        settings.$showsMenuBarIcon
            .dropFirst()
            .sink { [weak self] shows in self?.menuBarItem.setVisible(shows) }
            .store(in: &settingsSubscriptions)
        settings.$showsCornerTab
            .dropFirst()
            .sink { [weak self] shows in self?.cornerTab.setEnabled(shows) }
            .store(in: &settingsSubscriptions)
        settings.$dashboardBaseURL
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] url in self?.switchDashboard(to: url) }
            .store(in: &settingsSubscriptions)
        settings.$routing
            .dropFirst()
            .sink { [model] routing in model.applyRouting(routing) }
            .store(in: &settingsSubscriptions)
    }

    // MARK: - Status feed

    private func beginFeed(from source: DashboardStatusSource) {
        Task { await source.start() }
        feedTask = Task { @MainActor [model] in
            for await snapshot in source.updates {
                guard !Task.isCancelled else { return }
                model.receive(snapshot)
            }
        }
    }

    /// Stops the old feed completely, then starts one on the new address.
    private func switchDashboard(to baseURL: URL) {
        feedTask?.cancel()
        let previousSource = statusSource
        Task { await previousSource.stop() }

        let endpoint = DashboardEndpoint(baseURL: baseURL)
        let source = DashboardStatusSource(endpoint: endpoint)
        statusSource = source
        switchCoordinator.statusSource = source
        model.statusSource = source
        model.workerClient = source
        model.useDashboard(address: endpoint.displayAddress)
        beginFeed(from: source)
    }

    // MARK: - Hotkey

    /// Registers `requested`; if macOS refuses it, puts the previous shortcut back.
    private func changeHotkey(to requested: AgentHotkeyConfig) -> HotkeyChangeOutcome {
        let previous = settings.hotkey
        let issue = hotkeys.register(requested)
        let outcome = HotkeyChangeOutcome.resolve(previous: previous, requested: requested, registrationIssue: issue)
        if case .reverted = outcome {
            reportHotkeyIssue(hotkeys.register(previous), for: previous)
        } else {
            reportHotkeyIssue(nil, for: requested)
        }
        settings.commitHotkey(outcome.active)
        cycleController.updateShortcutModifiers(outcome.active.modifiers)
        return outcome
    }

    /// While the recorder listens for keys, the global shortcut is off, so
    /// pressing it records it instead of triggering it.
    private func setHotkeyRecording(_ isRecording: Bool) {
        if isRecording {
            hotkeys.suspend()
        } else {
            reportHotkeyIssue(hotkeys.register(settings.hotkey), for: settings.hotkey)
        }
    }

    private func reportHotkeyIssue(_ issue: String?, for config: AgentHotkeyConfig) {
        model.reportHotkeyIssue(issue.map { "\(config.displayName): \($0)" })
    }
}
