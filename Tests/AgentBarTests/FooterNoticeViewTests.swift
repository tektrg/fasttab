import AppKit
import SwiftUI
import Testing
@testable import AgentBar

/// The ✕ on a failure notice must take a real mouse click. A tint drawn as an overlay above the
/// row once swallowed every click (esc still worked), so this drives actual mouse events
/// through a window instead of calling the button's action.
@MainActor @Suite(.serialized)
struct FooterNoticeViewTests {
    private final class Counter { var count = 0 }
    private final class KeyableWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    private func clickCloseButton(of notice: PanelFooterNotice) -> Int {
        let counter = Counter()
        let size = CGSize(width: AgentPanelMetrics.width, height: 32)   // one line of text: the notice is 32pt tall
        let host = NSHostingView(rootView: FooterNoticeView(notice: notice) { counter.count += 1 })
        host.frame = CGRect(origin: .zero, size: size)
        let window = KeyableWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        // The ✕ sits at the right edge, vertically centred.
        let point = CGPoint(x: size.width - 26, y: size.height / 2)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
            )
            if let event { window.sendEvent(event) }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        window.orderOut(nil)
        return counter.count
    }

    @Test func clickingTheCloseButtonDismissesAnActionFailure() {
        #expect(clickCloseButton(of: .actionFailed(AnswerCardModel.noReplyMessage)) == 1)
    }

    @Test func clickingTheCloseButtonDismissesASwitchFailure() {
        #expect(clickCloseButton(of: .switchFailed("pane gone")) == 1)
    }
}
