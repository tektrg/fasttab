import AppKit

/// The optional menu bar icon: a plain symbol whose menu opens the panel or
/// Settings, or quits. No badges or counts.
@MainActor
final class MenuBarItemController: NSObject {
    struct Handlers {
        var showPanel: () -> Void
        var showSettings: () -> Void
        var showAgentTree: () -> Void
    }

    private let handlers: Handlers
    private var statusItem: NSStatusItem?

    init(handlers: Handlers) {
        self.handlers = handlers
    }

    func setVisible(_ isVisible: Bool) {
        if isVisible, statusItem == nil {
            statusItem = makeStatusItem()
        } else if !isVisible, let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    private func makeStatusItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "list.bullet.rectangle", accessibilityDescription: "AgentBar")
        item.menu = makeMenu()
        return item
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Show AgentBar", #selector(showPanel), key: ""))
        menu.addItem(item("Agent Hierarchy…", #selector(showAgentTree), key: "t"))
        menu.addItem(item("Settings…", #selector(showSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(item("Quit AgentBar", #selector(quit), key: "q"))
        return menu
    }

    private func item(_ title: String, _ action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func showPanel() { handlers.showPanel() }
    @objc private func showSettings() { handlers.showSettings() }
    @objc private func showAgentTree() { handlers.showAgentTree() }
    @objc private func quit() { NSApp.terminate(nil) }
}
