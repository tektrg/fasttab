import Foundation

/// The Summary prompt the person can edit. The server owns the fixed rules (the article is
/// untrusted data, output only the summary, language last); this is only the style/structure part.
enum ReaderSummaryPrompt {
    /// Mirrors theindie-api `instruction` limit (JavaScript `.length`, i.e. UTF-16 units).
    static let maxInstructionLength = 2_000
    /// Mirrors theindie-api `SUMMARY_PROMPT_VERSION`. The editor starts from this text; a person who
    /// never edits sends no prompt at all, so the server's newest default always applies to them.
    static let defaultVersion = 1

    /// Mirrors theindie-api `DEFAULT_SUMMARY_INSTRUCTION` (src/ai/reader-prompt.ts), adapted from the
    /// GPTBreeze summary prompt. Keep the two in step when the server default changes (bump the version).
    static let defaultInstruction = """
Summarize the article below for a busy reader. Follow this procedure:
1. Read the whole article and split it into sections by topic.
2. For each section write ONE key takeaway sentence (under 15 words), then 1 to 3 sub-bullets with the specific facts behind it (who, what, how much, when).
3. Make the key names, dates, numbers and direct quotes **bold**.
4. At the very top, add one line starting with "**Gist:**" that states the point of the whole article in a single sentence.

Rules:
- Use simple vocabulary a teenager would understand; explain jargon in a few words.
- Report only what the article says. No interpretation, no inference, no opinion, no advice.
- Keep every takeaway under 15 words and every sub-bullet to one short line.
- Skip ads, navigation text, cookie notices and anything unrelated to the article.

Output format (markdown):
**Gist:** <one sentence>

### <Section topic>
- <Key takeaway>
  - <specific fact with **bold** names, dates, numbers>
  - <specific fact>

Example:
**Gist:** A city banned cars from its centre and air pollution fell fast.

### The ban
- Cars are barred from the centre since **March 2025**.
  - Affects about **40,000** daily trips.
  - Fines start at **€90**.

### The result
- Air quality improved within months.
  - Nitrogen dioxide fell **22%** by **September**.
"""

    /// What to send/store for what was typed: nil = "use the server default" (blank, or the
    /// default text itself); otherwise the trimmed custom text.
    static func normalized(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == defaultInstruction.trimmingCharacters(in: .whitespacesAndNewlines) { return nil }
        return trimmed
    }

    static func length(of text: String) -> Int { text.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count }
}

/// The editor's working copy, kept pure so its rules are unit-tested.
struct ReaderSummaryPromptDraft: Equatable {
    var text: String

    /// `stored` = the saved custom prompt, nil = default.
    init(stored: String?) { text = stored ?? ReaderSummaryPrompt.defaultInstruction }

    var normalized: String? { ReaderSummaryPrompt.normalized(text) }
    var isUsingDefault: Bool { normalized == nil }
    var length: Int { ReaderSummaryPrompt.length(of: text) }
    var isOverLimit: Bool { length > ReaderSummaryPrompt.maxInstructionLength }

    /// Save is offered when it would change what is stored, and the server would accept it.
    func canSave(stored: String?) -> Bool { !isOverLimit && normalized != stored }

    mutating func resetToDefault() { text = ReaderSummaryPrompt.defaultInstruction }
}
