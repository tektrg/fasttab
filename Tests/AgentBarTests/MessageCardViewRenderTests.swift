import AppKit
import SwiftUI
import Testing
@testable import AgentBar

/// The message card draws in each of its states without breaking layout. Set `MESSAGE_RENDER_DIR` to keep the PNGs.
@MainActor @Suite(.serialized)
struct MessageCardViewRenderTests {
    private func model(configure: (MessageCardModel) -> Void = { _ in }) async -> MessageCardModel {
        let model = MessageCardModel(loadSessionContext: { _ in
            SessionContext(latestMessage: "All three refactors are done and the tests pass. **Next up:** the migration. Want me to start it?", planFile: nil)
        })
        model.statusSource = MessageFakeSource()
        var agent = AgentListFixtures.agent("a", label: "fix-login", project: "aptusfit", section: .working)
        agent.sessionId = "session-1"
        model.open(agent)
        await waitUntil { model.card?.message != .loading }
        configure(model)
        return model
    }

    private func render(_ model: MessageCardModel, name: String) -> NSBitmapImageRep? {
        let height = AgentPanelMetrics.fullBodyHeight()
        let host = NSHostingView(rootView: MessageCardView(message: model, bodyHeight: height).frame(width: AgentPanelMetrics.width, height: height))
        host.frame = CGRect(x: 0, y: 0, width: AgentPanelMetrics.width, height: height)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let path = ProcessInfo.processInfo.environment["MESSAGE_RENDER_DIR"], let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path).appendingPathComponent("message-\(name).png"))
        }
        return bitmap
    }

    @Test func theCardDrawsEmptyTypedFlattenedRefusedAndCounting() async {
        #expect(render(await model(), name: "empty") != nil)
        #expect(render(await model { $0.setDraft("please continue with the migration") }, name: "typed") != nil)
        #expect(render(await model { $0.setDraft("one\ntwo") }, name: "linebreaks") != nil)
        #expect(render(await model { $0.setDraft("/clear") }, name: "slash") != nil)
        #expect(render(await model { $0.setDraft(String(repeating: "word ", count: 380)) }, name: "counter") != nil)
        #expect(render(await model { $0.setDraft(String(repeating: "word ", count: 420)) }, name: "toolong") != nil)
    }

    @Test func theConfirmingAndFailedStatesDraw() async {
        let source = MessageFakeSource()
        let confirming = await model { model in
            model.statusSource = source
            model.setDraft("hello")
            model.pressSend()
        }
        await source.waitForRequests(1)
        #expect(render(confirming, name: "sending") != nil)
        source.reply(.needsConfirmation(reason: ""))
        await waitUntil { confirming.card?.isConfirming == true }
        #expect(render(confirming, name: "confirming") != nil)
        confirming.pressSend()
        await source.waitForRequests(1)
        source.reply(.uncertain("The dashboard took too long to answer. Check the agent's terminal: the message may have gone through."))
        await waitUntil { confirming.card?.mayHaveGoneThrough == true }
        #expect(render(confirming, name: "uncertain") != nil)
    }
}
