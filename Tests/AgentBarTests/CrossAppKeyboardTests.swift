import AppKit
import SwiftUI
import Testing
@testable import AgentBar
import IndieCommandBar

/// Bug 2026-11-12 (reopened twice): typed keys did not reach the Message box or the "Other" box in the
/// real app, while `AnswerOtherRealKeysTests` passed. That test runs with the test process as the active
/// app, a fake activation (`FakeAppFocus`) and keys handed straight to `NSApp.sendEvent` — so the moment
/// that matters in real use never happens: ANOTHER app is frontmost, AgentBar (an accessory app with a
/// non-activating panel) clicks into a text box and activates itself, and AppKit/SwiftUI re-settle the
/// keyboard when the app becomes active.
///
/// These tests recreate that: a real helper app is launched and made frontmost (LaunchServices), the test
/// process runs as an accessory app like AgentBar, uses the REAL `SystemAppFocus`, opens a card text box,
/// and then checks what a physical key press needs to land in the box once everything has settled: the
/// card's window is key and the text box is its first responder. (Synthetic HID key events need
/// Accessibility permission, which neither Mac grants the test runner. A test process started from a
/// terminal also never shows as frontmost after `NSApp.activate`, so frontmost-ness is logged, not asserted.)
/// Before the 2026-11-12 fix the Message box failed here: first responder stayed the search box.
///
/// Env-gated, run alone in a GUI session: `AGENTBAR_CROSS_APP=1 swift test --filter CrossAppKeyboardTests`.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["AGENTBAR_CROSS_APP"] == "1",
                              "cross-app: GUI session, run alone, `AGENTBAR_CROSS_APP=1 swift test --filter CrossAppKeyboardTests`"))
struct CrossAppKeyboardTests {
    typealias A = AnswerFixtures
    typealias F = AgentListFixtures

    // MARK: - Helper app (another app that is frontmost, like Claude or a browser)

    private static let helperSource = #"""
    import AppKit
    final class D: NSObject, NSApplicationDelegate {
        var w: NSWindow!
        func applicationDidFinishLaunching(_ n: Notification) {
            w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 160, height: 40), styleMask: [.titled], backing: .buffered, defer: false)
            w.title = "AgentBar key-test helper"
            let f = NSTextField(frame: NSRect(x: 4, y: 8, width: 150, height: 22))
            w.contentView!.addSubview(f)
            w.makeKeyAndOrderFront(nil)
            w.makeFirstResponder(f)
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 120) { exit(0) }   // never outlives a stuck test
        }
    }
    let app = NSApplication.shared
    let d = D(); app.delegate = d
    app.setActivationPolicy(.regular)
    app.run()
    """#

    private static func launchHelper() throws -> NSRunningApplication? {
        for stale in NSRunningApplication.runningApplications(withBundleIdentifier: "com.trungluong.AgentBarKeyTestHelper") {
            stale.forceTerminate()
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentbar-keytest-\(getpid())")
        let app = dir.appendingPathComponent("AgentBarKeyTestHelper.app")
        let macos = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        let src = dir.appendingPathComponent("helper.swift")
        try helperSource.write(to: src, atomically: true, encoding: .utf8)
        try #"""
        <?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>CFBundleExecutable</key><string>helper</string>
        <key>CFBundleIdentifier</key><string>com.trungluong.AgentBarKeyTestHelper</string>
        <key>CFBundlePackageType</key><string>APPL</string></dict></plist>
        """#.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
        compile.arguments = ["-O", "-o", macos.appendingPathComponent("helper").path, src.path]
        try compile.run(); compile.waitUntilExit()
        guard compile.terminationStatus == 0 else { return nil }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-n", app.path]
        try open.run(); open.waitUntilExit()
        for _ in 0..<100 {
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.trungluong.AgentBarKeyTestHelper").first,
               NSWorkspace.shared.frontmostApplication?.processIdentifier == running.processIdentifier {
                return running
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        return NSRunningApplication.runningApplications(withBundleIdentifier: "com.trungluong.AgentBarKeyTestHelper").first
    }

    // MARK: - Rig

    /// Turns BOTH the main queue (Task.sleep) and the main run loop: the test host drives the main thread
    /// with dispatch, not a run loop, so SwiftUI's window updates (run-loop observers) would never land.
    private func pump(_ seconds: Double = 0.15) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            try? await Task.sleep(for: .milliseconds(20))
            Self.spinRunLoop()
        }
    }

    private static func spinRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        for window in NSApp.windows where window.isVisible { window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
    }

    private func state(_ window: NSWindow?) -> String {
        let front = NSWorkspace.shared.frontmostApplication
        return "active=\(NSApp.isActive) front=\(front?.localizedName ?? "nil")(\(front?.processIdentifier ?? 0)) self=\(getpid()) "
            + "keyWindow=\(NSApp.keyWindow.map { "\($0.title)(visible=\($0.isVisible))" } ?? "nil") target.isKey=\(window?.isKeyWindow ?? false) "
            + "fr=\(window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil") "
            + "occl=\(window?.occlusionState.contains(.visible) ?? false) boxes=\(Self.boxes(in: window?.contentView).count) allBoxes=\(NSApp.windows.map { Self.boxes(in: $0.contentView).count }) frame=\(window.map { NSStringFromRect($0.frame) } ?? "")"
    }

    private static func tree(_ view: NSView?) -> [String] {
        guard let view else { return [] }
        return [String(String(describing: type(of: view)).prefix(70))] + view.subviews.flatMap { tree($0) }
    }

    private static func boxes(in view: NSView?) -> [AnswerTextView] {
        guard let view else { return [] }
        return ((view as? AnswerTextView).map { [$0] } ?? []) + view.subviews.flatMap { boxes(in: $0) }
    }

    /// What a physical key press needs to land in the box: the box's window key, the box its first responder.
    private func expectKeyboardInBox(_ window: NSWindow, _ path: String, log: [String]) {
        print("CROSSAPP \(path): \(log.filter { !$0.hasPrefix("tree=") })")
        #expect(window.isKeyWindow, "\(path): card window not key — \(log)")
        #expect(window.firstResponder is AnswerTextView, "\(path): box not first responder — \(log)")
    }

    private func withHelper(_ body: () async throws -> Void) async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        // A test process starts out "active". AgentBar in real use is not: its panels never activate it, and
        // its own activation request (`TextInputActivation`, for dictation) is not granted while another app
        // the user is working in stays frontmost. This host runs no AppKit event loop, so the request stays
        // unprocessed here too, which is that same state.
        NSApp.deactivate()
        let helper = try Self.launchHelper()
        try #require(helper != nil, "helper app did not launch")
        defer { helper?.forceTerminate(); NSApp.deactivate() }
        try #require(NSWorkspace.shared.frontmostApplication?.processIdentifier == helper?.processIdentifier, "helper is not frontmost")
        try await body()
    }

    private func makeModel(_ agents: [AgentSnapshot]) -> AgentPanelModel {
        let defaults = makeScratchDefaults("cross-app-keys")
        let model = AgentPanelModel(
            store: FrecencyStore(defaults: defaults),
            triageStore: TriageStore(defaults: defaults),
            answer: AnswerCardModel(loadSessionContext: { _ in .empty }, openFile: { _ in }),
            permission: PermissionCardModel(loadSessionContext: { _ in .empty }),
            now: { F.now }
        )
        model.statusSource = MessageFakeSource()
        model.receive(F.snapshot(agents))
        return model
    }

    private func makeActivation() -> TextInputActivation {
        TextInputActivation(focus: SystemAppFocus(), isEnabled: { true }, isShortcutModifierHeld: { false })
    }

    /// Near-invisible but NOT fully transparent: a window at alpha 0 counts as occluded, and SwiftUI then
    /// stops updating it (the Message box never got built). The panel re-places itself on every resize, so
    /// it is not moved off-screen; the tests run on the idle Mac.
    private func hideOffScreen(_ window: NSWindow) {
        window.alphaValue = 0.02
    }

    /// Samples the state for ~1.5 s after the box appears: activation and SwiftUI's focus pass land late.
    private func settle(_ window: NSWindow) async -> [String] {
        var log: [String] = []
        for step in 0..<10 {
            await pump(0.15)
            if step % 3 == 0 || step == 9 { log.append(state(window)) }
        }
        return log
    }

    // MARK: - Tests

    @Test(arguments: [false, true])
    func messageBoxGetsTheKeyboardWhileAnotherAppIsFrontmost(fromCorner: Bool) async throws {
        try await withHelper {
            let model = makeModel([F.agent("m", section: .working)])
            let controller = AgentPanelController(model: model, activation: makeActivation())
            // As in the app: the corner window lives the whole time (hidden), hosting the same model.
            let corner = CornerTabWindowController(model: model, onClick: {}, onDismiss: {}, onOpenSettings: {})
            defer { corner.removeNow() }
            // Used earlier in the session, so both are laid out and keep following the model while hidden.
            let focus = FocusOverlayController(model: model, activation: makeActivation())
            focus.show(); await pump(0.3); focus.hide(restoringFocus: false)
            corner.showCard(); await pump(0.3); corner.removeNow()
            await pump(0.4)
            controller.show(fromCorner: fromCorner)
            defer { controller.hide(restoringFocus: false) }
            let window = try #require(NSApp.windows.first { $0 is CommandBarPanel && $0.isVisible })
            hideOffScreen(window)
            await pump(0.4)
            var log = [state(window)]
            _ = model.press(.message, on: "m")
            // The panel resizes for the card from INSIDE the open's will-change, so the window lays out the old
            // state and the card shows on the next model change; in the app that is the next dashboard poll.
            await pump()
            model.receive(F.snapshot([F.agent("m", section: .working)]))
            log += await settle(window)
            #expect(model.message.isOpen, "\(String(describing: model.message.card?.phase)) \(log)")
            log.append("tree=" + Self.tree(window.contentView).joined(separator: "|"))
            log.append("phase=\(String(describing: model.message.card?.phase)) cardOpen=\(model.isCardOpen)")
            expectKeyboardInBox(window, fromCorner ? "message/corner-hover" : "message/shortcut", log: log)
        }
    }

    @Test func otherBoxGetsTheKeyboardWhileAnotherAppIsFrontmost() async throws {
        try await withHelper {
            let model = makeModel([A.blockedAgent("q", blocker: .question(A.question()))])
            let controller = AgentPanelController(model: model, activation: makeActivation())
            // As in the app: the corner window lives the whole time and has shown a card earlier.
            let corner = CornerTabWindowController(model: model, onClick: {}, onDismiss: {}, onOpenSettings: {})
            defer { corner.removeNow() }
            corner.showCard(); await pump(0.3); corner.removeNow(); await pump(0.3)
            controller.show()
            defer { controller.hide(restoringFocus: false) }
            let window = try #require(NSApp.windows.first { $0 is CommandBarPanel && $0.isVisible })
            hideOffScreen(window)
            await pump(0.4)
            model.openCardForCorner(agentID: "q")
            await pump()
            var log = [state(window)]
            model.answer.clickOption(at: 2)
            log += await settle(window)
            expectKeyboardInBox(window, "other/panel", log: log)
        }
    }

    /// Which window SwiftUI updates last (and so which box's "take the keyboard" runs last) follows the
    /// order the windows started watching the model, so both orders are run: the hidden main panel's copy
    /// of the box ran last in one of them and took key status away from the visible card.
    @Test(arguments: [false, true])
    func cornerCardOtherBoxGetsTheKeyboardWhileAnotherAppIsFrontmost(cornerWindowFirst: Bool) async throws {
        try await withHelper {
            let model = makeModel([A.blockedAgent("q", blocker: .question(A.question()))])
            let activation = makeActivation()
            var corner: CornerTabWindowController?
            if cornerWindowFirst { corner = CornerTabWindowController(model: model, onClick: {}, onDismiss: {}, onOpenSettings: {}) }
            // As in the app: the main panel lives the whole time (hidden), hosting the same model.
            let mainPanel = AgentPanelController(model: model, activation: activation)
            defer { mainPanel.hide(restoringFocus: false) }
            // Used earlier in the session: its view is laid out and keeps following the model while hidden.
            // (Ordered in and out without becoming key, so the test host's missing event loop plays no part.)
            let main = try #require(NSApp.windows.first { $0 is CommandBarPanel })
            main.setFrame(NSRect(x: 0, y: 0, width: 660, height: 400), display: false)
            main.alphaValue = 0.02
            main.orderFrontRegardless()
            await pump(0.3)
            main.orderOut(nil)
            await pump(0.3)
            if corner == nil { corner = CornerTabWindowController(model: model, onClick: {}, onDismiss: {}, onOpenSettings: {}) }
            let cornerWindow = try #require(corner)
            defer { cornerWindow.removeNow(); activation.panelDidHide(restoringFocus: false) }
            model.openCardForCorner(agentID: "q")
            activation.panelDidShow()
            let observer = NotificationCenter.default.addObserver(forName: AnswerTextView.didAppearNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { activation.textInputAppeared() }
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            cornerWindow.showCard()
            let window = try #require(NSApp.windows.first { $0.title == "AgentBar corner tab" && $0.isVisible })
            hideOffScreen(window)
            await pump(0.4)
            hideOffScreen(window)   // the slide-in may have moved it back
            var log = [state(window)]
            model.answer.clickOption(at: 2)
            log += await settle(window)
            expectKeyboardInBox(window, "other/corner-card(cornerWindowFirst=\(cornerWindowFirst))", log: log)
            #expect(!main.isKeyWindow, "the hidden main panel took key status")

            // Every AgentBar window draws the same model, so a hidden one (the main panel, ordered out but
            // still following it) builds its OWN copy of the box — which of the copies runs its "take the
            // keyboard" last depends on update order. Here the hidden copy appears last, deterministically.
            // (Stand-in for its SwiftUI copy: the main panel window itself gets a box in place of its content.)
            let hidden = main
            let copy = NSHostingView(rootView: MultiLineAnswerField(text: .constant(""), onSubmit: {}, onLeave: {}))
            copy.frame = NSRect(x: 0, y: 0, width: 300, height: 80)
            hidden.contentView?.addSubview(copy)
            defer { copy.removeFromSuperview() }
            log = await settle(window)
            #expect(!hidden.isKeyWindow, "a hidden window's copy of the box took key status — \(log)")
            expectKeyboardInBox(window, "other/corner-card + hidden copy", log: log)
        }
    }
}
