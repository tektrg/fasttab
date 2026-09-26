import Testing
@testable import FastTab

struct ExtensionSetupStateTests {
    private let edge: Set<String> = ["Microsoft Edge"]

    @Test func connectedAndEnabledIsUsable() {
        #expect(ExtensionSetupState.resolve(extensionEnabled: true, compatibleAppNames: edge, mismatchedAppNames: []) == .usable)
    }

    /// The reported bug: extension connected, setting stored off → must not read as "waiting".
    @Test func connectedButSettingOffIsTurnedOff() {
        #expect(ExtensionSetupState.resolve(extensionEnabled: false, compatibleAppNames: edge, mismatchedAppNames: []) == .turnedOff)
    }

    @Test func onlyMismatchedConnectionsIsVersionMismatch() {
        #expect(ExtensionSetupState.resolve(extensionEnabled: true, compatibleAppNames: [], mismatchedAppNames: edge) == .versionMismatch)
    }

    @Test func compatibleConnectionWinsOverMismatchedOne() {
        #expect(ExtensionSetupState.resolve(extensionEnabled: true, compatibleAppNames: edge, mismatchedAppNames: ["Google Chrome"]) == .usable)
    }

    @Test func nothingConnectedIsWaiting() {
        #expect(ExtensionSetupState.resolve(extensionEnabled: true, compatibleAppNames: [], mismatchedAppNames: []) == .waiting)
        #expect(ExtensionSetupState.resolve(extensionEnabled: false, compatibleAppNames: [], mismatchedAppNames: []) == .waiting)
    }
}
