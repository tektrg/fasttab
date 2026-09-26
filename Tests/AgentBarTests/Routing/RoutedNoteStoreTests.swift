import Foundation
import Testing
@testable import AgentBar

struct RoutedNoteStoreTests {
    @Test func emptyByDefault() {
        let store = RoutedNoteStore(defaults: makeScratchDefaults("routed-notes-empty"))
        #expect(store.load().isEmpty)
    }

    @Test func roundTripsWhatWasSaved() {
        let defaults = makeScratchDefaults("routed-notes-roundtrip")
        let store = RoutedNoteStore(defaults: defaults)
        let note = RoutedNote(id: UUID(), text: "fix the login timeout", sentAt: Date(timeIntervalSince1970: 1_800_000_000))
        store.save(["agent-1": [note]])
        #expect(RoutedNoteStore(defaults: defaults).load() == ["agent-1": [note]])
    }

    @Test func unreadableDataReadsAsNoNotesRatherThanCrashing() {
        let defaults = makeScratchDefaults("routed-notes-garbage")
        defaults.set(Data([0xFF, 0x00]), forKey: RoutedNoteStore.defaultsKey)
        #expect(RoutedNoteStore(defaults: defaults).load().isEmpty)
    }
}
