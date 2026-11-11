import SwiftUI
import AppKit
import Combine
import CommandBarKit

/// The view builder: the filter form, a live match count, and Cancel / Save
/// (+ "Delete View…" with an inline confirmation when editing). One component
/// for both hosts — the command bar's tall page (`style: .bar`, inside the
/// fixed-height panel, so the form scrolls and the footer stays pinned) and
/// the Settings › Views sheet (`style: .sheet`). Frame, shared fields and
/// footer come from CommandBarKit (`SavedViewEditorShell`).
struct CustomViewEditor: View {
    typealias Style = SavedViewEditorStyle

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
        SavedViewEditorShell(isNew: isNew, style: style) {
            CustomViewEditorForm(
                draft: $draft,
                profileOptions: preview.profileOptions,
                historyReachDays: preview.historyReachDays
            )
        } footer: {
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
        .onAppear {
            preview.start()
            preview.update(draft: draft)
        }
        .onChange(of: draft) { _, newDraft in
            preview.update(draft: newDraft)
        }
    }
}

/// The shared `SavedViewEditorFooter` fed from a Fast Tab draft.
struct CustomViewEditorFooter: View {
    let draft: CustomViewDraft
    let isNew: Bool
    let matchCountText: String
    @Binding var isConfirmingDelete: Bool
    let onCancel: () -> Void
    let onSave: () -> Void
    let onDelete: (() -> Void)?

    var body: some View {
        SavedViewEditorFooter(
            viewName: draft.previewView.name,
            isNew: isNew,
            isValid: draft.isValid,
            firstIssue: draft.issues.first?.message,
            matchCountText: matchCountText,
            deleteReassurance: "Your tabs, bookmarks and history stay as they are.",
            isConfirmingDelete: $isConfirmingDelete,
            onCancel: onCancel,
            onSave: onSave,
            onDelete: onDelete
        )
    }

    static func matchCountText(count: Int?, hasSemanticFilter: Bool) -> String {
        SavedViewEditorFooter.matchCountText(count: count, hasSemanticFilter: hasSemanticFilter)
    }
}

/// The builder's fields: the shared Name / Icon / Keywords / AI filter
/// (`SavedViewEditorFields`) around Fast Tab's criteria rows. Reusable on its
/// own; takes the draft, the profile names to offer, and how far back cached
/// history reaches.
struct CustomViewEditorForm: View {
    @Binding var draft: CustomViewDraft
    let profileOptions: [CustomViewProfileOption]
    /// See `CustomViewDraft.historyReachDays`; nil = no history cached.
    var historyReachDays: Int? = nil

    @State private var isAIAvailable = CustomViewAI.isAvailable

    /// Narrower than this (the edge-anchored bar), labels go above their
    /// fields so every field gets the full width.
    static var stackedLabelsBelowWidth: CGFloat { SavedViewFormRow<EmptyView>.stackedLabelsBelowWidth }
    private static let defaultWithin: TimeInterval = 7 * 86_400
    private static let defaultOlderThan: TimeInterval = 30 * 86_400

    var body: some View {
        SavedViewEditorFields(
            name: $draft.name,
            iconName: $draft.iconName,
            keywords: $draft.keywords,
            semanticPrompt: $draft.semanticPrompt,
            iconChoices: CustomViewDraft.iconChoices,
            namePlaceholder: "Reading list",
            keywordsPlaceholder: "Words, *wild*card or /regex/ in title or URL",
            promptPlaceholder: "Articles I want to read later",
            isAIAvailable: isAIAvailable,
            aiHint: isAIAvailable
                ? "Describe what belongs here. Apple Intelligence checks the 300 most recent items the filters above find, on this Mac."
                : CustomViewAI.unavailableMessage
        ) {
            row("Show") { typeChips }
            row("Pinned") { pinnedControl }
            row("Profiles") { profileMenu }
            row("Domains") { domainsField }
        } afterKeywords: {
            row("Last visited") { lastVisitedControls }
        } trailing: {
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
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        SavedViewFormRow(label, content: content)
    }

    private var groupByPicker: some View {
        Picker("Group by", selection: $draft.groupBy) {
            ForEach(CustomViewGroupBy.allCases, id: \.self) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .labelsHidden()
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

    /// The "Remove AI filter" button shows when the prompt field can't be
    /// edited (no Apple Intelligence) but holds a prompt.
    static func canRemoveAIFilter(draft: CustomViewDraft, isAIAvailable: Bool) -> Bool {
        SavedViewEditorFields<EmptyView, EmptyView, EmptyView>.canRemoveAIFilter(prompt: draft.semanticPrompt, isAIAvailable: isAIAvailable)
    }

    private func issueText(_ message: String) -> some View {
        SavedViewIssueText(message)
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

// MARK: - Small pieces (shared in CommandBarKit)

typealias CustomViewChip = SavedViewChip
typealias CustomViewFlowLayout = SavedViewFlowLayout
typealias CustomViewFormRowLayout = SavedViewFormRowLayout
