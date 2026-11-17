import Foundation
import Testing
@testable import AgentBar

struct CleanQuitMarkerTests {
    @Test func quitWritesMarkerAndLaunchClearsIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cleanquit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = CleanQuitMarker(directory: root.appendingPathComponent("AgentBar", isDirectory: true))
        #expect(!marker.exists)
        marker.markCleanQuit()          // creates the missing directory
        #expect(marker.exists)
        marker.markLaunched()
        #expect(!marker.exists)
        marker.markLaunched()           // no marker: still fine
        #expect(!marker.exists)
    }

    /// The keep-alive script hardcodes this path; they must agree.
    @Test func standardPathMatchesKeepAliveScript() throws {
        #expect(CleanQuitMarker.standard.url.path.hasSuffix("/Library/Application Support/AgentBar/clean-quit"))
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/agentbar-keepalive.sh")
        let text = try String(contentsOf: script, encoding: .utf8)
        #expect(text.contains("Library/Application Support/AgentBar/clean-quit"))
    }
}
