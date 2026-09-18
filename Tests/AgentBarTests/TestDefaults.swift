import Foundation

/// A scratch UserDefaults domain per call, so tests never touch the real one.
func makeScratchDefaults(_ purpose: String = "settings") -> UserDefaults {
    let suiteName = "test.agentbar.\(purpose).\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}
