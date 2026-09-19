import Testing
@testable import AgentBar

struct QuestionMatchingTests {
    private let clean = QuestionIdentity(title: "Persist", question: "Should it persist, and also reset each time?")
    private let cutByTheFeed = QuestionIdentity(title: "Persist", question: "Should it persist, and a lso reset each time?")

    @Test func wrappingAndBorderDifferencesStillMeanTheSameQuestion() {
        #expect(clean.isSameQuestion(as: cutByTheFeed))
        let bordered = QuestionIdentity(title: "Persist", question: "│ Should it persist, and also │ reset each time?")
        #expect(clean.isSameQuestion(as: bordered))
    }

    @Test func aDifferentTitleOrQuestionIsADifferentQuestion() {
        #expect(!clean.isSameQuestion(as: QuestionIdentity(title: "Other", question: clean.question)))
        #expect(!clean.isSameQuestion(as: QuestionIdentity(title: "Persist", question: "Something else entirely?")))
        #expect(!clean.isSameQuestion(as: QuestionIdentity(title: "", question: clean.question)))
    }

    @Test func aPreviewCarryingOnlyTheStartOfTheQuestionMatches() {
        #expect(clean.isSameQuestion(as: QuestionIdentity(title: "Persist", question: "Should it persist")))
    }

    @Test func theSentIdentityIsThePanesOwnReadingOnlyForTheSameQuestion() {
        #expect(cutByTheFeed.resolved(against: clean) == clean)
        let different = QuestionIdentity(title: "Persist", question: "A brand new question?")
        #expect(cutByTheFeed.resolved(against: different) == cutByTheFeed)   // still refused by the dashboard, never mis-answered
        #expect(cutByTheFeed.resolved(against: nil) == cutByTheFeed)
    }
}
