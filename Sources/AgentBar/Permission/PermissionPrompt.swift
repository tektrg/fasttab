import Foundation

/// A permission box an agent is waiting on ("Do you want to proceed?"), as the
/// dashboard reads it from the pane: which tool wants to do what, and the choices
/// the box offers. Every string is kept exactly as read: the dashboard refuses a
/// decision unless the box in the pane still matches this letter for letter.
struct PermissionPrompt: Equatable, Hashable, Sendable {
    struct Option: Equatable, Hashable, Sendable {
        /// The number the box shows; the key that selects it.
        let index: Int
        let label: String
    }

    /// What the box asks: a tool call to allow or deny, or Claude's plan mode asking to proceed.
    enum Kind: String, Equatable, Hashable, Sendable {
        case tool
        case plan
    }

    /// "Bash", "Write", "Edit"... ("ExitPlanMode" for a plan box).
    let tool: String
    /// The command, file or arguments, in full (the text inside `Tool(...)`). Empty for a plan box.
    let detail: String
    let title: String
    let options: [Option]
    /// The option the pane's cursor is on.
    let cursorIndex: Int?
    let kind: Kind
    /// A plan box: the plan file named in its footer, exactly as drawn (`~` not expanded); nil when the footer is absent.
    let planPath: String?

    init(
        tool: String, detail: String, title: String, options: [Option], cursorIndex: Int?,
        kind: Kind = .tool, planPath: String? = nil
    ) {
        self.tool = tool
        self.detail = detail
        self.title = title
        self.options = options
        self.cursorIndex = cursorIndex
        self.kind = kind
        self.planPath = planPath
    }

    /// The choices this box offers, in the order the card shows them. The rules are the
    /// dashboard's own (it presses nothing its own reading of the box does not corroborate):
    /// allow is the first "Yes" row, deny the last "No" row, allow-always the row that says
    /// "don't ask again" or "for this session". A plan box has no such rows (see `PermissionPrompt+Plan`).
    func option(for choice: PermissionChoice) -> Option? {
        // A plan box's rows ("Yes, and use auto mode") only look like allow rows: it is never allowed or denied
        // by wording, only by picking a row on the plan card.
        guard !isPlan else { return nil }
        switch choice {
        case .allow:
            guard let first = options.first, first.label.hasPrefix("Yes"), !Self.isAlways(first.label) else { return nil }
            return first
        case .deny:
            guard let last = options.last, last.label.hasPrefix("No") else { return nil }
            return last
        case .allowAlways:
            return options.first { $0.label.hasPrefix("Yes") && Self.isAlways($0.label) }
        }
    }

    var choices: [PermissionChoice] {
        PermissionChoice.allCases.filter { option(for: $0) != nil }
    }

    /// Who this prompt is, for telling "the same box" from "another one".
    var identity: PermissionIdentity { PermissionIdentity(self) }

    /// A "Yes" row that grants more than this one call (the dashboard's own two phrasings).
    private static func isAlways(_ label: String) -> Bool {
        label.contains("don't ask again") || label.contains("for this session")
    }

    /// The first line of the detail (the command, or an edited file's path) and, for an edit box,
    /// the diff excerpt that follows it.
    var detailParts: (headline: String, body: String?) {
        guard let newline = detail.firstIndex(of: "\n") else { return (detail, nil) }
        return (String(detail[..<newline]), String(detail[detail.index(after: newline)...]))
    }

    /// True for the file-edit box ("Do you want to make this edit to <file>?").
    var isFileEdit: Bool { title.hasPrefix("Do you want to make this edit to") }
}

/// What makes one permission box the same box as another: tool, detail and title, with
/// whitespace runs collapsed (the status feed and a fresh pane read can wrap the same
/// text differently).
struct PermissionIdentity: Hashable, Sendable {
    let tool: String
    let detail: String
    let title: String
    /// A plan box's title and options are one fixed sentence for every plan: the file is what tells two apart.
    let planPath: String?

    init(_ prompt: PermissionPrompt) {
        tool = prompt.tool
        detail = Self.collapsed(prompt.detail)
        title = Self.collapsed(prompt.title)
        planPath = prompt.planPath
    }

    private static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// What the user can decide on a permission box.
enum PermissionChoice: CaseIterable, Equatable, Sendable {
    case allow
    case allowAlways
    case deny

    /// The word the dashboard's request uses.
    var wireName: String {
        switch self {
        case .allow: "allow"
        case .allowAlways: "allow-always"
        case .deny: "deny"
        }
    }

    var title: String {
        switch self {
        case .allow: "Allow"
        case .allowAlways: "Allow always"
        case .deny: "Deny"
        }
    }

    /// What the row says while this decision is on its way.
    var sendingLabel: String {
        switch self {
        case .allow, .allowAlways: "Sending approval…"
        case .deny: "Sending denial…"
        }
    }

    /// Say-so on the row's spinner tag (see `SendTracker.Flight.tag`).
    var flightTag: String { self == .deny ? "denial" : "approval" }
}

/// What was decided on a permission card when it was sent (nothing is kept for a retry).
struct PermissionDecision: SendDraft {
    let identity: PermissionIdentity
    /// Nil for a row picked on a plan card (`planRowIndex`).
    let choice: PermissionChoice?
    let planRowIndex: Int?

    init(identity: PermissionIdentity, choice: PermissionChoice) {
        self.identity = identity
        self.choice = choice
        self.planRowIndex = nil
    }

    init(identity: PermissionIdentity, planRowIndex: Int) {
        self.identity = identity
        self.choice = nil
        self.planRowIndex = planRowIndex
    }
}

/// The permission box as it stood on the row, for `PermissionCard` and the row's own buttons.
extension AgentBlocker {
    var permissionPrompt: PermissionPrompt? {
        if case .permissionReview(let prompt) = self { return prompt }
        return nil
    }
}
