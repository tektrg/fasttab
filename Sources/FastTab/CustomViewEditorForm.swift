import SwiftUI
import AppKit
import Combine

/// The view builder: the filter form, a live match count, and Cancel / Save
/// (+ "Delete View…" with an inline confirmation when editing). One component
/// for both hosts — the command bar's tall page (`style: .bar`, inside the
/// fixed-height panel, so the form scrolls and the footer stays pinned) and
/// the Settings › Views sheet (`style: .sheet`).
struct CustomViewEditor: View {
    enum Style {
        case bar
        case sheet
    }

    @Binding var draft: CustomViewDraft
    let isNew: Bool
    let style: Style
    /// The footer's inline "Delete …?" row.
    @Binding var isConfirmingDelete: Bool
    let onCancel: () -> Void
    let onSave: () -> Void
    /// Nil for a new view (nothing to delete).
    let onDelete: (() -> Void)?

    @StateObject private var preview = CustomViewEditorPreview.live()

    var body: some View {
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
                CustomViewEditorForm(
                    draft: $draft,
                    profileOptions: preview.profileOptions,
                    historyReachDays: preview.historyReachDays
                )
                    .padding(.horizontal, style == .bar ? 14 : 16)
                    .padding(.vertical, 10)
            }
            Divider()
            footer
                .padding(.horizontal, style == .bar ? 14 : 16)
                .padding(.vertical, 8)
        }
        .controlSize(.small)
        .onAppear {
            preview.start()
            preview.update(draft: draft)
        }
        .onChange(of: draft) { _, newDraft in
            preview.update(draft: newDraft)
        }
    }

    private var footer: some View {
        CustomViewEditorFooter(
            draft: draft,
            isNew: isNew,
            matchCountText: CustomViewEditorFooter.matchCountText(
                count: preview.matchCount,
                hasSemanticFilter: draft.previewView.hasSemanticFilter
            ),
            isConfirmingDelete: $isConfirmingDelete,
            onCancel: onCancel,
            onSave: onSave,
            onDelete: onDelete
        )
    }
}

/// Cancel / Save, the live match count, and "Delete View…" with its inline
/// confirmation. Fits any bar width: one row when there's room, otherwise
/// the text moves to its own line above the buttons.
struct CustomViewEditorFooter: View {
    let draft: CustomViewDraft
    let isNew: Bool
    let matchCountText: String
    @Binding var isConfirmingDelete: Bool
    let onCancel: () -> Void
    let onSave: () -> Void
    let onDelete: (() -> Void)?

    var body: some View {
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
        Text("Delete “\(draft.previewView.name.isEmpty ? "this view" : draft.previewView.name)”? Your tabs, bookmarks and history stay as they are.")
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
                .disabled(!draft.isValid)
                .help(draft.issues.first?.message ?? "Save (⌘Return)")
        }
        .fixedSize()
    }

    static func matchCountText(count: Int?, hasSemanticFilter: Bool) -> String {
        guard let count else { return "Counting…" }
        let base = count == 1 ? "1 item matches" : "\(count) items match"
        return hasSemanticFilter ? base + " before the AI filter" : base
    }
}

/// The builder's fields. Reusable on its own; takes the draft, the
/// profile names to offer, and how far back cached history reaches.
struct CustomViewEditorForm: View {
    @Binding var draft: CustomViewDraft
    let profileOptions: [CustomViewProfileOption]
    /// See `CustomViewDraft.historyReachDays`; nil = no history cached.
    var historyReachDays: Int? = nil

    @FocusState private var focusedField: Field?
    @State private var isAIAvailable = CustomViewAI.isAvailable

    private enum Field: Hashable {
        case name, domains, keywords, prompt
    }

    private static let labelWidth: CGFloat = 86
    /// Narrower than this (the edge-anchored bar), labels go above their
    /// fields so every field gets the full width.
    static let stackedLabelsBelowWidth: CGFloat = 360
    private static let defaultWithin: TimeInterval = 7 * 86_400
    private static let defaultOlderThan: TimeInterval = 30 * 86_400

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("Name") {
                TextField("Reading list", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .name)
            }
            row("Icon") { iconGrid }
            row("Show") { typeChips }
            row("Pinned") { pinnedControl }
            row("Profiles") { profileMenu }
            row("Domains") { domainsField }
            row("Keywords") {
                TextField("Words, *wild*card or /regex/ in title or URL", text: $draft.keywords)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .keywords)
            }
            row("Last visited") { lastVisitedControls }
            row("AI filter") { aiField }
            row("Group by") {
                // Segmented when it fits, a menu otherwise.
                ViewThatFits(in: .horizontal) {
                    groupByPicker.pickerStyle(.segmented).fixedSize()
                    groupByPicker.pickerStyle(.menu).fixedSize()
                }
            }
        }
        .onAppear {
            isAIAvailable = CustomViewAI.isAvailable
            // After the page's slide-in, or the field isn't in the window yet.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                focusedField = .name
            }
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        CustomViewFormRowLayout(labelWidth: Self.labelWidth, stackBelowWidth: Self.stackedLabelsBelowWidth) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            VStack(alignment: .leading, spacing: 4) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var groupByPicker: some View {
        Picker("Group by", selection: $draft.groupBy) {
            ForEach(CustomViewGroupBy.allCases, id: \.self) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .labelsHidden()
    }

    // MARK: Icon

    private var iconGrid: some View {
        CustomViewFlowLayout(spacing: 4) {
            ForEach(CustomViewDraft.iconChoices, id: \.self) { icon in
                let isSelected = draft.iconName == icon
                Button {
                    draft.iconName = icon
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

    // MARK: Types / profiles

    private var typeChips: some View {
        VStack(alignment: .leading, spacing: 3) {
            CustomViewFlowLayout(spacing: 6) {
                ForEach(CustomViewDraft.typeOrder, id: \.self) { type in
                    CustomViewChip(
                        title: CustomView.pluralLabel(type),
                        systemImage: type.symbolName,
                        isOn: draft.types.contains(type)
                    ) {
                        if draft.types.contains(type) {
                            draft.types.remove(type)
                        } else {
                            draft.types.insert(type)
                        }
                    }
                }
            }
            if draft.types.isEmpty {
                issueText(CustomViewDraft.Issue.noTypes.message)
            }
        }
    }

    // MARK: Pinned

    private var pinnedPicker: some View {
        Picker("Pinned", selection: $draft.pinned) {
            ForEach(PinnedRule.allCases, id: \.self) { rule in
                Text(rule.displayName).tag(rule)
            }
        }
        .labelsHidden()
    }

    @ViewBuilder
    private var pinnedControl: some View {
        ViewThatFits(in: .horizontal) {
            pinnedPicker.pickerStyle(.segmented).fixedSize()
            pinnedPicker.pickerStyle(.menu).fixedSize()
        }
        if let hint = Self.pinnedHint(draft.pinned) {
            Text(hint)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Under the Pinned control; nil for Any.
    static func pinnedHint(_ rule: PinnedRule) -> String? {
        switch rule {
        case .any: return nil
        // `isPinned` = the browser's pin (companion extension) OR FastTab's own
        // pin (`MyOrderStore.overlayPinStatus`), which works in every browser.
        case .only: return "Tabs pinned in FastTab or the browser. No bookmarks or history."
        case .exclude: return "Leaves out pinned tabs, and their bookmarks and history."
        }
    }

    // MARK: Profiles

    /// One menu (OR within the field; nothing ticked = any profile) — a chip
    /// per profile took the whole editor with many browsers' profiles.
    @ViewBuilder
    private var profileMenu: some View {
        if profileOptions.isEmpty {
            Text("Any profile")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Menu {
                Toggle("Any profile", isOn: Binding(
                    get: { draft.profiles.isEmpty },
                    set: { if $0 { draft.profiles = [] } }
                ))
                Divider()
                ForEach(profileOptions) { option in
                    Toggle(option.label, isOn: Binding(
                        get: { draft.isProfileSelected(option.name) },
                        set: { _ in draft.toggleProfile(option.name) }
                    ))
                }
            } label: {
                Text(Self.profileMenuTitle(selected: draft.profiles, options: profileOptions))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .menuStyle(.button)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Profiles")
            // The label replaces the button title for VoiceOver; keep the selection audible.
            .accessibilityValue(Self.profileMenuTitle(selected: draft.profiles, options: profileOptions))
            if draft.profiles.count > 1 {
                Text(Self.selectedProfilesList(selected: draft.profiles, options: profileOptions))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The profile menu's button title: "Any profile", the one profile's
    /// label ("Default · Google Chrome"), or "3 profiles".
    static func profileMenuTitle(selected: [String], options: [CustomViewProfileOption]) -> String {
        let names = selected
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        let unique = names.filter { seen.insert($0.lowercased()).inserted }
        switch unique.count {
        case 0: return "Any profile"
        case 1: return label(of: unique[0], in: options)
        default: return "\(unique.count) profiles"
        }
    }

    /// The ticked profiles' labels, in menu order, for the line under the
    /// menu when more than one is ticked.
    static func selectedProfilesList(selected: [String], options: [CustomViewProfileOption]) -> String {
        options
            .filter { option in selected.contains { $0.caseInsensitiveCompare(option.name) == .orderedSame } }
            .map(\.label)
            .joined(separator: "; ")
    }

    private static func label(of name: String, in options: [CustomViewProfileOption]) -> String {
        options.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.label ?? name
    }

    // MARK: Domains

    private var domainsField: some View {
        VStack(alignment: .leading, spacing: 3) {
            TextField("github.com, *.docs.*, /regex/", text: $draft.domainsText)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .domains)
            let invalid = draft.invalidDomains
            if !invalid.isEmpty {
                issueText(CustomViewDraft.Issue.invalidDomains(invalid).message)
            } else if !draft.normalizedDomains.isEmpty {
                Text("Includes subdomains. Patterns: *wild*card, /regex/.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Last visited

    private enum LastVisitedMode: Hashable {
        case any, within, olderThan
    }

    private var lastVisitedMode: Binding<LastVisitedMode> {
        Binding(
            get: {
                switch draft.lastVisited {
                case .any: return .any
                case .within: return .within
                case .olderThan: return .olderThan
                }
            },
            set: { mode in
                switch mode {
                case .any: draft.lastVisited = .any
                case .within: draft.lastVisited = .within(draft.lastVisited.seconds ?? Self.defaultWithin)
                case .olderThan: draft.lastVisited = .olderThan(draft.lastVisited.seconds ?? Self.defaultOlderThan)
                }
            }
        )
    }

    private var lastVisitedSeconds: Binding<TimeInterval> {
        Binding(
            get: { draft.lastVisited.seconds ?? Self.defaultWithin },
            set: { seconds in
                switch draft.lastVisited {
                case .any: break
                case .within: draft.lastVisited = .within(seconds)
                case .olderThan: draft.lastVisited = .olderThan(seconds)
                }
            }
        )
    }

    /// Presets, plus the stored duration when it isn't one (an older or
    /// synced value) so the menu can show it.
    private var durationOptions: [LastVisitedPreset] {
        var options = LastVisitedRule.presets
        if let seconds = draft.lastVisited.seconds, !options.contains(where: { $0.seconds == seconds }) {
            options.append(LastVisitedPreset(seconds: seconds, displayName: LastVisitedRule.durationName(seconds)))
            options.sort { $0.seconds < $1.seconds }
        }
        return options
    }

    @ViewBuilder
    private var lastVisitedControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { lastVisitedModePicker; lastVisitedDurationPicker }
            VStack(alignment: .leading, spacing: 4) { lastVisitedModePicker; lastVisitedDurationPicker }
        }
        if let hint = CustomViewDraft.lastVisitedHint(rule: draft.lastVisited, historyReachDays: historyReachDays) {
            Text(hint)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var lastVisitedModePicker: some View {
        Picker("Last visited", selection: lastVisitedMode) {
            Text("Any").tag(LastVisitedMode.any)
            Text("Within").tag(LastVisitedMode.within)
            Text("More than").tag(LastVisitedMode.olderThan)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    @ViewBuilder
    private var lastVisitedDurationPicker: some View {
        if draft.lastVisited != .any {
            HStack(spacing: 4) {
                Picker("Duration", selection: lastVisitedSeconds) {
                    ForEach(durationOptions) { preset in
                        Text(preset.displayName).tag(preset.seconds)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                if case .olderThan = draft.lastVisited {
                    Text("ago")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: AI

    private var aiField: some View {
        VStack(alignment: .leading, spacing: 3) {
            TextField("Articles I want to read later", text: $draft.semanticPrompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
                .focused($focusedField, equals: .prompt)
                .disabled(!isAIAvailable)
            Text(isAIAvailable
                 ? "Describe what belongs here. Apple Intelligence checks the 300 most recent items the filters above find, on this Mac."
                 : CustomViewAI.unavailableMessage)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            // The field is disabled without Apple Intelligence; a prompt saved
            // earlier (or synced) must still be removable.
            if !isAIAvailable, CustomViewEditorForm.canRemoveAIFilter(draft: draft, isAIAvailable: isAIAvailable) {
                Button("Remove AI filter") {
                    draft.semanticPrompt = ""
                }
                .controlSize(.small)
            }
        }
    }

    /// The "Remove AI filter" button shows when the prompt field can't be
    /// edited (no Apple Intelligence) but holds a prompt.
    static func canRemoveAIFilter(draft: CustomViewDraft, isAIAvailable: Bool) -> Bool {
        !isAIAvailable && !draft.semanticPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func issueText(_ message: String) -> some View {
        Text(message)
            .font(.caption2)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Live preview data

/// Live data for the builder: how many items the draft's structured filters
/// match right now (debounced, evaluated off the main thread — the AI filter
/// is not applied) and which browser profiles exist to pick from.
@MainActor
final class CustomViewEditorPreview: ObservableObject {
    /// Nil until the first count lands.
    @Published private(set) var matchCount: Int?
    @Published private(set) var profileOptions: [CustomViewProfileOption] = []
    /// See `CustomViewDraft.historyReachDays`; refreshed with the sources.
    @Published private(set) var historyReachDays: Int?

    private let candidates: @MainActor () -> [BrowserSearchResult]
    private let prepareSources: @MainActor () -> Void
    private let debounceNanoseconds: UInt64
    private let now: () -> Date
    private var draft: CustomViewDraft?
    private var countTask: Task<Void, Never>?
    private var sourcesSubscription: AnyCancellable?
    private var generation = 0

    init(
        candidates: @escaping @MainActor () -> [BrowserSearchResult],
        prepareSources: @escaping @MainActor () -> Void = {},
        sourcesDidChange: AnyPublisher<Void, Never>,
        debounceNanoseconds: UInt64 = 250_000_000,
        now: @escaping () -> Date = Date.init
    ) {
        self.candidates = candidates
        self.now = now
        self.prepareSources = prepareSources
        self.debounceNanoseconds = debounceNanoseconds
        sourcesSubscription = sourcesDidChange
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let draft = self.draft else { return }
                    self.recompute(draft: draft, debounce: false)
                }
            }
    }

    static func live() -> CustomViewEditorPreview {
        let service = AppState.shared.browserService
        return CustomViewEditorPreview(
            candidates: { service.customViewCandidates() },
            prepareSources: { service.prepareCustomViewSources() },
            sourcesDidChange: service.customViewSourcesDidChange.eraseToAnyPublisher()
        )
    }

    /// Warms the bookmark/history caches (cold when Settings opens first).
    func start() {
        prepareSources()
    }

    func update(draft: CustomViewDraft) {
        let previous = self.draft
        self.draft = draft
        if let previous, previous.profiles != draft.profiles {
            profileOptions = CustomViewProfileOption.options(from: candidates(), selected: draft.profiles)
        }
        // Name / icon / AI prompt / grouping don't change the count.
        if let previous, previous.previewView.withoutCosmetics == draft.previewView.withoutCosmetics, matchCount != nil {
            return
        }
        recompute(draft: draft, debounce: previous != nil)
    }

    private func recompute(draft: CustomViewDraft, debounce: Bool) {
        if !debounce {
            let current = candidates()
            profileOptions = CustomViewProfileOption.options(from: current, selected: draft.profiles)
            historyReachDays = CustomViewDraft.historyReachDays(candidates: current, now: now())
        }
        generation += 1
        let gen = generation
        let delay = debounce ? debounceNanoseconds : 0
        countTask?.cancel()
        countTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled, let self else { return }
            let candidates = self.candidates()
            let view = draft.previewView
            let count = await Task.detached(priority: .userInitiated) {
                CustomViewFilter.evaluate(view, candidates: candidates).count
            }.value
            guard !Task.isCancelled, self.generation == gen else { return }
            self.matchCount = count
        }
    }

    /// The in-flight count, for tests.
    var pendingCount: Task<Void, Never>? { countTask }
}

private extension CustomView {
    /// Only the fields `CustomViewFilter.evaluate` reads.
    var withoutCosmetics: CustomView {
        var copy = self
        copy.name = ""
        copy.iconName = ""
        copy.semanticPrompt = ""
        copy.groupBy = .none
        return copy
    }
}

// MARK: - Small pieces

/// Toggle chip (types, profiles).
struct CustomViewChip: View {
    let title: String
    let systemImage: String?
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(title)
                    .lineLimit(1)
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(isOn ? Color.accentColor : Color.primary.opacity(0.8))
            .background(Capsule().fill(isOn ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06)))
            .overlay(Capsule().strokeBorder(isOn ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.12), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Left-aligned wrapping row (profile chips).
struct CustomViewFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews: subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

/// One labelled form row: label (trailing-aligned, fixed width) beside the
/// field when the row is at least `stackBelowWidth` wide, label above the
/// field otherwise — so the narrow edge-anchored bar gives every field its
/// full width instead of overflowing. First subview = label, second = field.
struct CustomViewFormRowLayout: Layout {
    var labelWidth: CGFloat
    var stackBelowWidth: CGFloat
    var spacing: CGFloat = 10
    var stackedSpacing: CGFloat = 3

    func isStacked(width: CGFloat?) -> Bool {
        (width ?? .infinity) < stackBelowWidth
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let frames = arrange(width: proposal.width, subviews: subviews)
        let width = proposal.width ?? max(frames.label.maxX, frames.content.maxX)
        return CGSize(width: width, height: max(frames.label.maxY, frames.content.maxY))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let frames = arrange(width: bounds.width, subviews: subviews)
        for (index, frame) in [frames.label, frames.content].enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    private func arrange(width: CGFloat?, subviews: Subviews) -> (label: CGRect, content: CGRect) {
        let label = subviews[0], content = subviews[1]
        if isStacked(width: width) {
            let labelSize = label.sizeThatFits(ProposedViewSize(width: width, height: nil))
            let contentProposal = ProposedViewSize(width: width, height: nil)
            let contentSize = content.sizeThatFits(contentProposal)
            return (
                CGRect(origin: .zero, size: labelSize),
                CGRect(x: 0, y: labelSize.height + stackedSpacing,
                       width: width ?? contentSize.width, height: contentSize.height)
            )
        }
        let contentWidth = width.map { max(0, $0 - labelWidth - spacing) }
        let labelProposal = ProposedViewSize(width: labelWidth, height: nil)
        let contentProposal = ProposedViewSize(width: contentWidth, height: nil)
        let labelSize = label.sizeThatFits(labelProposal)
        let contentSize = content.sizeThatFits(contentProposal)
        // Line the label's text up with the field's first line; capped so a
        // field with no text (the icon grid) keeps its label near the top.
        let labelBaseline = label.dimensions(in: labelProposal)[VerticalAlignment.firstTextBaseline]
        let contentBaseline = content.dimensions(in: contentProposal)[VerticalAlignment.firstTextBaseline]
        let shift = min(max(contentBaseline - labelBaseline, -labelSize.height), 6)
        return (
            CGRect(x: labelWidth - min(labelSize.width, labelWidth), y: max(shift, 0),
                   width: min(labelSize.width, labelWidth), height: labelSize.height),
            CGRect(x: labelWidth + spacing, y: max(-shift, 0),
                   width: contentWidth ?? contentSize.width, height: contentSize.height)
        )
    }
}
