import Foundation
@testable import AgentBar

/// Hand-built questions and blocked agents for the answer-card tests.
enum AnswerFixtures {
    static func dashboardQuestion(json: String) -> DashboardQuestion {
        try! JSONDecoder().decode(DashboardQuestion.self, from: Data(json.utf8))
    }

    /// A parsed picker as the dashboard sends it: `labels` are numbered from 1,
    /// the last one being the free-text row when `withOther`.
    static func questionJSON(
        title: String = "Fruit",
        question: String = "Which fruit?",
        multi: Bool = false,
        labels: [String] = ["Apple", "Banana"],
        withOther: Bool = true,
        context: String? = "Some prose above the box."
    ) -> String {
        var options = labels.enumerated().map { position, label in
            #"{"index": \#(position + 1), "label": "\#(label)", "desc": "About \#(label)", "checked": false, "other": false}"#
        }
        if withOther {
            options.append(#"{"index": \#(labels.count + 1), "label": "Type something.", "desc": "", "checked": false, "other": true}"#)
        }
        let contextJSON = context.map { #""\#($0)""# } ?? "null"
        return #"{"title": "\#(title)", "question": "\#(question)", "multi": \#(multi), "options": [\#(options.joined(separator: ","))], "cursorIndex": 1, "otherIndex": \#(labels.count + 1), "hasSubmit": \#(multi), "context": \#(contextJSON)}"#
    }

    static func question(
        title: String = "Fruit",
        question: String = "Which fruit?",
        multi: Bool = false,
        labels: [String] = ["Apple", "Banana"],
        withOther: Bool = true,
        context: String? = "Some prose above the box."
    ) -> AnswerableQuestion {
        let json = questionJSON(title: title, question: question, multi: multi, labels: labels, withOther: withOther, context: context)
        return AnswerableQuestion(dashboardQuestion(json: json))!
    }

    /// A Needs-you agent blocked on `blocker`, with a Claude session id.
    static func blockedAgent(
        _ id: String,
        blocker: AgentBlocker?,
        section: AgentSection = .needsYou,
        sessionId: String? = "session-1"
    ) -> AgentSnapshot {
        var agent = AgentListFixtures.agent(id, label: "agent \(id)", project: "proj", section: section)
        agent.blocker = blocker
        agent.sessionId = sessionId
        return agent
    }
}
