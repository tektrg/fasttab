import Foundation
@testable import AgentBar

/// Hand-built `Persona` values, shared by every routing test that needs one (candidate building,
/// delivery, the confirm row's effect) — one place for the wire shape, like `AgentListFixtures.agent`.
enum PersonaFixtures {
    static func persona(
        _ name: String,
        description: String = "does things",
        routesWhen: [String] = ["thing A"],
        notFor: [String] = ["thing B"],
        offline: Bool = false,
        mainRowId: String? = nil,
        sessionRowIds: [String] = [],
        idleStart: Persona.IdleStart? = nil
    ) -> Persona {
        Persona(
            name: name, address: "local:~/\(name)", description: description,
            routesWhen: routesWhen, notFor: notFor, offline: offline,
            mainRowId: mainRowId, sessionRowIds: sessionRowIds, idleStart: idleStart
        )
    }
}
