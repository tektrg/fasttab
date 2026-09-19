import Foundation
import Testing
@testable import AgentBar

struct AnswerableQuestionTests {
    typealias A = AnswerFixtures

    @Test func aWholePickerIsAnswerable() throws {
        let question = try #require(AnswerableQuestion(A.dashboardQuestion(json: A.questionJSON(labels: ["Apple", "Banana"]))))
        #expect(question.title == "Fruit")
        #expect(question.isMultiSelect == false)
        #expect(question.options.map(\.index) == [1, 2, 3])
        #expect(question.options.map(\.isOther) == [false, false, true])
        #expect(question.options[0].description == "About Apple")
        #expect(question.context == "Some prose above the box.")
        #expect(question.identity == QuestionIdentity(title: "Fruit", question: "Which fruit?"))
    }

    @Test func stringsAreKeptExactlyAsSentBecauseTheDashboardComparesThemVerbatim() throws {
        let raw = "│ Should we persist  it? │ Yes or no?"
        let json = #"{"title": " Padded title ", "question": "\#(raw)", "multi": false, "options": [{"index":1,"label":"A"},{"index":2,"label":"B"}]}"#
        let question = try #require(AnswerableQuestion(A.dashboardQuestion(json: json)))
        #expect(question.identity == QuestionIdentity(title: " Padded title ", question: raw))
        #expect(question.displayQuestion == "Should we persist it? Yes or no?")   // display only
    }

    @Test(arguments: [
        #"{"title": "T", "question": "Q", "options": [{"index":1,"label":"A"},{"index":2,"label":"B"}]}"#,           // no multi
        #"{"question": "Q", "multi": false, "options": [{"index":1,"label":"A"},{"index":2,"label":"B"}]}"#,        // no title
        #"{"title": "T", "multi": false, "options": [{"index":1,"label":"A"},{"index":2,"label":"B"}]}"#,           // no question
        #"{"title": "T", "question": "Q", "multi": false, "options": [{"index":1,"label":"A"}]}"#,                  // one option
        #"{"title": "T", "question": "Q", "multi": false, "options": []}"#,                                         // a preview: no options yet
        #"{"title": "T", "question": "Q", "multi": false, "options": [{"index":1,"label":"A"},{"index":1,"label":"B"}]}"#,   // same number twice
        #"{"title": "T", "question": "Q", "multi": false, "options": [{"index":1,"label":"A"},{"label":"B"}]}"#,    // option without a number
        #"{"title": "T", "question": "Q", "multi": false, "options": [{"index":1,"label":"A","checked":true},{"index":2,"label":"B"}]}"#,   // already ticked
        #"{"title": "T", "question": "Q", "multi": "yes", "options": [{"index":1,"label":"A"},{"index":2,"label":"B"}]}"#,   // wrong type
        #"{"title": "T", "question": "Q", "multi": false, "options": "oops"}"#
    ])
    func anythingShortOfAWholePickerIsNotAnswerable(json: String) {
        #expect(AnswerableQuestion(A.dashboardQuestion(json: json)) == nil)
    }

    @Test func nothingIsNotAnswerable() {
        #expect(AnswerableQuestion(nil) == nil)
    }

    // MARK: - Row classification from a real capture

    @Test func healthyFixtureMarksTheQuestionRowAnswerableAndThePermissionRowReadOnly() throws {
        let snapshot = try StatusFixtures.snapshot("state-healthy")
        let question = try #require(snapshot.agent(labelled: "agent-one"))
        guard case .question(let parsed)? = question.blocker else {
            Issue.record("expected an answerable question, got \(String(describing: question.blocker))")
            return
        }
        #expect(parsed.title == "Storage choice")
        #expect(parsed.options.count == 3)
        #expect(question.sessionId == StatusFixtures.sessionId(1))
        #expect(try #require(snapshot.agent(labelled: "agent-two")).blocker == .permission)
        #expect(try #require(snapshot.agent(labelled: "agent-four")).blocker == nil)   // finished, not blocked
    }

    @Test func aQuestionRowWithoutAParsedPickerIsNotAnswerableYet() throws {
        // The dashboard's ~15s lag: the row exists (from the hook) but carries no `question`.
        let data = StatusFixtures.data("state-healthy") { object in
            var computed = object["computed"] as! [String: Any]
            var rows = computed["needsYou"] as! [[String: Any]]
            rows[0]["question"] = NSNull()
            rows[0]["questionPreview"] = ["title": "Storage choice", "question": "Keep it?", "options": [["index": 1, "label": "Yes"]]]
            computed["needsYou"] = rows
            object["computed"] = computed
        }
        let snapshot = try StatusSnapshotBuilder.snapshot(fromJSON: data, fetchedAt: StatusFixtures.serverNow)
        #expect(try #require(snapshot.agent(labelled: "agent-one")).blocker
            == .questionLoading(QuestionIdentity(title: "Storage choice", question: "Keep it?")))
    }

    @Test func aQuestionRowWithNothingAtAllIsStillJustLoading() throws {
        let data = StatusFixtures.data("state-healthy") { object in
            var computed = object["computed"] as! [String: Any]
            var rows = computed["needsYou"] as! [[String: Any]]
            rows[0]["question"] = NSNull()
            computed["needsYou"] = rows
            object["computed"] = computed
        }
        let snapshot = try StatusSnapshotBuilder.snapshot(fromJSON: data, fetchedAt: StatusFixtures.serverNow)
        #expect(try #require(snapshot.agent(labelled: "agent-one")).blocker == .questionLoading(nil))
    }

    @Test func aMalformedQuestionObjectNeverCrashesAndIsNotAnswerable() throws {
        let data = StatusFixtures.data("state-healthy") { object in
            var computed = object["computed"] as! [String: Any]
            var rows = computed["needsYou"] as! [[String: Any]]
            rows[0]["question"] = ["title": 7, "options": "nope", "multi": ["x"]]
            computed["needsYou"] = rows
            object["computed"] = computed
        }
        let snapshot = try StatusSnapshotBuilder.snapshot(fromJSON: data, fetchedAt: StatusFixtures.serverNow)
        #expect(try #require(snapshot.agent(labelled: "agent-one")).blocker == .questionNotAnswerable)
    }
}
