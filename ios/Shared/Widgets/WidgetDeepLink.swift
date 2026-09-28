import Foundation

/// Where a widget tap lands in the app. `fasttab://` URLs, built by the widget and parsed by the
/// app's `onOpenURL` (`FastTabMobileApp`). The only place the scheme and paths are spelled.
enum WidgetDeepLink: Equatable {
    /// Opens `url` in the reader; `highlightID` scrolls to a highlight.
    case read(url: URL, title: String, highlightID: String?)
    /// The More tab, whose top card is the reading stats.
    case stats
    /// The Tabs tab.
    case tabs

    static let scheme = "fasttab"

    private enum Host {
        static let read = "read"
        static let stats = "stats"
        static let tabs = "tabs"
    }

    private enum Query {
        static let url = "url"
        static let title = "title"
        static let highlight = "highlight"
    }

    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .read(let url, let title, let highlightID):
            components.host = Host.read
            components.queryItems = [
                URLQueryItem(name: Query.url, value: url.absoluteString),
                URLQueryItem(name: Query.title, value: title),
            ] + (highlightID.map { [URLQueryItem(name: Query.highlight, value: $0)] } ?? [])
        case .stats:
            components.host = Host.stats
        case .tabs:
            components.host = Host.tabs
        }
        return components.url ?? URL(string: "\(Self.scheme)://")!
    }

    init?(url: URL) {
        guard url.scheme == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        func value(_ name: String) -> String? {
            components.queryItems?.first { $0.name == name }?.value
        }
        switch components.host {
        case Host.read:
            guard let target = value(Query.url).flatMap(URL.init(string:)) else { return nil }
            self = .read(url: target, title: value(Query.title) ?? "", highlightID: value(Query.highlight))
        case Host.stats:
            self = .stats
        case Host.tabs:
            self = .tabs
        default:
            return nil
        }
    }
}
