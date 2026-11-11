import Foundation
import IndieSearch

/// The saved-view editor's working copy: plain fields the form binds to, turned into an
/// `AgentSavedView` on save. Pure.
struct AgentViewDraft: Equatable {
    var id: UUID
    var name: String
    var iconName: String
    var keywords: String
    var groupBy: AgentViewGroupBy
    /// Name-or-folder entries, one per line or comma-separated (`TextPattern` forms).
    var namesText: String
    var projects: Set<String>
    var sections: Set<AgentSection>
    var activeWithinMinutes: Int?

    static let iconChoices = [
        "square.stack.3d.up", "star", "flag", "bolt", "hammer", "briefcase", "folder",
        "person.2", "bubble.left", "clock", "bell", "leaf", "flame", "cpu", "terminal", "sparkles"
    ]

    /// Active-within choices (minutes; nil = any time), with labels.
    static let activeWithinChoices: [(minutes: Int?, title: String)] = [
        (nil, "Any time"), (15, "15 min"), (60, "1 hour"), (24 * 60, "24 hours"), (7 * 24 * 60, "7 days")
    ]

    init(_ view: AgentSavedView) {
        id = view.id
        name = view.name
        iconName = view.iconName
        keywords = view.keywords
        groupBy = view.groupBy
        namesText = view.criteria.names.joined(separator: ", ")
        projects = Set(view.criteria.projects)
        sections = view.criteria.sections
        activeWithinMinutes = view.criteria.activeWithinMinutes
    }

    static func new() -> AgentViewDraft {
        AgentViewDraft(AgentSavedView(name: ""))
    }

    /// Raw entries as typed, split on commas and new lines.
    var nameEntries: [String] {
        namesText.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    enum Issue: Equatable {
        case noName
        case brokenPattern(String)

        var message: String {
            switch self {
            case .noName: "Give the view a name."
            case .brokenPattern(let entry): "“\(entry)” is not a valid pattern."
            }
        }
    }

    var issues: [Issue] {
        var found: [Issue] = []
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { found.append(.noName) }
        if let broken = nameEntries.first(where: { TextPattern.isRegex($0) && TextPattern.normalize($0) == nil }) {
            found.append(.brokenPattern(broken))
        }
        return found
    }

    var isValid: Bool { issues.isEmpty }

    var view: AgentSavedView {
        AgentSavedView(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            iconName: iconName,
            keywords: keywords.trimmingCharacters(in: .whitespacesAndNewlines),
            groupBy: groupBy,
            criteria: AgentViewCriteria(
                names: TextPattern.clean(nameEntries),
                projects: projects.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending },
                sections: sections,
                activeWithinMinutes: activeWithinMinutes
            )
        )
    }
}
