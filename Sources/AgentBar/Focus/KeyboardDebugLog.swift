import AppKit

/// Off-by-default trace of who owns the keyboard, for the "typed keys get lost" bug (2026-11-13).
/// Turn on: `defaults write com.trungluong.AgentBar keyboardDebugLog -bool YES`, relaunch AgentBar.
/// Read: `~/Library/Logs/AgentBar/keyboard.log` (a file, because `log show` returned nothing for AgentBar).
/// Every line starts with "keyboard:" and carries the app/window/first-responder state at that moment.
@MainActor
enum KeyboardDebugLog {
    static let defaultsKey = "keyboardDebugLog"
    static var isOn: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    private static var tokens: [Any] = []
    private static let fileURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/AgentBar")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("keyboard.log")
    }()
    private static let timeFormat: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    static func log(_ what: String, window: NSWindow? = nil) {
        guard isOn else { return }
        let line = "keyboard: \(timeFormat.string(from: Date())) \(what) | \(state(window))\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else {
            try? data.write(to: fileURL)
        }
    }

    static func describe(_ window: NSWindow?) -> String {
        guard let window else { return "none" }
        let name = window.title.isEmpty ? String(describing: type(of: window)) : window.title
        return "\(name)#\(window.windowNumber)(visible=\(window.isVisible) key=\(window.isKeyWindow) canKey=\(window.canBecomeKey))"
    }

    private static func state(_ window: NSWindow?) -> String {
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        var text = "active=\(NSApp.isActive) front=\(front) keyWindow=\(describe(NSApp.keyWindow)) "
            + "keyFR=\(responderName(NSApp.keyWindow?.firstResponder))"
        if let window, window !== NSApp.keyWindow {
            text += " target=\(describe(window)) targetFR=\(responderName(window.firstResponder))"
        }
        return text
    }

    static func responderName(_ responder: NSResponder?) -> String {
        responder.map { String(describing: type(of: $0)) } ?? "nil"
    }

    /// Installs the app-wide watchers (only when the flag is on): every key/mouse event AgentBar's own
    /// event loop receives, key-window changes of every window, and app activation changes.
    static func start() {
        guard isOn, tokens.isEmpty else { return }
        log("trace started")
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown], handler: { event in
            MainActor.assumeIsolated {
                let kind = event.type == .keyDown ? "keyDown '\(event.charactersIgnoringModifiers ?? "")'" : "mouseDown"
                log("event \(kind) to window \(describe(event.window))", window: event.window)
            }
            return event
        }) { tokens.append(monitor) }
        let center = NotificationCenter.default
        let names: [(Notification.Name, String)] = [
            (NSWindow.didBecomeKeyNotification, "window became key"),
            (NSWindow.didResignKeyNotification, "window resigned key"),
            (NSApplication.didBecomeActiveNotification, "app became active"),
            (NSApplication.didResignActiveNotification, "app resigned active"),
        ]
        for (name, label) in names {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                nonisolated(unsafe) let window = note.object as? NSWindow
                MainActor.assumeIsolated { log("\(label): \(describe(window))", window: window) }
            })
        }
    }
}
