import Foundation

/// The user's answer to "always open this site as an app?" — `nil` (absent
/// from the dictionary) means not yet asked.
enum WebAppRoutingDecision: String, Codable, Sendable {
    case enabled
    case declined
}

/// UserDefaults-backed observable map of site (see `webAppRouteKeyString`) to
/// the user's routing decision for it. Mirrors `SourceSelectionStore`'s shape.
@MainActor
final class WebAppRoutingStore: ObservableObject {
    static let shared = WebAppRoutingStore()

    private static let defaultsKey = "FastTab.webAppRouting.v1"

    @Published private(set) var decisions: [String: WebAppRoutingDecision]

    init(defaults: UserDefaults = .standard) {
        self.decisions = Self.load(from: defaults)
    }

    /// `nil` means the user has never been asked about this site.
    func decision(for routeKey: String) -> WebAppRoutingDecision? {
        decisions[routeKey]
    }

    func setDecision(_ decision: WebAppRoutingDecision, for routeKey: String) {
        guard decisions[routeKey] != decision else { return }
        decisions[routeKey] = decision
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(decisions) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    private static func load(from defaults: UserDefaults) -> [String: WebAppRoutingDecision] {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: WebAppRoutingDecision].self, from: data) else {
            return [:]
        }
        return decoded
    }
}
