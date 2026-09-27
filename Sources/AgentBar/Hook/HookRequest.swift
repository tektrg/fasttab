import Foundation

/// A prompt a status-only Claude session (Claude Desktop, or the CLI outside herdr) is waiting on,
/// as the dashboard's hook bridge holds it: Claude's `PermissionRequest` hook sent it there and waits
/// for AgentBar's answer (`POST /api/hook/permission/<requestId>/answer`). There is no pane behind it,
/// so nothing is read off a screen: the request itself is the whole prompt, and the answer goes by id.
struct HookRequest: Equatable, Sendable {
    enum Content: Equatable, Sendable {
        /// AskUserQuestion: every question of the call (one or more), in order.
        case questions([FormQuestion])
        /// Any other tool asking to run.
        case permission(HookPermission)
    }

    let requestId: String
    let toolName: String
    let content: Content

    /// The free-text row AgentBar adds to every hook question (Claude's own picker has one too).
    static let otherOptionLabel = "Other"

    /// Nil unless the wire entry is whole enough to answer: a path-safe id, a known kind, and
    /// questions with distinct texts (answers are keyed by question text) and at least one option each.
    init?(_ wire: DashboardHookRequest?) {
        guard let wire, let requestId = wire.requestId, Self.isPathSafe(requestId) else { return nil }
        let toolName = wire.toolName ?? ""
        switch wire.kind {
        case "question":
            let questions = wire.questions.compactMap(Self.formQuestion)
            guard !questions.isEmpty, questions.count == wire.questions.count,
                  Set(questions.map(\.question)).count == questions.count else { return nil }
            content = .questions(questions)
        case "permission":
            guard !toolName.isEmpty, let permission = wire.permission else { return nil }
            let suggestions = permission.suggestions.compactMap { suggestion -> HookPermissionSuggestion? in
                guard let index = suggestion.index, let label = suggestion.label, !label.isEmpty else { return nil }
                return HookPermissionSuggestion(index: index, label: label)
            }
            content = .permission(HookPermission(
                title: nonEmpty(permission.title) ?? "Allow \(toolName)?",
                detail: permission.detail ?? "",
                suggestions: Set(suggestions.map(\.index)).count == suggestions.count ? suggestions : []
            ))
        default:
            return nil
        }
        self.requestId = requestId
        self.toolName = toolName
    }

    /// The id goes into a URL path: only letters, digits, `-` and `_` (anything else is not answered).
    static func isPathSafe(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "_"
        }
    }

    private static func formQuestion(_ wire: DashboardHookQuestion) -> FormQuestion? {
        guard let question = nonEmpty(wire.question) else { return nil }
        let options = wire.options.compactMap { option -> FormQuestion.Option? in
            guard let label = nonEmpty(option.label) else { return nil }
            return FormQuestion.Option(label: label, description: option.description ?? "")
        }
        guard !options.isEmpty, options.count == wire.options.count else { return nil }
        return FormQuestion(header: wire.header ?? "", question: question, isMultiSelect: wire.multiSelect ?? false, options: options)
    }

    // MARK: - As the row and cards see it

    /// The blocker the row shows: Answer on a question (the first one; a form card shows them all),
    /// Review on a permission. Built only from this request, never from a screen.
    var blocker: AgentBlocker {
        switch content {
        case .questions(let questions): .question(Self.answerableQuestion(questions[0]))
        case .permission(let permission): .permissionReview(permissionPrompt(permission))
        }
    }

    /// The questions of an AskUserQuestion request; empty for a permission.
    var questions: [FormQuestion] {
        if case .questions(let questions) = content { return questions }
        return []
    }

    /// A hook question as the single answer card shows it: options numbered 1...n, then the free-text row.
    static func answerableQuestion(_ question: FormQuestion) -> AnswerableQuestion {
        var options = question.options.enumerated().map { position, option in
            AnswerableQuestion.Option(index: position + 1, label: option.label, description: option.description, isOther: false)
        }
        options.append(AnswerableQuestion.Option(index: options.count + 1, label: otherOptionLabel, description: "", isOther: true))
        return AnswerableQuestion(
            title: question.header.isEmpty ? "Question" : question.header,
            question: question.question, isMultiSelect: question.isMultiSelect, options: options, context: nil
        )
    }

    /// A hook permission as the permission card shows it: "Yes" first (allow once), one row per
    /// "always allow" suggestion (exact rule in its label), "No" last. The rows exist only on the card.
    private func permissionPrompt(_ permission: HookPermission) -> PermissionPrompt {
        let rows = [Self.allowOnceLabel] + permission.suggestions.map(\.label) + [Self.denyLabel]
        return PermissionPrompt(
            tool: toolName, detail: permission.detail, title: permission.title,
            options: rows.enumerated().map { PermissionPrompt.Option(index: $0.offset + 1, label: $0.element) },
            cursorIndex: nil, hookSuggestions: permission.suggestions
        )
    }

    static let allowOnceLabel = "Yes, this time only"
    static let denyLabel = "No"
}

struct HookPermission: Equatable, Sendable {
    let title: String
    /// The Bash command, file path or plan text, as the dashboard summarised it.
    let detail: String
    let suggestions: [HookPermissionSuggestion]
}

/// One of Claude's "always allow" offers: `index` is what the answer sends back (`suggestionIndex`),
/// `label` the plain-English rule (e.g. "Always allow `python3 -c ...` in this project").
struct HookPermissionSuggestion: Equatable, Hashable, Sendable {
    let index: Int
    let label: String
}

private func nonEmpty(_ text: String?) -> String? {
    guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return text
}

// MARK: - Wire

/// `needsYou[].hookRequest` (and the agent row's): every field optional, one odd value costs only itself.
struct DashboardHookRequest: Decodable {
    let requestId: String?
    /// "question" | "permission"
    let kind: String?
    let toolName: String?
    let questions: [DashboardHookQuestion]
    let permission: DashboardHookPermission?

    private enum CodingKeys: String, CodingKey { case requestId, kind, toolName, questions, permission }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestId = container.lenient(.requestId)
        kind = container.lenient(.kind)
        toolName = container.lenient(.toolName)
        questions = (container.lenient(.questions) as LenientArray<DashboardHookQuestion>?)?.elements ?? []
        permission = container.lenient(.permission)
    }
}

struct DashboardHookQuestion: Decodable {
    let question: String?
    let header: String?
    let multiSelect: Bool?
    let options: [Option]

    struct Option: Decodable {
        let label: String?
        let description: String?

        private enum CodingKeys: String, CodingKey { case label, description }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            label = container.lenient(.label)
            description = container.lenient(.description)
        }
    }

    private enum CodingKeys: String, CodingKey { case question, header, multiSelect, options }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        question = container.lenient(.question)
        header = container.lenient(.header)
        multiSelect = container.lenient(.multiSelect)
        options = (container.lenient(.options) as LenientArray<Option>?)?.elements ?? []
    }
}

struct DashboardHookPermission: Decodable {
    let title: String?
    let detail: String?
    let suggestions: [Suggestion]

    struct Suggestion: Decodable {
        let index: Int?
        let label: String?

        private enum CodingKeys: String, CodingKey { case index, label }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            index = container.lenient(.index)
            label = container.lenient(.label)
        }
    }

    private enum CodingKeys: String, CodingKey { case title, detail, suggestions }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = container.lenient(.title)
        detail = container.lenient(.detail)
        suggestions = (container.lenient(.suggestions) as LenientArray<Suggestion>?)?.elements ?? []
    }
}
