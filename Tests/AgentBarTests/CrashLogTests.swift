import Foundation
import Testing
@testable import AgentBar

struct CrashLogTests {
    @Test func reportCarriesNameReasonAndStack() {
        let text = CrashLog.report(name: "NSGenericException", reason: "layout loop", stack: ["0 AppKit", "1 AgentBar"])
        #expect(text.contains("name: NSGenericException"))
        #expect(text.contains("reason: layout loop"))
        #expect(text.contains("0 AppKit\n1 AgentBar"))
    }

    @Test func writesTimestampedFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("crashlog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try #require(CrashLog.write("hello", to: dir))
        #expect(url.lastPathComponent.hasPrefix("crash-") && url.pathExtension == "log")
        #expect(try String(contentsOf: url, encoding: .utf8) == "hello")
    }
}
