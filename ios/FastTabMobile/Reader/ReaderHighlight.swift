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

    public init(
        id: String = UUID().uuidString,
        urlKey: String,
        selectedText: String,
        color: HighlightColor,
        serializedRange: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.urlKey = urlKey
        self.selectedText = selectedText
        self.color = color
        self.serializedRange = serializedRange
        self.createdAt = createdAt
    }
}
