import Foundation
import Testing
@testable import AgentBar

/// `Persona` decoding from `GET /api/personas` — in particular `idleStart`, added by a parallel P3
/// change and optional on the wire until it ships everywhere (see `Persona.IdleStart`'s doc comment).
struct PersonaTests {
    private func decode(_ json: String) throws -> Persona {
        try JSONDecoder().decode(Persona.self, from: Data(json.utf8))
    }

    @Test func decodesWithIdleStartResume() throws {
        let persona = try decode("""
        {"name": "chief-aptus", "address": "local:~/chief-aptus", "description": "the AptusFit chief",
         "routesWhen": ["AptusFit work"], "notFor": ["unrelated projects"], "idle": true,
         "offline": false, "mainRowId": "w1", "sessionRowIds": ["w2"], "idleStart": "resume"}
        """)
        #expect(persona.idleStart == .resume)
        #expect(persona.effectiveIdleStart == .resume)
    }

    @Test func decodesWithIdleStartFresh() throws {
        let persona = try decode("""
        {"name": "air-notes", "address": "local:~/air-notes", "description": "notes triage",
         "routesWhen": [], "notFor": [], "idle": true, "offline": false,
         "mainRowId": null, "sessionRowIds": [], "idleStart": "fresh"}
        """)
        #expect(persona.idleStart == .fresh)
        #expect(persona.effectiveIdleStart == .fresh)
    }

    /// The field the brief says a parallel change is still rolling out: missing entirely must decode
    /// cleanly (not throw), and read as "fresh" rather than silently defaulting to "resume".
    @Test func decodesWithoutIdleStartAtAllAndDefaultsEffectiveToFresh() throws {
        let persona = try decode("""
        {"name": "air-notes", "address": "local:~/air-notes", "description": "notes triage",
         "routesWhen": [], "notFor": [], "idle": true, "offline": false,
         "mainRowId": null, "sessionRowIds": []}
        """)
        #expect(persona.idleStart == nil)
        #expect(persona.effectiveIdleStart == .fresh)
    }

    @Test func decodesAFullyPopulatedLiveEntry() throws {
        let persona = try decode("""
        {"name": "chief-aptus", "address": "local:~/chief-aptus", "description": "the AptusFit chief",
         "routesWhen": ["AptusFit work", "sprint planning"], "notFor": ["personal notes"], "idle": false,
         "offline": false, "mainRowId": "w1:p1", "sessionRowIds": ["w1:p2", "w1:p3"], "idleStart": "resume"}
        """)
        #expect(persona.name == "chief-aptus")
        #expect(persona.address == "local:~/chief-aptus")
        #expect(persona.description == "the AptusFit chief")
        #expect(persona.routesWhen == ["AptusFit work", "sprint planning"])
        #expect(persona.notFor == ["personal notes"])
        #expect(persona.offline == false)
        #expect(persona.mainRowId == "w1:p1")
        #expect(persona.sessionRowIds == ["w1:p2", "w1:p3"])
    }
}
