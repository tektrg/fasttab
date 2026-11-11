import SwiftUI

/// Where the builder is hosted.
public enum SavedViewEditorStyle: Sendable {
    case bar
    case sheet
}

/// The saved-view builder's frame, shared by every app: optional sheet title,
/// the scrolling form, a divider and the pinned footer. `.bar` sits inside the
/// fixed-height command bar; `.sheet` in a Settings sheet.
public struct SavedViewEditorShell<Form: View, Footer: View>: View {
    public typealias Style = SavedViewEditorStyle

    let isNew: Bool
    let style: Style
    let form: Form
    let footer: Footer

    public init(isNew: Bool, style: Style, @ViewBuilder form: () -> Form, @ViewBuilder footer: () -> Footer) {
        self.isNew = isNew
        self.style = style
        self.form = form()
        self.footer = footer()
    }

    public var body: some View {
        VStack(spacing: 0) {
            if style == .sheet {
                Text(isNew ? "New View" : "Edit View")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 6)
            }
            ScrollView(.vertical) {
                form
                    .padding(.horizontal, style == .bar ? 14 : 16)
                    .padding(.vertical, 10)
            }
            Divider()
            footer
                .padding(.horizontal, style == .bar ? 14 : 16)
                .padding(.vertical, 8)
        }
        .controlSize(.small)
    }
}

/// The builder's shared fields — Name, Icon, Keywords, AI filter — with the
/// app's criteria rows in three slots: `filters` (after Icon),
/// `afterKeywords` (before the AI filter) and `trailing` (after it).
public struct SavedViewEditorFields<Filters: View, AfterKeywords: View, Trailing: View>: View {
    @Binding var name: String
    @Binding var iconName: String
    @Binding var keywords: String
    @Binding var semanticPrompt: String
    let iconChoices: [String]
    let namePlaceholder: String
    let keywordsPlaceholder: String
    let promptPlaceholder: String
    let isAIAvailable: Bool
    /// Under the AI field: what it does (available) or why it can't be used.
    let aiHint: String
    /// False hides the AI filter row (an app that can't evaluate prompts yet).
    let showsAIFilter: Bool
    let filters: Filters
    let afterKeywords: AfterKeywords
    let trailing: Trailing

    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case name, keywords, prompt
    }

    public init(
        name: Binding<String>,
        iconName: Binding<String>,
        keywords: Binding<String>,
        semanticPrompt: Binding<String>,
        iconChoices: [String],
        namePlaceholder: String,
        keywordsPlaceholder: String,
        promptPlaceholder: String,
        isAIAvailable: Bool,
        aiHint: String,
        showsAIFilter: Bool = true,
        @ViewBuilder filters: () -> Filters,
        @ViewBuilder afterKeywords: () -> AfterKeywords,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self._name = name
        self._iconName = iconName
        self._keywords = keywords
        self._semanticPrompt = semanticPrompt
        self.iconChoices = iconChoices
        self.namePlaceholder = namePlaceholder
        self.keywordsPlaceholder = keywordsPlaceholder
        self.promptPlaceholder = promptPlaceholder
        self.isAIAvailable = isAIAvailable
        self.aiHint = aiHint
        self.showsAIFilter = showsAIFilter
        self.filters = filters()
        self.afterKeywords = afterKeywords()
        self.trailing = trailing()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SavedViewFormRow("Name") {
                TextField(namePlaceholder, text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .name)
            }
            SavedViewFormRow("Icon") { iconGrid }
            filters
            SavedViewFormRow("Keywords") {
                TextField(keywordsPlaceholder, text: $keywords)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .keywords)
            }
            afterKeywords
            if showsAIFilter {
                SavedViewFormRow("AI filter") { aiField }
            }
            trailing
        }
        .onAppear {
            // After the page's slide-in, or the field isn't in the window yet.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                focusedField = .name
            }
        }
    }

    private var iconGrid: some View {
        SavedViewFlowLayout(spacing: 4) {
            ForEach(iconChoices, id: \.self) { icon in
                let isSelected = iconName == icon
                Button {
                    iconName = icon
                } label: {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 24, height: 22)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.primary.opacity(0.75))
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(icon)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }

    private var aiField: some View {
        VStack(alignment: .leading, spacing: 3) {
            TextField(promptPlaceholder, text: $semanticPrompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
                .focused($focusedField, equals: .prompt)
                .disabled(!isAIAvailable)
            Text(aiHint)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            // The field is disabled without the on-device model; a prompt
            // saved earlier (or synced) must still be removable.
            if Self.canRemoveAIFilter(prompt: semanticPrompt, isAIAvailable: isAIAvailable) {
                Button("Remove AI filter") {
                    semanticPrompt = ""
                }
                .controlSize(.small)
            }
        }
    }

    /// "Remove AI filter" shows when the prompt field can't be edited (no
    /// on-device model) but holds a prompt.
    public static func canRemoveAIFilter(prompt: String, isAIAvailable: Bool) -> Bool {
        !isAIAvailable && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Cancel / Save, the live match count, and "Delete View…" with its inline
/// confirmation. Fits any bar width: one row when there's room, otherwise
/// the text moves to its own line above the buttons.
public struct SavedViewEditorFooter: View {
    let viewName: String
    let isNew: Bool
    let isValid: Bool
    /// Save's tooltip when invalid (the first problem).
    let firstIssue: String?
    let matchCountText: String
    /// After "Delete “name”?" — what deleting leaves alone.
    let deleteReassurance: String
    @Binding var isConfirmingDelete: Bool
    let onCancel: () -> Void
    let onSave: () -> Void
    let onDelete: (() -> Void)?

    public init(
        viewName: String,
        isNew: Bool,
        isValid: Bool,
        firstIssue: String?,
        matchCountText: String,
        deleteReassurance: String,
        isConfirmingDelete: Binding<Bool>,
        onCancel: @escaping () -> Void,
        onSave: @escaping () -> Void,
        onDelete: (() -> Void)?
    ) {
        self.viewName = viewName
        self.isNew = isNew
        self.isValid = isValid
        self.firstIssue = firstIssue
        self.matchCountText = matchCountText
        self.deleteReassurance = deleteReassurance
        self._isConfirmingDelete = isConfirmingDelete
        self.onCancel = onCancel
        self.onSave = onSave
        self.onDelete = onDelete
    }

    public var body: some View {
        if isConfirmingDelete, let onDelete {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    deletePrompt.lineLimit(2)
                    Spacer(minLength: 8)
                    deleteButtons(onDelete)
                }
                VStack(alignment: .leading, spacing: 6) {
                    deletePrompt
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        deleteButtons(onDelete)
                    }
                }
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    deleteButton
                    countText
                    Spacer(minLength: 8)
                    actionButtons
                }
                VStack(alignment: .leading, spacing: 6) {
                    countText
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        deleteButton
                        Spacer(minLength: 8)
                        actionButtons
                    }
                }
            }
        }
    }

    private var deletePrompt: some View {
        Text("Delete “\(viewName.isEmpty ? "this view" : viewName)”? \(deleteReassurance)")
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func deleteButtons(_ onDelete: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Button("Cancel") { isConfirmingDelete = false }
                .keyboardShortcut(.cancelAction)
            Button("Delete View", role: .destructive, action: onDelete)
        }
        .fixedSize()
    }

    @ViewBuilder
    private var deleteButton: some View {
        if onDelete != nil {
            Button("Delete View…") { isConfirmingDelete = true }
                .fixedSize()
        }
    }

    private var countText: some View {
        Text(matchCountText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button(isNew ? "Create View" : "Save", action: onSave)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!isValid)
                .help(firstIssue ?? "Save (⌘Return)")
        }
        .fixedSize()
    }

    /// "12 items match" / "1 item matches" / "Counting…", noting when an AI
    /// filter will narrow it further.
    public static func matchCountText(count: Int?, hasSemanticFilter: Bool) -> String {
        guard let count else { return "Counting…" }
        let base = count == 1 ? "1 item matches" : "\(count) items match"
        return hasSemanticFilter ? base + " before the AI filter" : base
    }
}
