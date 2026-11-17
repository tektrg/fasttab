import XCTest
@testable import AgentBar

final class CleanQuitMarkerTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleanquit-\(UUID().uuidString)/AgentBar", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
    }

    func testQuitWritesMarkerAndLaunchClearsIt() {
        let marker = CleanQuitMarker(directory: dir)
        XCTAssertFalse(marker.exists)
        marker.markCleanQuit()          // creates the missing directory
        XCTAssertTrue(marker.exists)
        marker.markLaunched()
        XCTAssertFalse(marker.exists)
        marker.markLaunched()           // no marker: still fine
        XCTAssertFalse(marker.exists)
    }

    /// The keep-alive script hardcodes this path; they must agree.
    func testStandardPathMatchesKeepAliveScript() throws {
        XCTAssertTrue(CleanQuitMarker.standard.url.path
            .hasSuffix("/Library/Application Support/AgentBar/clean-quit"))
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/agentbar-keepalive.sh")
        let text = try String(contentsOf: script, encoding: .utf8)
        XCTAssertTrue(text.contains("Library/Application Support/AgentBar/clean-quit"))
    }
}
