import AppKit
import ApplicationServices
import IndieWorkspace

/// Diagnostic: `agentbar://debug/claude-ax` writes the Accessibility tree of every Claude Desktop
/// window to ~/Library/Logs/AgentBar/claude-ax.txt (needs Agent Bar's Accessibility permission).
@MainActor
enum ClaudeAXDump {
    static func handles(_ url: URL) -> Bool { url.scheme == "agentbar" && url.host == "debug" && url.path == "/claude-ax" }

    static func run() {
        var out = ""
        let start = Date()
        let titles = AXWindowControl().webPageTitles(bundleID: "com.anthropic.claudefordesktop", budget: 0.15)
        out += "matcher read: \(Int(Date().timeIntervalSince(start) * 1000)) ms -> \(titles.map { "\($0)" } ?? "nil (over budget)")\n"
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop").first else { return write("no Claude running") }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(root, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        Thread.sleep(forTimeInterval: 0.5)
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &value)
        let windows = (value as? [AXUIElement]) ?? []
        out += "trusted=\(AXIsProcessTrusted()) pid=\(app.processIdentifier) err=\(err.rawValue) windows=\(windows.count) cgWindows=\(cgWindowCount(app.processIdentifier))\n"
        if windows.isEmpty { var c = 0; walk(root, depth: 0, out: &out, count: &c) }
        for (i, w) in windows.enumerated() {
            out += "=== window \(i)\n"
            var count = 0
            walk(w, depth: 0, out: &out, count: &count)
        }
        write(out)
    }

    private static func cgWindowCount(_ pid: pid_t) -> Int {
        let list = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
        return list.filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }.count
    }

    private static func str(_ e: AXUIElement, _ a: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success, let v else { return nil }
        if let s = v as? String { return s.isEmpty ? nil : String(s.prefix(120)) }
        if let n = v as? NSNumber { return n.stringValue }
        if let arr = v as? [String] { return arr.joined(separator: " ") }
        return nil
    }

    private static func walk(_ e: AXUIElement, depth: Int, out: inout String, count: inout Int) {
        count += 1
        guard count < 6000, depth < 60 else { return }
        let parts = [("r", "AXRole"), ("t", "AXTitle"), ("v", "AXValue"), ("d", "AXDescription"), ("sel", "AXSelected"),
                     ("id", "AXDOMIdentifier"), ("cls", "AXDOMClassList"), ("focus", "AXFocused"), ("url", "AXURL")]
            .compactMap { k, a in str(e, a).map { "\(k)=\($0)" } }
        out += String(repeating: " ", count: depth) + parts.joined(separator: " | ") + "\n"
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v)
        for c in (v as? [AXUIElement]) ?? [] { walk(c, depth: depth + 1, out: &out, count: &count) }
    }

    private static func write(_ s: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/AgentBar")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? s.write(to: dir.appendingPathComponent("claude-ax.txt"), atomically: true, encoding: .utf8)
    }
}
