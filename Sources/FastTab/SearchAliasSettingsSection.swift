import SwiftUI

/// Settings for the "type a keyword, then search that site" aliases.
///
/// Two lists on purpose: the ones FastTab owns (editable here) and the ones
/// mirrored from the browsers' address-bar search engines (read-only, because
/// editing them in the browser is what makes the change sync to the user's
/// other machines).
struct SearchAliasSettingsSection: View {
    @ObservedObject private var store = SearchAliasStore.shared

    @State private var newKeyword: String = ""
    @State private var newDisplayName: String = ""
    @State private var newURLTemplate: String = ""
    @State private var addFailureMessage: String?
    @State private var isShowingImportedAliases = false

    var body: some View {
        Section("Search aliases") {
            Text("Type a keyword, press a trigger key, then search that site directly — the same way your browser's address bar works. If the site resolves IDs (Jira, for one), an exact ticket key jumps straight to the ticket.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            triggerKeyToggles
            userAliasList
            addAliasForm
            importedAliasList
        }
    }

    // MARK: - Trigger keys

    private var triggerKeyToggles: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 16) {
                Text("Trigger with")
                ForEach(SearchAliasTriggerKey.allCases, id: \.self) { key in
                    Toggle(key.label, isOn: Binding(
                        get: { store.isTriggerEnabled(key) },
                        set: { store.setTrigger(key, enabled: $0) }
                    ))
                }
            }

            if store.triggerKeys.isEmpty {
                Text("With both off, aliases never trigger.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - User aliases

    @ViewBuilder
    private var userAliasList: some View {
        if store.userAliases.isEmpty {
            Text("You haven't added any aliases yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(store.userAliases) { alias in
                HStack(spacing: 8) {
                    AliasSummaryLabel(alias: alias)
                    Spacer(minLength: 8)
                    Button {
                        store.removeUserAlias(keyword: alias.keyword)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove \(alias.keyword)")
                }
            }
        }
    }

    private var addAliasForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("e.g. jira", text: $newKeyword)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                TextField("e.g. Jira Search", text: $newDisplayName)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }

            HStack(spacing: 6) {
                TextField("https://example.com/search?q=%s", text: $newURLTemplate)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .lineLimit(1)
                Button("Add", action: addAlias)
                    .disabled(newKeyword.trimmed.isEmpty || newURLTemplate.trimmed.isEmpty)
            }

            if let addFailureMessage {
                Text(addFailureMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Put %s where the search text goes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func addAlias() {
        let didAdd = store.upsertUserAlias(
            keyword: newKeyword,
            displayName: newDisplayName,
            urlTemplate: newURLTemplate
        )
        guard didAdd else {
            addFailureMessage = SearchAliasTemplate.containsQueryPlaceholder(newURLTemplate)
                ? "That URL doesn't work as a web address. It needs to start with http:// or https://."
                : "Add %s to the URL so FastTab knows where the search text goes."
            return
        }
        addFailureMessage = nil
        newKeyword = ""
        newDisplayName = ""
        newURLTemplate = ""
    }

    // MARK: - Imported aliases

    private var groupedImportedAliases: [(alias: SearchAlias, otherProfileCount: Int)] {
        SearchAliasMatching.groupedByKeyword(store.importedAliases)
    }

    @ViewBuilder
    private var importedAliasList: some View {
        if !store.importedAliases.isEmpty {
            DisclosureGroup(isExpanded: $isShowingImportedAliases) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(groupedImportedAliases, id: \.alias.id) { entry in
                        AliasSummaryLabel(alias: entry.alias, otherProfileCount: entry.otherProfileCount)
                    }

                    Text("These come from your browsers' own search engines. Add or remove them in the browser's settings and they'll update here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            } label: {
                // Counts distinct keywords, not raw rows — the same engine is
                // registered in several profiles, and only one is reachable.
                Text("From your browsers (\(groupedImportedAliases.count))")
            }
        }
    }
}

private struct AliasSummaryLabel: View {
    let alias: SearchAlias
    var otherProfileCount: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(alias.keyword)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                Text(alias.displayName)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let profileName = alias.origin.profileName,
               let appName = alias.origin.browserAppName {
                Text(otherProfileCount > 0
                     ? "\(appName) · \(profileName) · also in \(otherProfileCount) more"
                     : "\(appName) · \(profileName)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
