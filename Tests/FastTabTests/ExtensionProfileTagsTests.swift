import Foundation
import Testing
@testable import FastTab

@Suite("Extension profile tags")
struct ExtensionProfileTagsTests {
    @Test func findsTheProfileHoldingTheTagAndItsName() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("edge-\(UUID().uuidString)")
        for (dir, tag) in [("Profile 1", "ftp-aaa"), ("Profile 3", "ftp-bbb")] {
            let store = base.appendingPathComponent("\(dir)/Local Extension Settings/extid")
            try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
            try Data("junk\u{0}fasttabProfileTag\"\(tag)\"junk".utf8).write(to: store.appendingPathComponent("000003.log"))
        }
        let state = #"{"profile":{"info_cache":{"Profile 1":{"name":"Your Chrome"},"Profile 3":{"name":"AptusFit"}}}}"#
        try Data(state.utf8).write(to: base.appendingPathComponent("Local State"))

        #expect(ExtensionProfileTags.lookUp(tag: "ftp-bbb", supportDirectory: base.path) == "AptusFit")
        #expect(ExtensionProfileTags.lookUp(tag: "ftp-aaa", supportDirectory: base.path) == "Your Chrome")
        #expect(ExtensionProfileTags.lookUp(tag: "ftp-zzz", supportDirectory: base.path) == nil)
    }

    @Test func helloCarriesTheTag() {
        guard case .hello(_, _, let tag) = ExtensionBridge.decodeInboundMessage(
            type: "hello", payload: ["app": "edge", "extensionVersion": "0.1.5", "profileTag": "ftp-x"], now: Date())
        else { Issue.record("not hello"); return }
        #expect(tag == "ftp-x")
    }
}
