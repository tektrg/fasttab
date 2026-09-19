import Foundation
import Testing
@testable import AgentBar

/// What the feed says about permission boxes, and the buttons that follow from it.
struct PermissionPayloadTests {
    typealias P = PermissionFixtures

    private func snapshot(permissionField: Any?) throws -> StatusSnapshot {
        let data = StatusFixtures.data("state-healthy") { object in
            var computed = object["computed"] as! [String: Any]
            var rows = computed["needsYou"] as! [[String: Any]]
            if let permissionField { rows[1]["permission"] = permissionField }
            computed["needsYou"] = rows
            object["computed"] = computed
        }
        return try StatusSnapshotBuilder.snapshot(fromJSON: data, fetchedAt: StatusFixtures.serverNow)
    }

    private func blocker(_ snapshot: StatusSnapshot) throws -> AgentBlocker? {
        try #require(snapshot.agent(labelled: "agent-two")).blocker
    }

    // MARK: - Decoding: present, null, absent

    @Test func aParsedPermissionMakesTheRowReviewable() throws {
        let object = try JSONSerialization.jsonObject(with: Data(P.json(P.bash).utf8))
        #expect(try blocker(snapshot(permissionField: object)) == .permissionReview(P.bash))
    }

    @Test func aNullPermissionIsTheOldPlainBlockedRow() throws {
        #expect(try blocker(snapshot(permissionField: NSNull())) == .permission)
    }

    @Test func aDashboardThatNeverSendsPermissionStillDecodes() throws {
        #expect(try blocker(snapshot(permissionField: nil)) == .permission)   // the recorded capture has no such field
    }

    @Test func aPermissionMissingPiecesIsNotReviewable() throws {
        let broken: [Any] = [
            ["tool": "Bash", "title": "Do you want to proceed?", "options": [["index": 1, "label": "Yes"], ["index": 2, "label": "No"]]],  // no detail
            ["tool": "Bash", "detail": "ls", "title": "Do you want to proceed?", "options": [["index": 1, "label": "Yes"]]],                   // one option
            ["tool": "Bash", "detail": "ls", "title": "Do you want to proceed?", "options": [["index": 1, "label": "Yes"], ["label": "No"]]],  // option without number
            "not an object",
            [Any](),
        ]
        for permission in broken {
            #expect(try blocker(snapshot(permissionField: permission)) == .permission, "\(permission)")
        }
    }

    @Test func aWholeBoxKeepsEveryStringExactlyAsSent() throws {
        let odd = PermissionPrompt(
            tool: "Bash", detail: "echo \"a\\b\"\n  ok  ", title: "Do you want to proceed?",
            options: [.init(index: 1, label: "Yes  "), .init(index: 2, label: "No, ✓ tell")], cursorIndex: 2
        )
        let decoded = try JSONDecoder().decode(DashboardPermission.self, from: Data(P.json(odd).utf8))
        #expect(decoded.prompt == odd)
    }

    @Test func aPermissionWithoutACursorStillDecodes() throws {
        let json = #"{"tool": "Bash", "detail": "ls", "title": "Do you want to proceed?", "options": [{"index": 1, "label": "Yes"}, {"index": 2, "label": "No"}]}"#
        let decoded = try JSONDecoder().decode(DashboardPermission.self, from: Data(json.utf8))
        #expect(decoded.prompt?.cursorIndex == nil)
        #expect(decoded.prompt?.choices == [.allow, .deny])
    }

    // MARK: - Buttons

    private func buttons(_ agent: AgentSnapshot) -> [RowButton] { RowButtons.available(for: agent).map(\.button) }

    @Test func aReviewableBoxOffersReviewAndParkInsteadOfOpenTerminal() {
        #expect(buttons(P.agent("a", P.bash)) == [.review, .park])
        #expect(RowButtons.usableButtons(for: P.agent("a", P.bash)) == [.review, .park])
    }

    @Test func aPlainBlockedRowKeepsOpenTerminal() {
        #expect(buttons(P.agent("a", nil)) == [.openTerminal, .park])
    }

    @Test func reviewIsRedLikeTheOtherBlockedActions() {
        #expect(RowButton.review.isBlockedAction)
        #expect(RowButton.review.title == "Review")
        #expect(RowButton.review.sessionAction == nil)
    }

    @Test func pressingReviewPlansOpeningTheCard() {
        #expect(RowActionMachine.plan(pressing: .review, current: nil) == .openReview)
        #expect(RowActionMachine.plan(pressing: .review, current: .busy(.done)) == .ignore)
    }

    @Test func aParkedReviewableAgentHasNoBlockedActions() {
        let agent = P.agent("a", P.bash).placed(in: .parked)
        #expect(buttons(agent) == [.unpark, .done])
    }
}
