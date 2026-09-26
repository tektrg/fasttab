import SwiftUI
import AppKit

/// "Sources" tab of Settings: which browsers/apps FastTab searches, and which
/// installed web apps get their own dedicated window instead of a browser tab.
struct SourcesSettingsView: View {
    @ObservedObject private var sourceSelection = SourceSelectionStore.shared
    @ObservedObject private var webAppCatalog = InstalledWebAppCatalog.shared
    @ObservedObject private var webAppRouting = WebAppRoutingStore.shared

    var body: some View {
        Form {
            Section("Sources") {
                ForEach(SearchSource.allCases) { source in
                    Toggle(source.displayName, isOn: Binding(
                        get: { sourceSelection.isEnabled(source) },
                        set: { sourceSelection.setEnabled(source, $0) }
                    ))
                    .disabled(!source.isInstalled)

                    if !source.isInstalled {
                        Text("Not installed on this Mac.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                if sourceSelection.needsRestartToApply {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .foregroundStyle(.orange)
                        Text("Restart FastTab to apply source changes.")
                            .font(.callout)
                        Spacer()
                        Button("Restart") {
                            restartFastTab()
                        }
                        .controlSize(.small)
                    }
                }
            }

            AutomationPermissionSection()

            Section("Open as App") {
                if webAppCatalog.apps.isEmpty {
                    Text("No installed web apps found. Use a browser's \"Install as app\" option to see it here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(webAppCatalog.apps) { app in
                        let routeKey = webAppRouteKeyString(for: app.homeURL)
                        let dormant = isWebAppDormant(app)

                        Toggle(app.name, isOn: Binding(
                            get: { routeKey.map { webAppRouting.decision(for: $0) == .enabled } ?? false },
                            set: { newValue in
                                guard let routeKey else { return }
                                webAppRouting.setDecision(newValue ? .enabled : .declined, for: routeKey)
                            }
                        ))
                        .disabled(dormant)

                        if dormant {
                            Text("\(app.browserAppName) isn't an enabled source above, so links can never route here.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Text("Enabled sites reopen from history or bookmarks in the app's own window instead of a new tab.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            webAppCatalog.rescanIfNeeded()
        }
    }

    private func isWebAppDormant(_ app: InstalledWebApp) -> Bool {
        !SearchSource.allCases.contains { $0.displayName == app.browserAppName && sourceSelection.isEnabled($0) }
    }
}
