import Foundation
import Testing
@testable import AgentBar

/// Exercises `RoutingAPIKeyStoring`'s contract via `FakeRoutingAPIKeyStore` — never the real
/// Keychain (`KeychainRoutingAPIKeyStore` has no headless-safe way to test without touching the
/// system Keychain, so its behavior is covered here through the same protocol it implements).
struct RoutingAPIKeyStoreTests {
    @Test func startsEmpty() {
        let store = FakeRoutingAPIKeyStore()
        #expect(store.get() == nil)
    }

    @Test func setThenGetRoundTrips() throws {
        let store = FakeRoutingAPIKeyStore()
        try store.set("sk-or-test-key")
        #expect(store.get() != nil)
        #expect(store.get()?.hasPrefix("sk-or-") == true)
    }

    @Test func settingNilDeletes() throws {
        let store = FakeRoutingAPIKeyStore()
        try store.set("sk-or-test-key")
        try store.set(nil)
        #expect(store.get() == nil)
    }

    @Test func settingEmptyOrWhitespaceDeletes() throws {
        let store = FakeRoutingAPIKeyStore()
        try store.set("sk-or-test-key")
        try store.set("   ")
        #expect(store.get() == nil)
        #expect(store.setCallCount == 2)
    }

    @Test func settingANewValueOverwritesTheOld() throws {
        let store = FakeRoutingAPIKeyStore()
        try store.set("sk-or-first")
        try store.set("sk-or-second")
        #expect(store.get()?.hasSuffix("second") == true)
    }
}
