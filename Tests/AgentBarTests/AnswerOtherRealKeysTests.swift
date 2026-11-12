import AppKit
import SwiftUI
import Testing
@testable import AgentBar
import IndieCommandBar

/// Bug 2026-11-12 (reopened): the answer card's "Other" free text lost typed keys in the real app.
/// The earlier test only checked a pure routing decision. These build the REAL windows (main panel,
/// Focus mode, corner card), choose Other, and post real keyDown NSEvents through `NSApp.sendEvent`
/// (which delivers to the KEY window, as AppKit does), then check the text. The corner card failed:
/// a click on the Other row showed the box with a caret, but its window never became key, so every key
/// went elsewhere. Needs a window server (GUI session). Env-gated and run on its own: in the parallel full
/// suite other tests' windows take key status. Windows are moved off-screen and made transparent so
/// nothing shows on the user's display.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["AGENTBAR_REAL_KEYS"] == "1",
                              "real windows + key window: run alone, `AGENTBAR_REAL_KEYS=1 swift test --filter AnswerOtherRealKeysTests`"))
struct AnswerOtherRealKeysTests {
    typealias A = AnswerFixtures
    typealias F = AgentListFixtures

    private func makeRig() -> (AgentPanelController, AgentPanelModel, NSWindow) {
        _ = NSApplication.shared
        let defaults = makeScratchDefaults("other-real-keys")
        let model = AgentPanelModel(
            store: FrecencyStore(defaults: defaults),
            triageStore: TriageStore(defaults: defaults),
            answer: AnswerCardModel(loadSessionContext: { _ in .empty }, openFile: { _ in }),
            permission: PermissionCardModel(loadSessionContext: { _ in .empty }),
            now: { F.now }
        )
        model.statusSource = PermissionFakeSource()
        model.receive(F.snapshot([A.blockedAgent("q", blocker: .question(A.question()))]))
        let activation = TextInputActivation(focus: FakeAppFocus(), isEnabled: { true }, isShortcutModifierHeld: { false })
        let controller = AgentPanelController(model: model, activation: activation)
        controller.show()
        let window = NSApp.windows.first { $0 is CommandBarPanel && $0.isVisible }!
        hideOffScreen(window)
        return (controller, model, window)
    }

    /// Lets the main queue AND the run loop turn (a nested RunLoop.run inside a main-queue job never
    /// drains the main queue, so `DispatchQueue.main.async` work would never run).
    /// Keeps the window key and on-screen-ordered for AppKit, but invisible to the user.
    private func hideOffScreen(_ window: NSWindow) {
        window.alphaValue = 0
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
    }

    private func pump(_ seconds: Double = 0.15) async {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    private static let keyCodes: [Character: UInt16] = [
        "d": 2, " ": 49, "4": 21, "2": 19, "o": 31, "k": 40, "3": 20,
    ]

    private func type(_ text: String, into window: NSWindow, between: (() -> Void)? = nil) async -> [String] {
        var log: [String] = []
        for ch in text {
            between?()
            await pump(0.05)
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: String(ch),
                charactersIgnoringModifiers: String(ch), isARepeat: false, keyCode: Self.keyCodes[ch]!
            )!
            let responder = (NSApp.keyWindow === window ? "" : "NOT-KEY(key=\(NSApp.keyWindow.map { String(describing: Swift.type(of: $0)) } ?? "none")) ") + (window.firstResponder.map { String(describing: Swift.type(of: $0)) } ?? "nil")
            NSApp.sendEvent(event)
            let up = NSEvent.keyEvent(
                with: .keyUp, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: String(ch),
                charactersIgnoringModifiers: String(ch), isARepeat: false, keyCode: Self.keyCodes[ch]!
            )!
            NSApp.sendEvent(up)
            await pump(0.05)
            log.append("'\(ch)' -> \(responder)")
        }
        return log
    }

    /// Waits (≤3 s) for a condition the UI reaches asynchronously; parallel suites slow the main thread.
    private func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<60 where !condition() { await pump(0.05) }
    }

    private func check(_ model: AgentPanelModel, _ window: NSWindow, path: String, between: (() -> Void)? = nil) async {
        await waitFor { window.firstResponder is AnswerTextView }
        let log = await type("dd 42 ok", into: window, between: between)
        let text = model.answer.card?.state.otherText ?? "<no card>"
        #expect(model.answer.card?.state.phase == .typingOther, "\(path)")
        #expect(text == "dd 42 ok", "\(path): \(log)")
        #expect(model.query.isEmpty, "\(path)")
    }

    @Test func keyboardPathOtherKeepsEveryKey() async {
        let (controller, model, window) = makeRig()
        defer { controller.hide(restoringFocus: false) }
        await pump()
        model.openCardForCorner(agentID: "q")
        await pump()
        window.makeKey()   // other suites' windows may have taken key status in parallel runs
        await waitFor { model.answer.card != nil && window.firstResponder is NSTextView }
        let pick = await type("3", into: window)
        #expect(model.answer.card?.state.phase == .typingOther, "3 went: \(pick) key=\(window.isKeyWindow) fr=\(String(describing: window.firstResponder))")   // the Other row's number
        await check(model, window, path: "keyboard")
    }

    @Test func clickPathOtherKeepsEveryKey() async {
        let (controller, model, window) = makeRig()
        defer { controller.hide(restoringFocus: false) }
        model.openCardForCorner(agentID: "q")
        await pump()
        model.answer.clickOption(at: 2)
        await check(model, window, path: "click")
    }

    @Test func otherKeepsEveryKeyWhileTheFeedUpdates() async {
        let (controller, model, window) = makeRig()
        defer { controller.hide(restoringFocus: false) }
        await pump()
        model.openCardForCorner(agentID: "q")
        await pump()
        window.makeKey()   // other suites' windows may have taken key status in parallel runs
        await waitFor { model.answer.card != nil && window.firstResponder is NSTextView }
        let pick = await type("3", into: window)
        #expect(model.answer.card?.state.phase == .typingOther, "3 went: \(pick) key=\(window.isKeyWindow) fr=\(String(describing: window.firstResponder))")
        await check(model, window, path: "feed") {
            model.receive(F.snapshot([A.blockedAgent("q", blocker: .question(A.question()))]))
        }
    }

    @Test func otherKeepsEveryKeyWhenThePanelBecomesKeyAgain() async {
        let (controller, model, window) = makeRig()
        defer { controller.hide(restoringFocus: false) }
        await pump()
        model.openCardForCorner(agentID: "q")
        await pump()
        window.makeKey()   // other suites' windows may have taken key status in parallel runs
        await waitFor { model.answer.card != nil && window.firstResponder is NSTextView }
        let pick = await type("3", into: window)
        #expect(model.answer.card?.state.phase == .typingOther, "3 went: \(pick) key=\(window.isKeyWindow) fr=\(String(describing: window.firstResponder))")
        await check(model, window, path: "rekey") {
            window.resignKey(); window.makeKey()
        }
    }

    @Test func focusModeOtherKeepsEveryKey() async {
        let (controller, model, _) = makeRig()
        controller.hide(restoringFocus: false)
        let focus = FocusOverlayController(model: model, activation: TextInputActivation(
            focus: FakeAppFocus(), isEnabled: { true }, isShortcutModifierHeld: { false }))
        focus.show()
        defer { focus.hide(restoringFocus: false) }
        await pump(0.4)
        let window = NSApp.windows.first { $0 is CommandBarPanel && $0.isVisible && $0.level == FocusOverlayController.level }!
        hideOffScreen(window)
        window.makeKey()   // other suites' windows may have taken key status in parallel runs
        await waitFor { model.answer.card != nil && window.firstResponder is NSTextView }
        let pick = await type("3", into: window)
        #expect(model.answer.card?.state.phase == .typingOther, "3 went: \(pick) key=\(window.isKeyWindow) fr=\(String(describing: window.firstResponder))")
        await check(model, window, path: "focus")
    }

    @Test func cornerCardOtherKeepsEveryKey() async {
        let (controller, model, _) = makeRig()
        controller.hide(restoringFocus: false)
        let corner = CornerTabWindowController(model: model, onClick: {}, onDismiss: {}, onOpenSettings: {})
        defer { corner.removeNow() }
        model.openCardForCorner(agentID: "q")
        corner.showCard()
        let window = NSApp.windows.first { $0.title == "AgentBar corner tab" && $0.isVisible }!
        hideOffScreen(window)
        await pump(0.4)
        hideOffScreen(window)   // the slide-in may have moved it back
        model.answer.clickOption(at: 2)
        await check(model, window, path: "corner")
    }
}

