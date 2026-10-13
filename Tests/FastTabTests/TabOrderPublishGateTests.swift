import Foundation
import Testing
@testable import FastTab

@Suite("Tab order publish gate (title flicker)")
struct TabOrderPublishGateTests {
    let id = UUID()
    func slot(title: String, url: String = "https://chat.google.com", pinned: Bool = false) -> OrderedTabSlot {
        OrderedTabSlot(slotID: id, url: url, matchKey: url, title: title, browserName: "Edge", profileName: nil,
                       state: .live, boundTabID: nil, windowIndex: nil, tabIndex: nil, ghostedAt: nil,
                       lastSeenLiveAt: nil, isPinned: pinned, confirmedInBrowser: true)
    }

    @Test func titleFlickerWaitsButRealChangesGoNow() {
        var gate = TabOrderPublishGate()
        let t0 = Date(timeIntervalSince1970: 1_000)
        #expect(gate.decision(for: [slot(title: "Chat")], now: t0) == .publishNow)
        gate.didPublish([slot(title: "Chat")], at: t0)

        let flicker = [slot(title: "Ann messaged you - Chat")]
        #expect(gate.decision(for: flicker, now: t0.addingTimeInterval(2)) == .publishAt(t0.addingTimeInterval(30)))
        #expect(gate.decision(for: flicker, now: t0.addingTimeInterval(31)) == .publishNow)

        #expect(gate.decision(for: [slot(title: "Chat", url: "https://other")], now: t0.addingTimeInterval(2)) == .publishNow)
        #expect(gate.decision(for: [slot(title: "Chat", pinned: true)], now: t0.addingTimeInterval(2)) == .publishNow)
        #expect(gate.decision(for: [], now: t0.addingTimeInterval(2)) == .publishNow)
    }

    @Test func resetSendsTheNextChangeAtOnce() {
        var gate = TabOrderPublishGate()
        let t0 = Date()
        gate.didPublish([slot(title: "A")], at: t0)
        gate.reset()
        #expect(gate.decision(for: [slot(title: "B")], now: t0) == .publishNow)
    }
}
