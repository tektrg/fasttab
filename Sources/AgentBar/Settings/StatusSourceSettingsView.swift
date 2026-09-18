import SwiftUI

/// "Status source" tab: which dashboard AgentBar reads agent status from.
/// The address is applied when editing ends (Return, or clicking away).
struct StatusSourceSettingsView: View {
    @ObservedObject var settings: AgentBarSettings
    let connectionTester: DashboardConnectionTester

    @State private var addressText = ""
    @State private var addressProblem: String?
    @State private var testState = TestState.idle
    @FocusState private var addressFieldFocused: Bool

    private enum TestState: Equatable {
        case idle, testing, finished(DashboardConnectionTester.Result)
    }

    var body: some View {
        Form {
            Section("Dashboard") {
                TextField("Address", text: $addressText, prompt: Text(DashboardEndpoint.defaultBaseURL.absoluteString))
                    .focused($addressFieldFocused)
                    .onSubmit(applyAddress)
                    .onChange(of: addressFieldFocused) { _, focused in
                        if !focused { applyAddress() }
                    }
                if let addressProblem {
                    Text(addressProblem)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Test connection", action: testConnection)
                        .disabled(testState == .testing)
                    Button("Reset to default", action: resetAddress)
                        .disabled(isShowingDefault)
                }
                testResultView
                Text("AgentBar reads which agents are running, and what each is doing, from the chief dashboard. A change takes effect immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear { addressText = settings.dashboardBaseURL.absoluteString }
    }

    @ViewBuilder
    private var testResultView: some View {
        switch testState {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView().controlSize(.small)
        case .finished(let result):
            let isConnected = { if case .connected = result { true } else { false } }()
            Label(result.message, systemImage: isConnected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(isConnected ? Color.green : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var isShowingDefault: Bool {
        addressProblem == nil && settings.dashboardBaseURL == DashboardEndpoint.defaultBaseURL
            && addressText.trimmingCharacters(in: .whitespaces) == DashboardEndpoint.defaultBaseURL.absoluteString
    }

    private func applyAddress() {
        switch settings.applyDashboardAddress(addressText) {
        case .valid(let url):
            addressProblem = nil
            addressText = url.absoluteString
        case .invalid(let reason):
            addressProblem = "\(reason) Still using \(settings.dashboardBaseURL.absoluteString)."
        }
    }

    private func resetAddress() {
        settings.resetDashboardAddress()
        addressText = settings.dashboardBaseURL.absoluteString
        addressProblem = nil
        testState = .idle
    }

    /// Tests what is in the field, saved or not, so a typo is caught before it is applied.
    private func testConnection() {
        guard case .valid(let url) = DashboardAddress.validate(addressText) else {
            testState = .finished(.failed(DashboardAddress.validate(addressText).invalidReason ?? "Invalid address."))
            return
        }
        testState = .testing
        Task {
            testState = .finished(await connectionTester.test(url))
        }
    }
}

private extension DashboardAddress.Validation {
    var invalidReason: String? {
        if case .invalid(let reason) = self { return reason }
        return nil
    }
}
