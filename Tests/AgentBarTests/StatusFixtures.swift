import Foundation
@testable import AgentBar

/// Loads the redacted dashboard captures in `Fixtures/` and builds snapshots from them.
enum StatusFixtures {
    /// Server clock of every fixture (`serverTimeTs`).
    static let serverNow = Date(timeIntervalSince1970: 1_789_744_498)

    static func data(_ name: String) -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        return try! Data(contentsOf: url)
    }

    /// The fixture with `edit` applied to its top-level JSON object.
    static func data(_ name: String, editing edit: (inout [String: Any]) -> Void) -> Data {
        var object = try! JSONSerialization.jsonObject(with: data(name)) as! [String: Any]
        edit(&object)
        return try! JSONSerialization.data(withJSONObject: object)
    }

    static func snapshot(_ name: String) throws -> StatusSnapshot {
        try StatusSnapshotBuilder.snapshot(fromJSON: data(name), fetchedAt: serverNow)
    }

    /// Fixture agent ids: `00000000-0000-4000-8000-<n as 12 digits>`.
    static func sessionId(_ n: Int) -> String {
        "00000000-0000-4000-8000-" + String(format: "%012d", n)
    }
}

extension StatusSnapshot {
    func agent(labelled label: String) -> AgentSnapshot? {
        agents.first { $0.label == label }
    }
}
