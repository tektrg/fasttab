import Foundation

/// Claude Desktop's end-of-turn question: the turn ended with its `wrap_up` tool carrying an `ask`, and nothing
/// was said since. The dashboard reads it from the session transcript (`dashboard/server/lib/transcript_wrap_up.py`,
/// which already drops app actions like "commit" and fills a missing `message` with the label) and sends it on an
/// idle status-only row and its needsYou entry. The turn is over, so the answer is a plain message through the
/// session inbox — the message card shows the ask with one button per action (`MessageCardModel.pressWrapUpAction`).
struct WrapUpQuestion: Equatable, Sendable {
    struct Action: Equatable, Sendable {
        let label: String
        /// What the button sends.
        let message: String
    }

    let ask: String
    let recap: String
    let actions: [Action]

    /// Nil when the payload has no ask or no usable action: nothing to show buttons for.
    init?(_ payload: DashboardWrapUpQuestion?) {
        guard let payload, let ask = Self.trimmed(payload.ask) else { return nil }
        let actions = (payload.actions ?? []).compactMap { raw -> Action? in
            guard let label = Self.trimmed(raw.label) else { return nil }
            return Action(label: label, message: Self.trimmed(raw.message) ?? label)
        }
        guard !actions.isEmpty else { return nil }
        self.ask = ask
        self.recap = Self.trimmed(payload.recap) ?? ""
        self.actions = actions
    }

    private static func trimmed(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

/// `wrapUpQuestion` as the dashboard sends it: `{ask, recap, actions: [{label, message}]}`.
struct DashboardWrapUpQuestion: Decodable {
    struct Action: Decodable {
        let label: String?
        let message: String?

        private enum CodingKeys: String, CodingKey { case label, message }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            label = container.lenient(.label)
            message = container.lenient(.message)
        }
    }

    let ask: String?
    let recap: String?
    let actions: [Action]?

    private enum CodingKeys: String, CodingKey { case ask, recap, actions }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ask = container.lenient(.ask)
        recap = container.lenient(.recap)
        actions = container.lenient(.actions)
    }
}
