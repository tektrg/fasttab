import Foundation
@testable import AgentBar

/// In-memory stand-in for `RoutingAPIKeyStoring`. Tests must never write to the real
/// Keychain (same spirit as "never POST to the real dashboard in tests" — see AGENTS.md).
final class FakeRoutingAPIKeyStore: RoutingAPIKeyStoring, @unchecked Sendable {
    private(set) var stored: String?
    private(set) var setCallCount = 0

    func get() -> String? { stored }

    func set(_ key: String?) throws {
        setCallCount += 1
        if let key, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            stored = key
        } else {
            stored = nil
        }
    }
}
