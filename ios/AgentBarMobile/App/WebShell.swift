import AgentBarCore
import SwiftUI

/// What the main screen shows and which page the web view should be on.
@MainActor
final class WebShellModel: ObservableObject {
    enum Phase: Equatable { case loading, ready, offline(String), tokenRejected }

    @Published var phase: Phase = .loading
    /// Bumped to make the web view (re)load `target`.
    @Published private(set) var loadRequest = 0
    private(set) var target: URL?

    var base: URL? { AgentBarClient.currentAPI()?.baseURL }

    /// Load base + `path` (only same-origin paths; anything else opens the home page).
    func open(path: Any? = nil) {
        guard let base else { return }
        target = WebRoutes.url(base: base, path: path)
        phase = .loading
        loadRequest += 1
    }
}

/// Root: settings until configured, then the full-screen PWA with a small gear overlay.
struct RootView: View {
    @ObservedObject var settings: SettingsModel
    @ObservedObject var shell: WebShellModel
    @State private var showSettings = false

    var body: some View {
        Group {
            if settings.isConfigured {
                ZStack(alignment: .topTrailing) {
                    WebContainer(shell: shell).ignoresSafeArea(edges: .bottom)
                    overlay
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape.fill").font(.footnote).padding(8)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("Settings")
                    .padding(.trailing, 8).padding(.top, 2).opacity(0.6)
                }
                // Safari-like keyboard: the web view keeps its full height and WebKit shrinks
                // visualViewport, which the PWA's sheet/composer logic is built on. Letting
                // SwiftUI resize the stack instead left the composer under the keyboard.
                .ignoresSafeArea(.keyboard)
                .sheet(isPresented: $showSettings, onDismiss: { shell.open() }) {
                    SettingsView(model: settings)
                }
            } else {
                SettingsView(model: settings)
            }
        }
        .onChange(of: settings.isConfigured) { _, configured in if configured { shell.open() } }
    }

    @ViewBuilder private var overlay: some View {
        switch shell.phase {
        case .offline(let reason):
            problem(icon: "wifi.slash", title: "Can't reach Mac",
                    detail: "Check that Tailscale is on and the Mac is awake.\n\(reason)")
        case .tokenRejected:
            problem(icon: "key.slash", title: "Token rejected",
                    detail: "The Mac didn't accept the saved token. Paste a new one in Settings.")
        case .loading, .ready:
            EmptyView()
        }
    }

    private func problem(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 44)).foregroundStyle(.secondary)
            Text(title).font(.title2.bold())
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Retry") { shell.open() }.buttonStyle(.borderedProminent)
            Button("Settings") { showSettings = true }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}
