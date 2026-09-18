import AppKit

/// Wires AgentBar together: status feed -> panel model, hotkeys -> cycle
/// controller -> panel, and activation -> switch. Owned by the app delegate.
@MainActor
final class AgentBarCoordinator {
    private let endpoint = DashboardEndpoint.configured()
    private let statusSource: DashboardStatusSource
    private let model = AgentPanelModel()
    private let panelController: AgentPanelController
    private let hotkeys = AgentHotkeys()
    private let modifierWatcher: ModifierReleaseWatcher
    private let cycleController: AgentCycleController
    private let switchCoordinator: AgentSwitchCoordinator
    private var feedTask: Task<Void, Never>?

    init() {
        statusSource = DashboardStatusSource(endpoint: endpoint)
        let panelController = AgentPanelController(model: model, dashboardAddress: endpoint.displayAddress)
        self.panelController = panelController
        let hotkeyConfig = AgentHotkeyConfig.configured()

        let cycleController = AgentCycleController(
            shortcutModifiers: hotkeyConfig.modifiers,
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
                hide: { panelController.hide() },
                show: { panelController.show() },
                isVisible: { panelController.isVisible }
            )
        )
        wire(hotkeyConfig: hotkeyConfig)
    }

    func start() {
        let source = statusSource
        Task { await source.start() }
        feedTask = Task { @MainActor [model] in
            for await snapshot in source.updates { model.receive(snapshot) }
        }
        panelController.show()
    }

    /// Launching the app again (e.g. `open AgentBar.app`) summons the panel;
    /// the fallback when the global shortcut could not be registered.
    func showPanel() {
        panelController.show()
    }

    private func wire(hotkeyConfig: AgentHotkeyConfig) {
        model.onActivate = { [switchCoordinator] agent in
            Task { await switchCoordinator.switchTo(agent) }
        }
        panelController.onVisibilityChange = { [modifierWatcher, cycleController] isVisible in
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
        model.reportHotkeyIssue(hotkeys.register(hotkeyConfig))
    }
}
