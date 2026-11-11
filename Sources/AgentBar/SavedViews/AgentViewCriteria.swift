import Foundation
import IndieSavedViews
import IndieSearch

/// One saved Agent Bar view ("page" above the agent list): name, icon, keywords plus
/// `AgentViewCriteria`. Stored flat in `AgentSavedViewStore`.
typealias AgentSavedView = SavedView<AgentViewCriteria>

/// How a saved view's agents are grouped under headers.
enum AgentViewGroupBy: String, SavedViewGroupBy, CaseIterable {
    /// Same layout as the All page (status sections, nested under chiefs).
    case none
    /// Flat status sections (Needs you / Working / …), no chief nesting.
    case status
    /// One header per project.
    case project
    /// Day buckets of last activity (Today / Yesterday / …).
    case lastActive

    static var defaultValue: Self { .none }

    init(from decoder: Decoder) throws {
        let raw = try? decoder.singleValueContainer().decode(String.self)
        self = raw.flatMap(Self.init(rawValue:)) ?? .defaultValue
    }

    var title: String {
        switch self {
        case .none: "None"
        case .status: "Status"
        case .project: "Project"
        case .lastActive: "Last active"
        }
    }
}

/// What a saved Agent Bar view keeps. Every non-empty rule must hold (AND); inside one rule any
/// entry may match (OR). Empty criteria = every agent the All page shows.
struct AgentViewCriteria: SavedViewCriteria {
    typealias GroupBy = AgentViewGroupBy

    /// `TextPattern` entries (plain text, `*wildcard*`, `/regex/`) matched against the session
    /// label OR its working folder.
    var names: [String] = []
    /// Exact project names, any case.
    var projects: [String] = []
    /// Statuses to keep; empty = all.
    var sections: Set<AgentSection> = []
    /// Keep agents whose last activity is at most this many minutes ago; nil = any time.
    var activeWithinMinutes: Int?

    static var defaultIconName: String { "square.stack.3d.up" }

    init() {}

    init(names: [String] = [], projects: [String] = [], sections: Set<AgentSection> = [], activeWithinMinutes: Int? = nil) {
        self.names = names
        self.projects = projects
        self.sections = sections
        self.activeWithinMinutes = activeWithinMinutes
    }

    var isEmpty: Bool { self == Self() }

    func matches(_ agent: AgentSnapshot) -> Bool {
        if !names.isEmpty, !TextPattern.matches(anyOf: [agent.label, agent.cwd], entries: names) { return false }
        if !projects.isEmpty {
            guard let project = agent.projectName,
                  projects.contains(where: { $0.caseInsensitiveCompare(project) == .orderedSame })
            else { return false }
        }
        if !sections.isEmpty, !sections.contains(agent.section) { return false }
        if let minutes = activeWithinMinutes {
            guard let seconds = agent.activitySeconds, seconds <= TimeInterval(minutes) * 60 else { return false }
        }
        return true
    }

    // MARK: Codable (flat, lenient — keys must not clash with SavedView's common keys)

    private enum CodingKeys: String, CodingKey {
        case names, projects, sections, activeWithinMinutes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        names = TextPattern.clean((try? c.decodeIfPresent([String].self, forKey: .names)) ?? [])
        projects = ((try? c.decodeIfPresent([String].self, forKey: .projects)) ?? []).filter { !$0.isEmpty }
        let rawSections = (try? c.decodeIfPresent([String].self, forKey: .sections)) ?? []
        sections = Set(rawSections.compactMap(AgentSection.init(storageKey:)))
        activeWithinMinutes = (try? c.decodeIfPresent(Int.self, forKey: .activeWithinMinutes)).flatMap { $0 > 0 ? $0 : nil }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(names, forKey: .names)
        try c.encode(projects, forKey: .projects)
        try c.encode(AgentSection.allCases.filter(sections.contains).map(\.storageKey), forKey: .sections)
        try c.encodeIfPresent(activeWithinMinutes, forKey: .activeWithinMinutes)
    }
}

extension AgentSection {
    /// Stable name for saved views (the Int raw value is display order, free to change).
    var storageKey: String {
        switch self {
        case .needsYou: "needsYou"
        case .working: "working"
        case .parked: "parked"
        case .ended: "ended"
        case .sleeping: "sleeping"
        }
    }

    init?(storageKey: String) {
        guard let match = Self.allCases.first(where: { $0.storageKey == storageKey }) else { return nil }
        self = match
    }
}

extension AgentSavedView {
    /// The agents this view keeps: criteria and keywords. Keywords also see the folder, so
    /// `*/aptusfit*` works there.
    func filter(_ agents: [AgentSnapshot]) -> [AgentSnapshot] {
        let words = SavedViewKeywords(keywords)
        return agents.filter { agent in
            criteria.matches(agent)
                && words.matches(texts: [agent.label, agent.projectName, agent.cwd, agent.promptExcerpt])
        }
    }
}
