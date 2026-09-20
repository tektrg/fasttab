import Foundation

/// Keeps a blocked agent's answerable question (or reviewable permission box) steady
/// while the dashboard's view of it flaps. One pane's row can be reported three ways within seconds:
/// the parsed picker (answerable), the hook's early preview with no options yet,
/// and a plain "blocked" row while its screen sweep has not confirmed the picker.
/// Read as-is, the Answer button would come and go. Once a question has been
/// seen answerable it stays that until the agent stops being blocked, or shows
/// a different question; the dashboard still re-checks the pane before typing.
/// A permission box flaps the same way (parsed, then a plain "blocked" row while its
/// screen read has not confirmed it), and is held the same way.
struct BlockerMemory {
    /// How long a "blocked, screen unconfirmed" report may stand in for a question just seen.
    static let unconfirmedGraceSeconds: TimeInterval = 45

    private struct Sighting {
        /// Only ever `.question` or `.permissionReview`.
        let blocker: AgentBlocker
        let at: Date
        /// Read from the pane by AgentBar itself (see `BlockerProbe`) rather than reported by
        /// the dashboard: the dashboard's own row may not show it yet, even as a plain
        /// "blocked" one, so it also stands in for a row with no blocker at all.
        var readFromPane = false

        var question: AnswerableQuestion? {
            if case .question(let question) = blocker { return question }
            return nil
        }
    }

    private var sightings: [String: Sighting] = [:]

    /// A question or permission box AgentBar read from the pane before the dashboard reported it.
    mutating func learn(_ blocker: AgentBlocker, for agentID: String, now: Date) {
        switch blocker {
        case .question, .permissionReview: sightings[agentID] = Sighting(blocker: blocker, at: now, readFromPane: true)
        case .questionLoading, .questionNotAnswerable, .permission: break
        }
    }

    /// `agents` with each blocked agent's blocker steadied. Forgets agents no longer blocked.
    mutating func steadied(_ agents: [AgentSnapshot], now: Date) -> [AgentSnapshot] {
        var remembered: [String: Sighting] = [:]
        let result = agents.map { agent -> AgentSnapshot in
            guard let blocker = agent.blocker else {
                guard agent.section == .needsYou, let seen = sightings[agent.id], seen.readFromPane,
                      now.timeIntervalSince(seen.at) <= Self.unconfirmedGraceSeconds else { return agent }
                remembered[agent.id] = seen
                return agent.withBlocker(seen.blocker)
            }
            switch blocker {
            case .question(let question):
                remembered[agent.id] = Sighting(blocker: blocker, at: now)
            case .permissionReview:
                remembered[agent.id] = Sighting(blocker: blocker, at: now)
            case .questionLoading(let previewed):
                guard let seen = sightings[agent.id], let question = seen.question,
                      previewed.map(question.identity.isSameQuestion) ?? true else { break }
                remembered[agent.id] = seen
                return agent.withBlocker(seen.blocker)
            case .permission:
                guard let seen = sightings[agent.id], now.timeIntervalSince(seen.at) <= Self.unconfirmedGraceSeconds else { break }
                remembered[agent.id] = seen
                return agent.withBlocker(seen.blocker)
            case .questionNotAnswerable:
                break
            }
            return agent
        }
        sightings = remembered
        return result
    }

    mutating func reset() {
        sightings = [:]
    }
}

extension AgentSnapshot {
    func withBlocker(_ blocker: AgentBlocker?) -> AgentSnapshot {
        var copy = self
        copy.blocker = blocker
        return copy
    }
}
