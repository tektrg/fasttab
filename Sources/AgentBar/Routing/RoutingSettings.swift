import Foundation

/// What happens right after Jev has picked a destination agent for a routed message.
enum AfterRoutingBehavior: String, CaseIterable, Sendable {
    /// Show the pick and wait for the user to confirm before sending.
    case confirmFirst
    /// Send as soon as Jev has picked, with no confirmation step.
    case sendImmediately
}

/// The non-secret Jev routing preferences (the API key itself lives in Keychain — see
/// `RoutingAPIKeyStoring` — never here). Persisted in the app's defaults; mirrors
/// `SoundSettings`'s shape.
struct RoutingSettings: Equatable, Sendable {
    static let modelIDKey = "routingModelID"
    static let afterRoutingKey = "routingAfterRouting"
    static let systemPromptKey = "routingSystemPrompt"

    static let defaultModelID = "~typesafe/jev-latest"

    var modelID: String = defaultModelID
    var afterRouting: AfterRoutingBehavior = .confirmFirst
    /// Extra guidance folded into every Jev request, on top of the fixed `routeInstructions`
    /// (`OpenRouterJevClient`) — e.g. which live agent suits which kind of message. Empty by
    /// default; never overrides the base instructions' shape.
    var systemPrompt: String = ""

    static let standard = RoutingSettings()

    /// Reads the saved values; anything missing or not a known choice falls back to its default.
    static func load(from defaults: UserDefaults) -> RoutingSettings {
        let modelID = defaults.string(forKey: modelIDKey) ?? standard.modelID
        let afterRouting = (defaults.string(forKey: afterRoutingKey)).flatMap(AfterRoutingBehavior.init(rawValue:))
            ?? standard.afterRouting
        let systemPrompt = defaults.string(forKey: systemPromptKey) ?? standard.systemPrompt
        return RoutingSettings(modelID: modelID, afterRouting: afterRouting, systemPrompt: systemPrompt)
    }

    func save(to defaults: UserDefaults) {
        defaults.set(modelID, forKey: Self.modelIDKey)
        defaults.set(afterRouting.rawValue, forKey: Self.afterRoutingKey)
        defaults.set(systemPrompt, forKey: Self.systemPromptKey)
    }
}
