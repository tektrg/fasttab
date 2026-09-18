import AppKit
import Testing
@testable import CommandBarKit

@MainActor
private final class Recorder {
    var advances = 0
    var commits = 0
}

/// Session whose shortcut modifier is ⌘, with counting callbacks.
@MainActor
private func makeSession(advanceLandsOnItem: Bool = true) -> (CycleSession, Recorder) {
    let recorder = Recorder()
    let session = CycleSession(isShortcutModifierHeld: { $0.contains(.command) })
    session.onAdvance = {
        recorder.advances += 1
        return advanceLandsOnItem
    }
    session.onCommit = { recorder.commits += 1 }
    return (session, recorder)
}

@MainActor
@Test func advanceFiresOnAdvanceAndSetsHasCycled() {
    let (session, recorder) = makeSession()
    session.advance()
    #expect(recorder.advances == 1)
    #expect(session.hasCycled)
}

@MainActor
@Test func advanceOntoSearchFieldDoesNotArmCommit() {
    let (session, recorder) = makeSession(advanceLandsOnItem: false)
    session.advance()
    #expect(recorder.advances == 1)
    #expect(!session.hasCycled)
}

@MainActor
@Test func releaseAfterCycleCommitsOnce() {
    let (session, recorder) = makeSession()
    #expect(!session.handleFlagsChanged(.command))
    session.advance()
    session.advance()
    #expect(!session.handleFlagsChanged([.command, .shift]))
    #expect(session.isModifierHeld)

    #expect(session.handleFlagsChanged([]))
    #expect(recorder.commits == 1)
    #expect(!session.hasCycled)
    #expect(!session.isModifierHeld)

    #expect(!session.handleFlagsChanged([]))
    #expect(recorder.commits == 1)
}

@MainActor
@Test func releaseWithoutCycleDoesNothing() {
    let (session, recorder) = makeSession()
    #expect(!session.handleFlagsChanged(.command))
    #expect(!session.handleFlagsChanged([]))
    #expect(recorder.commits == 0)
}

@MainActor
@Test func resetClearsCycle() {
    let (session, recorder) = makeSession()
    session.advance()
    session.reset()
    #expect(!session.hasCycled)
    #expect(!session.handleFlagsChanged([]))
    #expect(recorder.commits == 0)
}
