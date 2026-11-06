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
                CustomViewEditorForm(draft: $draft, profileOptions: preview.profileOptions)
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

    @ViewBuilder
    private var footer: some View {
        if isConfirmingDelete, let onDelete {
            HStack(spacing: 8) {
                Text("Delete “\(draft.previewView.name.isEmpty ? "this view" : draft.previewView.name)”? Your tabs, bookmarks and history stay as they are.")
                    .font(.caption)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Cancel") { isConfirmingDelete = false }
                    .keyboardShortcut(.cancelAction)
                Button("Delete View", role: .destructive, action: onDelete)
            }
        } else {
            HStack(spacing: 8) {
                if onDelete != nil {
                    Button("Delete View…") { isConfirmingDelete = true }
                }
                Text(matchCountText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Create View" : "Save", action: onSave)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!draft.isValid)
                    .help(draft.issues.first?.message ?? "Save (⌘Return)")
            }
        }
    }

    private var matchCountText: String {
        guard let count = preview.matchCount else { return "Counting…" }
        let base = count == 1 ? "1 item matches" : "\(count) items match"
        return draft.previewView.hasSemanticFilter ? base + " before the AI filter" : base
    }
}

/// The builder's fields. Reusable on its own; takes the draft and the
/// profile names to offer.
struct CustomViewEditorForm: View {
    @Binding var draft: CustomViewDraft
    let profileOptions: [CustomViewProfileOption]

    @FocusState private var focusedField: Field?
    @State private var isAIAvailable = CustomViewAI.isAvailable

    private enum Field: Hashable {
        case name, domains, keywords, prompt
    }

    private static let labelWidth: CGFloat = 86
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
            row("Profiles") { profileChips }
            row("Domains") { domainsField }
            row("Keywords") {
                TextField("Words in the title or address", text: $draft.keywords)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .keywords)
            }
            row("Last visited") { lastVisitedControls }
            row("AI filter") { aiField }
            row("Group by") {
                Picker("Group by", selection: $draft.groupBy) {
                    ForEach(CustomViewGroupBy.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
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
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: Self.labelWidth, alignment: .trailing)
            VStack(alignment: .leading, spacing: 4) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Icon

    private var iconGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(24), spacing: 4), count: 8), alignment: .leading, spacing: 4) {
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
            HStack(spacing: 6) {
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

    @ViewBuilder
    private var profileChips: some View {
        if profileOptions.isEmpty {
            Text("Any profile")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            CustomViewFlowLayout(spacing: 6) {
                ForEach(profileOptions) { option in
                    CustomViewChip(
                        title: option.label,
                        systemImage: nil,
                        isOn: draft.isProfileSelected(option.name)
                    ) {
                        draft.toggleProfile(option.name)
                    }
                }
            }
            if draft.profiles.isEmpty {
                Text("None selected: any profile.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Domains

    private var domainsField: some View {
        VStack(alignment: .leading, spacing: 3) {
            TextField("github.com, docs.rs", text: $draft.domainsText)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .domains)
            let invalid = draft.invalidDomains
            if !invalid.isEmpty {
                issueText(CustomViewDraft.Issue.invalidDomains(invalid).message)
            } else if !draft.normalizedDomains.isEmpty {
                Text("Includes subdomains.")
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

    private var lastVisitedControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { lastVisitedModePicker; lastVisitedDurationPicker }
            VStack(alignment: .leading, spacing: 4) { lastVisitedModePicker; lastVisitedDurationPicker }
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
                 ? "Describe what belongs here. Apple Intelligence checks the items the filters above find, on this Mac."
                 : CustomViewAI.unavailableMessage)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
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

    private let candidates: @MainActor () -> [BrowserSearchResult]
    private let prepareSources: @MainActor () -> Void
    private let debounceNanoseconds: UInt64
    private var draft: CustomViewDraft?
    private var countTask: Task<Void, Never>?
    private var sourcesSubscription: AnyCancellable?
    private var generation = 0

    init(
        candidates: @escaping @MainActor () -> [BrowserSearchResult],
        prepareSources: @escaping @MainActor () -> Void = {},
        sourcesDidChange: AnyPublisher<Void, Never>,
        debounceNanoseconds: UInt64 = 250_000_000
    ) {
        self.candidates = candidates
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
            profileOptions = CustomViewProfileOption.options(from: candidates(), selected: draft.profiles)
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
