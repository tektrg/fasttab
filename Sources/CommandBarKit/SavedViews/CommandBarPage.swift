import Foundation

/// An app's fixed command-bar pages (Fast Tab: Recents, Stack). `rawValue` is
/// what the app persists, so it must never change for a shipped page.
public protocol CommandBarBuiltinPage: Hashable, Sendable {
    var rawValue: String { get }
    init?(rawValue: String)
}

/// One swipeable page of a command bar: the app's built-in pages, then the
/// user's saved views (by id), then the trailing "＋ New View" builder page.
///
/// Persisted as a plain string (`rawValue`): a built-in page's own raw value,
/// "custom:<UUID>" for a saved view, "newView" for the builder page.
public enum CommandBarPage<Builtin: CommandBarBuiltinPage>: Hashable, Codable, Sendable {
    case builtin(Builtin)
    /// A user-defined saved view, by id.
    case custom(UUID)
    /// The trailing "＋ New View" page (hosts the inline view builder).
    case newView

    private static var customPrefix: String { "custom:" }
    private static var newViewRaw: String { "newView" }

    public var rawValue: String {
        switch self {
        case .builtin(let page): return page.rawValue
        case .custom(let id): return Self.customPrefix + id.uuidString
        case .newView: return Self.newViewRaw
        }
    }

    public init?(rawValue: String) {
        if rawValue == Self.newViewRaw {
            self = .newView
        } else if let page = Builtin(rawValue: rawValue) {
            self = .builtin(page)
        } else if rawValue.hasPrefix(Self.customPrefix),
                  let id = UUID(uuidString: String(rawValue.dropFirst(Self.customPrefix.count))) {
            self = .custom(id)
        } else {
            return nil
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let page = Self(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown view \(raw)"))
        }
        self = page
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public var builtinPage: Builtin? {
        if case .builtin(let page) = self { return page }
        return nil
    }

    public var customID: UUID? {
        if case .custom(let id) = self { return id }
        return nil
    }

    /// Saved views and the New View page are full pages of their own.
    public var isCustomPage: Bool {
        builtinPage == nil
    }

    /// Swipe order: `builtins`, then the saved views in order, then New View.
    public static func ordered(builtins: [Builtin], customIDs: [UUID]) -> [Self] {
        builtins.map(Self.builtin) + customIDs.map(Self.custom) + [.newView]
    }

    /// ⌘1…⌘9 targets: every page except New View (a builder, not a view, and
    /// its position shifts as views are added). ⌘N = the Nth entry; nil past
    /// the end.
    public static func numberedShortcutTarget(_ number: Int, in ordered: [Self]) -> Self? {
        let numbered = ordered.filter { $0 != .newView }
        guard number >= 1, number <= min(9, numbered.count) else { return nil }
        return numbered[number - 1]
    }

    /// The ⌘N number of each page in `ordered` (nil for New View and past ⌘9).
    public static func shortcutNumbers(in ordered: [Self]) -> [Int?] {
        var number = 0
        return ordered.map { page in
            guard page != .newView else { return nil }
            number += 1
            return number <= 9 ? number : nil
        }
    }

    /// The neighbouring page `step` places away in `ordered` (positive =
    /// forward), clamped: nil at either end or when `current` is not listed.
    public static func neighbor(of current: Self, step: Int, in ordered: [Self]) -> Self? {
        guard let index = ordered.firstIndex(of: current) else { return nil }
        let target = index + step
        guard ordered.indices.contains(target), target != index else { return nil }
        return ordered[target]
    }
}
