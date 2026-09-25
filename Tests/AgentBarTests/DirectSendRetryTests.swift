import Foundation
import Testing
@testable import AgentBar

/// The retry queue `AgentPanelModel` puts in front of every headless send (Jev routing, Tab-tag
/// compose, Compact/Clear) — `sendDirectMessage`'s doc comment. A `.failed` reply (nothing reached
/// the agent) gets a few quick automatic retries before the footer notice shows; an `.uncertain`
/// reply (may already be sitting typed in the agent's input box) never does, same reason the
/// Message card's own manual "Send again" stays manual (AGENTS.md gotcha 11). Driven through the
/// Compact quick command (`.press(.compact, on:)`), the simplest headless-send entry point, plus
/// Tab-tag compose for the cross-path duplicate guard. Against `MessageFakeSource`, so each attempt
/// is replied to explicitly rather than racing real time; `waitForRequests`/`waitUntil` poll by
/// count, not by wall clock, so these stay correct even when the shared machine is under load
/// (AGENTS.md: "Full-suite runs flake under machine load").
@MainActor
struct DirectSendRetryTests {
    typealias F = AgentListFixtures

    private struct Rig {
        let model: AgentPanelModel
        let source: MessageFakeSource
    }

    /// Tiny delays so a "give up after N tries" test doesn't wait out real backoff.
    private func makeRig(_ agents: [AgentSnapshot], retryDelays: [TimeInterval] = [0.01, 0.01]) -> Rig {
        let defaults = makeScratchDefaults("direct-send-retry-\(UUID().uuidString)")
        let model = AgentPanelModel(
            store: FrecencyStore(defaults: defaults),
            triageStore: TriageStore(defaults: defaults),
            routedNoteStore: RoutedNoteStore(defaults: defaults),
            directSendRetryDelays: retryDelays,
            now: { F.now }
        )
        let source = MessageFakeSource()
        model.statusSource = source
        model.receive(F.snapshot(agents))
        return Rig(model: model, source: source)
    }

    private func working(_ id: String = "a", label: String? = nil) -> AgentSnapshot {
        F.agent(id, label: label, section: .working)
    }

    @Test func aFailedAttemptIsRetriedAndSucceedsOnTheSecondTry() async {
        let rig = makeRig([working()])
        #expect(rig.model.press(.compact, on: "a") == nil)
        await rig.source.waitForRequests(1)
        // Row still shows the sending state right through a failed first attempt and the backoff gap.
        #expect(rig.model.sendingLabel(for: rig.model.presentation.agents[0]) == MessageCardModel.sendingLabel)
        rig.source.reply(.failed("busy pane"))
        await rig.source.waitForRequests(2)   // the retry landed
        #expect(rig.model.sendingLabel(for: rig.model.presentation.agents[0]) == MessageCardModel.sendingLabel)
        rig.source.reply(.sent(queued: false))
        await waitUntil { rig.model.sentLabel(for: rig.model.presentation.agents[0]) != nil }
        #expect(rig.source.sent == [
            .init(rowId: "a", text: "/compact", confirmed: true),
            .init(rowId: "a", text: "/compact", confirmed: true),
        ])
        #expect(rig.model.footerNotice == nil)   // recovered silently, no notice for a retry that worked
    }

    @Test func exhaustingEveryRetryShowsTheGiveUpNoticeWithTheAttemptCount() async {
        let rig = makeRig([working(label: "worker-1")], retryDelays: [0.01, 0.01])   // 3 attempts total
        #expect(rig.model.press(.compact, on: "a") == nil)
        for _ in 0..<3 {
            await rig.source.waitForRequests(rig.source.sent.count + 1)
            rig.source.reply(.failed("dashboard unreachable"))
        }
        await waitUntil { rig.model.footerNotice != nil }
        #expect(rig.source.sent.count == 3)
        #expect(rig.model.footerNotice?.text == "Couldn't send to worker-1 after 3 tries: dashboard unreachable")
        #expect(rig.model.sendingLabel(for: rig.model.presentation.agents[0]) == nil)   // gave up, row is idle again
    }

    @Test func anUncertainReplyIsNeverRetried() async {
        let rig = makeRig([working(label: "worker-1")])
        #expect(rig.model.press(.compact, on: "a") == nil)
        await rig.source.waitForRequests(1)
        rig.source.reply(.uncertain("may have gone through"))
        await waitUntil { rig.model.footerNotice != nil }
        // No second attempt turns up, even generously waiting for the retry window to have run.
        for _ in 0..<50 where rig.source.sent.count < 2 { await Task.yield() }
        #expect(rig.source.sent.count == 1)
        #expect(rig.model.footerNotice?.text == "Message to worker-1: may have gone through")
    }

    @Test func aSecondHeadlessSendToTheSameAgentWhileOneIsAlreadyPendingIsRefusedNotClobbered() async {
        let rig = makeRig([working(label: "worker-1")])
        let agent = working(label: "worker-1")   // sentLabel/sendingLabel only key off `.id`; `presentation.agents`
                                                   // is not used below since query-filtering (next) can empty it
        #expect(rig.model.press(.compact, on: "a") == nil)   // starts attempt 1; marks "a" pending right away
        await rig.source.waitForRequests(1)
        // Race a Tab-tag compose send to the SAME agent while the compact send is still outstanding
        // (tag-compose does not go through `isPressable`, unlike a second row-button press, so it
        // actually reaches the shared guard instead of being blocked by the row's own sending state).
        rig.model.tagSelected()
        rig.model.query = "a second message"
        rig.model.activateSelected()
        #expect(rig.model.footerNotice?.text == "Still retrying an earlier message to worker-1 — wait a moment before sending another.")
        #expect(rig.model.taggedAgentID == "a")   // refused, not sent: tag and typed text both survive
        #expect(rig.model.query == "a second message")
        #expect(rig.source.sent.count == 1)   // the race never reached the dashboard a second time
        // The original send still lands on its own, unaffected by the refused second one.
        rig.source.reply(.failed("busy pane"))
        await rig.source.waitForRequests(2)   // its own retry, not the refused second send
        rig.source.reply(.sent(queued: false))
        await waitUntil { rig.model.sentLabel(for: agent) != nil }
        #expect(rig.source.sent.map(\.text) == ["/compact", "/compact"])
    }

    @Test func switchingDashboardsSilentlyDropsAPendingRetry() async {
        let rig = makeRig([working(label: "worker-1")])
        #expect(rig.model.press(.compact, on: "a") == nil)
        await rig.source.waitForRequests(1)
        rig.source.reply(.failed("busy pane"))   // queued on MainActor, not yet processed
        rig.model.useDashboard(address: "127.0.0.1:9999")   // clears pendingDirectSends before that reply lands
        // The queued reply's retry decision now finds no tracked send for "a" and must drop it, not
        // fall back to "attempt 1" and start a fresh retry cycle against the new dashboard.
        for _ in 0..<50 { await Task.yield() }
        #expect(rig.source.sent.count == 1)
    }
}
