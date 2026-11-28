import Foundation
import Testing
@testable import AgentBar

/// Chief check-ins (chief redesign item 14): the `checkIn` wire on a Desktop chief, the row words,
/// the settings request/reply, and the tree model's optimistic pace / sleep-time change.
struct ChiefCheckInTests {
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// 2026-11-28 14:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_795_874_400)

    private func checkIn(
        state: ChiefCheckIn.State = .ok, running: Date? = nil, next: Date? = nil, overdue: Int = 0,
        pace: ChiefCheckInPace = .steady, sleep: Bool = false, wake: Bool = false
    ) -> ChiefCheckIn {
        ChiefCheckIn(
            chiefKey: "ssv-shared/digital", state: state, lastCheckInAt: nil, runningSince: running, nextDueAt: next,
            overdueSeconds: overdue, pace: pace, sleepCheckins: sleep, schedule: "every 2h", wakeEnabled: wake,
            lastWakeResult: nil, lastWakeReason: nil
        )
    }

    // MARK: - Wire

    @Test func aDesktopChiefsCheckInMapsOntoItsTreeNode() throws {
        let json = """
        {"agentTree": {"chiefs": [{"id": "c1", "label": "Digital", "children": [],
          "checkIn": {"chiefKey": "ssv-shared/digital", "state": "overdue", "lastCheckInAt": 1795870000,
                      "checkInRunningSince": null, "nextDueAt": 1795881600, "overdueSec": 2400,
                      "pace": "pace-out", "sleepCheckins": true, "schedule": "every 4h", "wakeEnabled": false,
                      "lastWake": {"result": "deferred", "reason": "chief busy"}}}],
          "unassigned": [], "parentGone": []}, "computed": {"agents": [], "needsYou": []}}
        """
        let payload = try JSONDecoder().decode(DashboardPayload.self, from: Data(json.utf8))
        let tree = try #require(AgentTreeMapper.map(payload.agentTree))
        let checkIn = try #require(tree.chiefs.first?.checkIn)
        #expect(checkIn.chiefKey == "ssv-shared/digital")
        #expect(checkIn.state == .overdue)
        #expect(checkIn.overdueSeconds == 2400)
        #expect(checkIn.pace == .paceOut)
        #expect(checkIn.sleepCheckins == true)
        #expect(checkIn.lastCheckInAt == Date(timeIntervalSince1970: 1_795_870_000))
        #expect(checkIn.runningSince == nil)
        #expect(checkIn.lastWakeResult == "deferred")
        #expect(tree.chiefCheckIn(forKey: "ssv-shared/digital") == checkIn)
    }

    @Test func aChiefWithoutCheckInOrWithAnUnknownStateHasNone() throws {
        let json = """
        {"agentTree": {"chiefs": [{"id": "c1", "label": "A", "children": []},
                                  {"id": "c2", "label": "B", "children": [], "checkIn": {"chiefKey": "p/b", "state": "weird"}},
                                  {"id": "c3", "label": "C", "children": [], "checkIn": {"state": "ok"}}],
          "unassigned": [], "parentGone": []}, "computed": {"agents": [], "needsYou": []}}
        """
        let payload = try JSONDecoder().decode(DashboardPayload.self, from: Data(json.utf8))
        let tree = try #require(AgentTreeMapper.map(payload.agentTree))
        #expect(tree.chiefs.map(\.id) == ["c1", "c2", "c3"])   // the chiefs themselves survive
        #expect(tree.chiefs.allSatisfy { $0.checkIn == nil })
    }

    @Test func anUnknownPaceFallsBackToSteady() throws {
        let wire = try JSONDecoder().decode(ChiefCheckInWire.self, from: Data(#"{"chiefKey": "p/c", "state": "ok", "pace": 7}"#.utf8))
        #expect(wire.domain?.pace == .steady)
        #expect(wire.domain?.sleepCheckins == false)
    }

    // MARK: - Words

    @Test func badgeSaysOverdueWithHowLong() {
        let badge = ChiefCheckInText.badge(checkIn(state: .overdue, overdue: 2400), now: now, calendar: Self.utc)
        #expect(badge.text == "Overdue 40m")
        #expect(badge.tone == .danger)
    }

    @Test func aRunningCheckInBeatsDueOrNext() {
        let running = checkIn(state: .due, running: now.addingTimeInterval(-600))
        #expect(ChiefCheckInText.badge(running, now: now, calendar: Self.utc).text == "Check-in running")
        // …but an overdue chief stays overdue even with a stale "running" marker.
        let overdue = checkIn(state: .overdue, running: now.addingTimeInterval(-600), overdue: 600)
        #expect(ChiefCheckInText.badge(overdue, now: now, calendar: Self.utc).tone == .danger)
    }

    @Test func nextIsAClockTodayAndADayOtherwise() {
        let today = checkIn(next: now.addingTimeInterval(2 * 3600 + 7 * 60))
        #expect(ChiefCheckInText.badge(today, now: now, calendar: Self.utc).text == "Next 16:07")
        let monday = checkIn(next: Date(timeIntervalSince1970: 1_796_026_020))   // Mon 2026-11-30 08:07 UTC
        #expect(ChiefCheckInText.badge(monday, now: now, calendar: Self.utc).text == "Next Mon 08:07")
    }

    @Test func quietGoneAndNoScheduleAreMuted() {
        for state in [ChiefCheckIn.State.quiet, .gone, .noSchedule] {
            #expect(ChiefCheckInText.badge(checkIn(state: state), now: now, calendar: Self.utc).tone == .muted)
        }
    }

    @Test func detailLinesSayWhoWakesTheChief() {
        let tracked = ChiefCheckInText.detailLines(checkIn(), now: now, calendar: Self.utc)
        #expect(tracked.contains("Last check-in: none seen"))
        #expect(tracked.contains { $0.hasPrefix("Tracked only") })
        let waking = ChiefCheckInText.detailLines(checkIn(wake: true), now: now, calendar: Self.utc)
        #expect(waking.contains { $0.hasPrefix("The dashboard wakes") })
    }

    // MARK: - Optimistic apply

    @Test func goingQuietClearsNextAndOverdue() {
        let quiet = checkIn(state: .overdue, next: now, overdue: 900).applying(pace: .quiet, sleepCheckins: nil)
        #expect(quiet.state == .quiet)
        #expect(quiet.nextDueAt == nil)
        #expect(quiet.overdueSeconds == 0)
    }

    @Test func leavingQuietShowsOkUntilTheDashboardAnswers() {
        let back = checkIn(state: .quiet, pace: .quiet).applying(pace: .rush, sleepCheckins: nil)
        #expect(back.state == .ok)
        #expect(back.pace == .rush)
    }

    @Test func theSleepToggleKeepsThePace() {
        let changed = checkIn(pace: .paceOut).applying(pace: nil, sleepCheckins: true)
        #expect(changed.pace == .paceOut)
        #expect(changed.sleepCheckins == true)
        #expect(checkIn().isUnchanged(pace: .steady, sleepCheckins: false))
        #expect(!checkIn().isUnchanged(pace: nil, sleepCheckins: true))
    }

    // MARK: - Request / reply

    private let endpoint = DashboardEndpoint(baseURL: URL(string: "http://127.0.0.1:4799")!)

    @Test func settingsRequestSendsOnlyTheFieldsGiven() throws {
        let request = endpoint.chiefSettingsRequest(chiefKey: "ssv-shared/digital", pace: .paceOut, sleepCheckins: nil)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/chief/settings")
        let data = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["chief"] as? String == "ssv-shared/digital")
        #expect(json["pace"] as? String == "pace-out")
        #expect(Set(json.keys) == ["chief", "pace"])
        let sleep = endpoint.chiefSettingsRequest(chiefKey: "k", pace: nil, sleepCheckins: true)
        let sleepData = try #require(sleep.httpBody)
        let sleepJSON = try #require(JSONSerialization.jsonObject(with: sleepData) as? [String: Any])
        #expect(Set(sleepJSON.keys) == ["chief", "sleepCheckins"])
    }

    private func source(_ json: String, status: Int = 200) -> DashboardStatusSource {
        DashboardStatusSource(endpoint: endpoint, transport: ScriptedDashboardTransport { _ in .body(Data(json.utf8), statusCode: status) })
    }

    @Test func anOkReplyCarriesTheDashboardsNewTimer() async {
        let outcome = await source(#"{"ok": true, "settings": {}, "checkIn": {"chiefKey": "p/c", "state": "quiet", "pace": "quiet"}}"#)
            .updateChiefCheckIn(chiefKey: "p/c", pace: .quiet, sleepCheckins: nil)
        guard case .updated(let checkIn) = outcome else { Issue.record("expected updated, got \(outcome)"); return }
        #expect(checkIn?.state == .quiet)
    }

    @Test func aRefusalCarriesTheDashboardsWords() async {
        let outcome = await source(#"{"ok": false, "error": "unknown chief 'p/x'"}"#, status: 404)
            .updateChiefCheckIn(chiefKey: "p/x", pace: .rush, sleepCheckins: nil)
        #expect(outcome == .failed("unknown chief 'p/x'"))
    }

    @Test func anUnreachableDashboardFails() async {
        let source = DashboardStatusSource(endpoint: endpoint, transport: ScriptedDashboardTransport { _ in .fail })
        let outcome = await source.updateChiefCheckIn(chiefKey: "p/c", pace: .rush, sleepCheckins: nil)
        #expect(outcome == .failed("Can't reach the status dashboard."))
    }
}

/// The tree model's pace / sleep change: optimistic, then the dashboard's word, reverted on failure.
@MainActor
struct ChiefCheckInModelTests {
    final class FakeEditing: AgentTreeEditing, @unchecked Sendable {
        private let lock = NSLock()
        private var callsStorage: [String] = []
        private var replyStorage: ChiefCheckInSettingsOutcome = .updated(nil)
        var calls: [String] { lock.withLock { callsStorage } }
        var reply: ChiefCheckInSettingsOutcome {
            get { lock.withLock { replyStorage } }
            set { lock.withLock { replyStorage = newValue } }
        }

        func attachToTree(child: String, parent: String, confirmCrossProject: Bool) async -> AttachOutcome { .attached(warning: nil) }
        func detachFromTree(child: String) async -> DetachOutcome { .detached }
        func updateChiefCheckIn(chiefKey: String, pace: ChiefCheckInPace?, sleepCheckins: Bool?) async -> ChiefCheckInSettingsOutcome {
            lock.withLock { callsStorage.append("\(chiefKey) \(pace?.rawValue ?? "-") \(sleepCheckins.map(String.init) ?? "-")") }
            return reply
        }
    }

    private func checkIn(pace: ChiefCheckInPace = .steady, state: ChiefCheckIn.State = .ok) -> ChiefCheckIn {
        ChiefCheckIn(chiefKey: "p/digital", state: state, lastCheckInAt: nil, runningSince: nil, nextDueAt: nil,
                     overdueSeconds: 0, pace: pace, sleepCheckins: false, schedule: "", wakeEnabled: false,
                     lastWakeResult: nil, lastWakeReason: nil)
    }

    private func model(_ editing: FakeEditing) -> AgentTreeModel {
        let model = AgentTreeModel(editing: editing)
        let chief = AgentTreeNode(id: "c1", label: "Digital", project: "p", projectRoot: nil, machine: "local", paneId: nil,
                                  alive: true, status: nil, crossProject: false, isChiefMode: true, checkIn: checkIn())
        let tree = AgentTree(generatedAt: nil, chiefs: [chief], unassigned: [], parentGone: [])
        model.receive(StatusSnapshot(agents: [], health: .ok, fetchedAt: Date(), boardIsCurrent: true, agentTree: tree))
        return model
    }

    @Test func aPaceChangeShowsAtOnceThenTakesTheDashboardsTimer() async {
        let editing = FakeEditing()
        editing.reply = .updated(checkIn(pace: .rush, state: .due))
        let model = model(editing)
        model.updateChiefCheckIn(chiefKey: "p/digital", pace: .rush)
        #expect(model.tree?.chiefs.first?.checkIn?.pace == .rush)   // optimistic
        await waitUntil { model.tree?.chiefs.first?.checkIn?.state == .due }
        #expect(editing.calls == ["p/digital rush -"])
    }

    @Test func aFailedChangeIsRevertedAndShown() async {
        let editing = FakeEditing()
        editing.reply = .failed("nope")
        let model = model(editing)
        model.updateChiefCheckIn(chiefKey: "p/digital", sleepCheckins: true)
        #expect(model.tree?.chiefs.first?.checkIn?.sleepCheckins == true)
        await waitUntil { model.errorMessage != nil }
        #expect(model.errorMessage == "nope")
        #expect(model.tree?.chiefs.first?.checkIn?.sleepCheckins == false)
    }

    @Test func choosingTheCurrentPaceSendsNothing() async {
        let editing = FakeEditing()
        let model = model(editing)
        model.updateChiefCheckIn(chiefKey: "p/digital", pace: .steady)
        model.updateChiefCheckIn(chiefKey: "p/unknown", pace: .rush)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(editing.calls.isEmpty)
    }
}
