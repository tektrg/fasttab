import SwiftUI

// MARK: - Highlight Color

public enum HighlightColor: String, Codable, CaseIterable, Sendable {
    case yellow, green, blue, pink

    public var uiColor: UIColor {
        switch self {
        case .yellow: return UIColor(red: 1.00, green: 0.92, blue: 0.23, alpha: 0.45)
        case .green:  return UIColor(red: 0.36, green: 0.87, blue: 0.54, alpha: 0.40)
        case .blue:   return UIColor(red: 0.26, green: 0.68, blue: 1.00, alpha: 0.40)
        case .pink:   return UIColor(red: 1.00, green: 0.43, blue: 0.68, alpha: 0.40)
        }
    }

    public var swiftUIColor: Color { Color(uiColor: uiColor) }

    /// CSS rgba() string used in the reader template
    public var cssRGBA: String {
        switch self {
        case .yellow: return "rgba(255, 235, 59, 0.45)"
        case .green:  return "rgba(92, 222, 138, 0.40)"
        case .blue:   return "rgba(66, 174, 255, 0.40)"
        case .pink:   return "rgba(255, 110, 173, 0.40)"
        }
    }

    public var label: String {
        switch self {
        case .yellow: return "Yellow"
        case .green:  return "Green"
        case .blue:   return "Blue"
        case .pink:   return "Pink"
        }
    }

    public var systemImage: String { "circle.fill" }
}

// MARK: - Highlight Model

/// A single user-created highlight on an article.
public struct ReaderHighlight: Codable, Identifiable, Hashable, Sendable {
    /// Stable identifier for this highlight
    public let id: String
    /// Canonical URL of the article (lowercased)
    public let urlKey: String
    /// The selected text (used as a fallback anchor and for display)
    public let selectedText: String
    /// Highlight colour chosen by the user
    public let color: HighlightColor
    /// Opaque JS-serialised range descriptor (passed back to `highlight.js`)
    public let serializedRange: String
    public let createdAt: Date
    /// Article title captured at highlight time. Absent on highlights created before this
    /// field existed; `ReaderHighlightTitleResolver` falls back to other sources for those.
    public let title: String?
    /// Raw article URL captured at highlight time, for opening the highlight later.
    public let urlString: String?

    // Explicit CodingKeys so old stored JSON (no `title`/`urlString`) still decodes.
    enum CodingKeys: String, CodingKey {
        case id, urlKey, selectedText, color, serializedRange, createdAt, title, urlString
    }

    public init(
        id: String = UUID().uuidString,
        urlKey: String,
        selectedText: String,
        color: HighlightColor,
        serializedRange: String,
        createdAt: Date = Date(),
        title: String? = nil,
        urlString: String? = nil
    ) {
        self.id = id
        self.urlKey = urlKey
        self.selectedText = selectedText
        self.color = color
        self.serializedRange = serializedRange
        self.createdAt = createdAt
        self.title = title
        self.urlString = urlString
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        urlKey = try c.decode(String.self, forKey: .urlKey)
        selectedText = try c.decode(String.self, forKey: .selectedText)
        color = try c.decode(HighlightColor.self, forKey: .color)
        serializedRange = try c.decode(String.self, forKey: .serializedRange)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        urlString = try c.decodeIfPresent(String.self, forKey: .urlString)
    }
}

public extension ReaderHighlight {
    /// URL to reopen this highlight's article: the raw URL captured at highlight time,
    /// falling back to the canonical key for highlights saved before `urlString` existed.
    var articleURL: URL? {
        urlString.flatMap(URL.init(string:)) ?? URL(string: urlKey)
    }
}

// MARK: - Title Resolution

/// Resolves a display title for a highlight, oldest-first source order:
/// the title stored on the highlight itself, then the extracted article cache,
/// then the Last Opened history, then finally the host name of the URL.
public enum ReaderHighlightTitleResolver {
    @MainActor
    public static func resolve(for highlight: ReaderHighlight) -> String {
        if let stored = highlight.title, !stored.isEmpty {
            return stored
        }
        guard let url = highlight.articleURL else {
            return highlight.urlKey
        }
        if let cached = ReaderArticleCache.shared.article(for: url)?.title, !cached.isEmpty {
            return cached
        }
        if let lastOpened = LastOpenedStore.shared.items.first(where: { $0.url == url.absoluteString })?.title,
           !lastOpened.isEmpty {
            return lastOpened
        }
        return url.host() ?? highlight.urlKey
    }
}
