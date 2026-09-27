import Foundation

/// The dashboard's persona registry as Settings > Personas edits it (`GET /api/personas/registry`,
/// and the `registry` of every `POST /api/personas` reply). Unlike `Persona` (what Jev routes to),
/// this lists every entry — hidden ones and ones with no description yet — because Settings is
/// where they get fixed. AgentBar never writes the registry file itself: the dashboard is its one
/// writer (see `dashboard/server/lib/persona_registry_edit.py`).
struct PersonaRegistry: Decodable, Equatable, Sendable {
    let globalInstructions: String
    let defaultGlobalInstructions: String
    let personas: [RegistryPersona]
    /// Hidden folders that are not personas (hidden suggestions), so they can be un-hidden.
    let hiddenSuggestions: [String]

    var usesDefaultGlobalInstructions: Bool { globalInstructions == defaultGlobalInstructions }
}

/// One registry entry.
struct RegistryPersona: Decodable, Equatable, Sendable, Identifiable {
    enum IdleMode: String, Codable, CaseIterable, Sendable {
        case resume, fresh
    }

    let address: String
    let name: String
    let description: String
    let routesWhen: [String]
    let notFor: [String]
    let extraInstructions: String
    let idle: IdleMode
    let resumeWithinDays: Double
    /// `in-place` or `script`: shown, never edited from Settings (a script is a command line).
    let start: String
    let hidden: Bool
    /// True when Jev may pick it: not hidden and a saved description.
    let offered: Bool

    var id: String { address }
}

/// A folder where Claude sessions ran recently (`GET /api/personas/suggestions`).
struct PersonaSuggestion: Decodable, Equatable, Sendable, Identifiable {
    let address: String
    /// Epoch seconds of the newest session there.
    let lastActive: Double
    let sessionCount: Int
    /// The folder's AGENTS.md/CLAUDE.md opening heading + paragraph; "" when it has none.
    let draftDescription: String

    var id: String { address }
}

/// The editable fields, as the editor sheet holds them. List fields are one line per entry.
struct PersonaDraft: Equatable, Sendable {
    var name = ""
    var description = ""
    var routesWhenText = ""
    var notForText = ""
    var extraInstructions = ""
    var idle = RegistryPersona.IdleMode.resume
    var resumeWithinDays = 3

    init() {}

    init(editing persona: RegistryPersona) {
        name = persona.name
        description = persona.description
        routesWhenText = persona.routesWhen.joined(separator: "\n")
        notForText = persona.notFor.joined(separator: "\n")
        extraInstructions = persona.extraInstructions
        idle = persona.idle
        resumeWithinDays = Int(persona.resumeWithinDays.rounded())
    }

    /// Adopting prefills the description from the folder's own instructions, and the name from the
    /// folder's last path component (lowercased, spaces to dashes) — both for the user to edit.
    init(adopting suggestion: PersonaSuggestion) {
        let folderName = suggestion.address.split(separator: "/").last.map(String.init) ?? ""
        name = folderName.lowercased().replacingOccurrences(of: " ", with: "-")
        description = suggestion.draftDescription
    }

    /// The `fields`/`persona` object the dashboard validates (it trims and drops blank lines too).
    var wireFields: [String: Any] {
        [
            "name": name.trimmingCharacters(in: .whitespacesAndNewlines),
            "description": description.trimmingCharacters(in: .whitespacesAndNewlines),
            "routesWhen": Self.lines(routesWhenText),
            "notFor": Self.lines(notForText),
            "extraInstructions": extraInstructions,
            "idle": idle.rawValue,
            "resumeWithinDays": resumeWithinDays,
        ]
    }

    var hasName: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var hasDescription: Bool { !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// One `POST /api/personas` call.
enum PersonaRegistryAction: Sendable {
    case adopt(address: String, draft: PersonaDraft)
    case edit(address: String, draft: PersonaDraft)
    case hide(address: String)
    case unhide(address: String)
    case remove(address: String)
    /// "" resets to the default block.
    case setGlobalInstructions(String)

    var body: [String: Any] {
        switch self {
        case .adopt(let address, let draft): ["action": "adopt", "address": address, "persona": draft.wireFields]
        case .edit(let address, let draft): ["action": "edit", "persona": address, "fields": draft.wireFields]
        case .hide(let address): ["action": "hide", "address": address]
        case .unhide(let address): ["action": "unhide", "address": address]
        case .remove(let address): ["action": "remove", "persona": address]
        case .setGlobalInstructions(let text): ["action": "setGlobalInstructions", "text": text]
        }
    }
}
