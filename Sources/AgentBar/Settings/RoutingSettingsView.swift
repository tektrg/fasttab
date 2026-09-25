import SwiftUI

/// "Routing" tab: Jev message routing — the OpenRouter API key (Keychain-backed, never
/// UserDefaults), which model to route with, and what happens once Jev has picked a
/// destination agent. Fields apply on submit/blur, mirroring `StatusSourceSettingsView`.
struct RoutingSettingsView: View {
    @ObservedObject var settings: AgentBarSettings
    var keyStore: RoutingAPIKeyStoring = KeychainRoutingAPIKeyStore()
    var makeClient: (String, String) -> JevRoutingClient = { apiKey, model in
        OpenRouterJevClient(apiKey: apiKey, model: model)
    }

    @State private var apiKeyText = ""
    @State private var hasStoredKey = false
    @State private var apiKeyProblem: String?
    @State private var modelIDText = ""
    @State private var systemPromptText = ""
    @State private var testState = TestState.idle
    @FocusState private var apiKeyFieldFocused: Bool
    @FocusState private var modelIDFieldFocused: Bool
    @FocusState private var systemPromptFieldFocused: Bool

    private enum TestState: Equatable {
        case idle, testing, succeeded, failed(String)
    }

    var body: some View {
        Form {
            Section("OpenRouter") {
                SecureField(apiKeyPlaceholder, text: $apiKeyText)
                    .focused($apiKeyFieldFocused)
                    .onSubmit(applyAPIKey)
                    .onChange(of: apiKeyFieldFocused) { _, focused in
                        if !focused { applyAPIKey() }
                    }
                if let apiKeyProblem {
                    Text(apiKeyProblem)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                TextField("Model", text: $modelIDText, prompt: Text(RoutingSettings.defaultModelID))
                    .focused($modelIDFieldFocused)
                    .onSubmit(applyModelID)
                    .onChange(of: modelIDFieldFocused) { _, focused in
                        if !focused { applyModelID() }
                    }

                HStack {
                    Button("Test", action: runTest)
                        .disabled(testState == .testing || (apiKeyText.isEmpty && !hasStoredKey))
                    testResultView
                }

                Text("Jev picks which agent a routed message should go to. The key is stored in the Keychain, not in plain settings, and is never shown back once saved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Jev guidance") {
                TextEditor(text: $systemPromptText)
                    .font(.system(size: 12))
                    .frame(minHeight: 56, maxHeight: 120)
                    .focused($systemPromptFieldFocused)
                    .onChange(of: systemPromptFieldFocused) { _, focused in
                        if !focused { applySystemPrompt() }
                    }
                Text("Extra guidance for Jev on how to route messages — for example, when it should start a new AptusFit worker instead of routing to an existing agent. This is advisory context only: it can steer which candidate Jev picks, but it can never change the routing task itself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("After routing") {
                Picker("After routing", selection: Binding(
                    get: { settings.routing.afterRouting },
                    set: { choice in settings.updateRouting { $0.afterRouting = choice } }
                )) {
                    Text("Confirm first").tag(AfterRoutingBehavior.confirmFirst)
                    Text("Send immediately").tag(AfterRoutingBehavior.sendImmediately)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("Send immediately types straight into the agent Jev picks, with no chance to check first. A wrong pick types into the wrong agent's terminal, and that can't be undone.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            hasStoredKey = keyStore.get() != nil
            modelIDText = settings.routing.modelID
            systemPromptText = settings.routing.systemPrompt
        }
        // Blur-only saving (above) silently drops a typed-but-unblurred edit if the tab/window
        // closes first (⌘W, switching Settings tabs, clicking the panel's own close button) —
        // exactly how `routingSystemPrompt` was found empty despite being typed. This is the
        // backstop: whatever is currently typed is saved on the way out, blurred or not.
        .onDisappear {
            applySystemPrompt()
            applyModelID()
        }
    }

    private var apiKeyPlaceholder: String {
        hasStoredKey ? "•••• set" : "API key"
    }

    @ViewBuilder
    private var testResultView: some View {
        switch testState {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView().controlSize(.small)
        case .succeeded:
            Label("Routing works", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Only saves when the user actually typed something; blurring an untouched (empty)
    /// field never deletes a key that is already stored.
    private func applyAPIKey() {
        guard !apiKeyText.isEmpty else { return }
        do {
            try keyStore.set(apiKeyText)
            apiKeyProblem = nil
            hasStoredKey = keyStore.get() != nil
            apiKeyText = ""
        } catch {
            apiKeyProblem = "Could not save the key: \(error.localizedDescription)"
        }
    }

    private func applyModelID() {
        let trimmed = modelIDText.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? RoutingSettings.defaultModelID : trimmed
        settings.updateRouting { $0.modelID = resolved }
        modelIDText = resolved
    }

    private func applySystemPrompt() {
        let trimmed = systemPromptText.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.updateRouting { $0.systemPrompt = trimmed }
        systemPromptText = trimmed
    }

    /// Tests the currently-typed key (falling back to the stored one when the field is
    /// blank) and the currently-typed model id, neither of which needs to be saved first.
    private func runTest() {
        let apiKey = apiKeyText.isEmpty ? (keyStore.get() ?? "") : apiKeyText
        guard !apiKey.isEmpty else {
            testState = .failed("Enter an API key first.")
            return
        }
        let trimmedModel = modelIDText.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = trimmedModel.isEmpty ? RoutingSettings.defaultModelID : trimmedModel

        testState = .testing
        Task {
            let client = makeClient(apiKey, model)
            let outcome = await client.route(
                text: "test",
                candidates: [RouteCandidate(agentID: "test", summary: "test")]
            )
            switch outcome {
            case .picked, .createNew:
                // A single, plain "test" candidate is never a "new:" id, so `.createNew` should
                // not occur here in practice — treated the same as `.picked` regardless: either
                // one means the round trip to OpenRouter worked.
                testState = .succeeded
            case .none:
                testState = .failed("Jev did not pick an agent.")
            case .failed(let reason):
                testState = .failed(reason)
            }
        }
    }
}
