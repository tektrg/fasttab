import SwiftUI
import Foundation

// MARK: - Font Family (Tier A: iOS built-in families only)

// Every case maps to a font family that ships with iOS itself, referenced by
// name through CSS — nothing is bundled, so there is no third-party font
// licence to clear for commercial use. (Deliberately NOT bundling SF / New York
// as files: Apple's licence only allows them via system APIs, which is what
// `-apple-system` / `ui-serif` / `ui-rounded` resolve to.)
public enum ReaderFontFamily: String, Codable, CaseIterable, Identifiable, Sendable {
    case systemSans
    case systemSerif
    case rounded
    case georgia
    case palatino
    case charter
    case helvetica
    case menlo

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .systemSans: return "System"
        case .systemSerif: return "Serif"
        case .rounded: return "Rounded"
        case .georgia: return "Georgia"
        case .palatino: return "Palatino"
        case .charter: return "Charter"
        case .helvetica: return "Helvetica"
        case .menlo: return "Mono"
        }
    }

    /// CSS `font-family` stack for the article body.
    public var cssBodyStack: String {
        switch self {
        case .systemSans:
            return "-apple-system, \"SF Pro Text\", Helvetica, Arial, sans-serif"
        case .systemSerif:
            return "ui-serif, \"New York\", Georgia, \"Times New Roman\", serif"
        case .rounded:
            return "ui-rounded, -apple-system, \"SF Pro Text\", sans-serif"
        case .georgia:
            return "Georgia, \"Times New Roman\", serif"
        case .palatino:
            return "Palatino, \"Palatino Linotype\", Georgia, serif"
        case .charter:
            return "Charter, Georgia, serif"
        case .helvetica:
            return "Helvetica, Arial, sans-serif"
        case .menlo:
            return "ui-monospace, Menlo, monospace"
        }
    }

    /// Title/headings stack. Mono body still gets a sans title so headings don't
    /// look like code.
    public var cssTitleStack: String {
        switch self {
        case .systemSerif, .georgia, .palatino, .charter:
            return cssBodyStack
        case .menlo:
            return "-apple-system, \"SF Pro Display\", Helvetica, Arial, sans-serif"
        default:
            return "-apple-system, \"SF Pro Display\", Helvetica, Arial, sans-serif"
        }
    }

    /// Native counterpart for the SwiftUI preview row in the settings sheet.
    /// Best-effort: falls back to the system font when the named family is absent.
    public func swiftUIFont(size: CGFloat) -> Font {
        switch self {
        case .systemSans: return .system(size: size)
        case .systemSerif: return .system(size: size, design: .serif)
        case .rounded: return .system(size: size, design: .rounded)
        case .georgia: return .custom("Georgia", size: size)
        case .palatino: return .custom("Palatino", size: size)
        case .charter: return .custom("Charter", size: size)
        case .helvetica: return .custom("Helvetica", size: size)
        case .menlo: return .system(size: size, design: .monospaced)
        }
    }
}

// MARK: - Colour Scheme + Line Height

public enum ReaderColorScheme: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

public enum ReaderLineHeight: String, Codable, CaseIterable, Identifiable, Sendable {
    case compact
    case regular
    case relaxed

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .compact: return "Compact"
        case .regular: return "Regular"
        case .relaxed: return "Relaxed"
        }
    }

    public var value: Double {
        switch self {
        case .compact: return 1.5
        case .regular: return 1.75
        case .relaxed: return 2.0
        }
    }
}

// MARK: - Settings Value

/// All user-customisable reader appearance, in one Codable value.
/// `updatedAt` powers last-writer-wins merging with iCloud Key-Value Store.
public struct ReaderReadingSettings: Codable, Equatable, Sendable {
    public static let fontSizeRange = 14...32
    public static let defaultFontSize = 18
    public static let defaultLightBackgroundHex = "#FAFAF8"
    public static let defaultDarkBackgroundHex = "#141414"
    public static let defaultSpeechRate = 1.0
    public static let speechRateOptions: [Double] = [0.75, 1.0, 1.25, 1.5, 2.0]

    public var effectiveSpeechRate: Double { speechRate ?? Self.defaultSpeechRate }
    /// Natural voice is on and offered in this build (DEBUG / TestFlight only for now).
    var usesNaturalVoice: Bool { (naturalVoiceEnabled ?? false) && AppDistribution.isDebugOrTestFlight }

    public var fontSize: Int
    public var fontFamily: ReaderFontFamily
    public var colorScheme: ReaderColorScheme
    public var lineHeight: ReaderLineHeight
    public var lightBackgroundHex: String
    public var darkBackgroundHex: String
    /// Read Aloud speed multiplier (1.0 = normal). Optional so settings saved
    /// before Read Aloud existed still decode; nil reads as `defaultSpeechRate`.
    public var speechRate: Double?
    /// Read Aloud voice the user picked (`AVSpeechSynthesisVoice.identifier`).
    /// Nil = automatic (best installed voice for the article's language).
    public var speechVoiceIdentifier: String?
    /// "Natural voice (beta)": Google voice via theindie-api. Nil/false = device voice.
    public var naturalVoiceEnabled: Bool?
    public var updatedAt: Date

    public static var defaults: Self {
        Self(
            fontSize: defaultFontSize,
            fontFamily: .systemSans,
            colorScheme: .system,
            lineHeight: .regular,
            lightBackgroundHex: defaultLightBackgroundHex,
            darkBackgroundHex: defaultDarkBackgroundHex,
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    public init(
        fontSize: Int = defaultFontSize,
        fontFamily: ReaderFontFamily = .systemSans,
        colorScheme: ReaderColorScheme = .system,
        lineHeight: ReaderLineHeight = .regular,
        lightBackgroundHex: String = defaultLightBackgroundHex,
        darkBackgroundHex: String = defaultDarkBackgroundHex,
        speechRate: Double? = nil,
        speechVoiceIdentifier: String? = nil,
        naturalVoiceEnabled: Bool? = nil,
        updatedAt: Date = Date()
    ) {
        self.fontSize = min(max(fontSize, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
        self.fontFamily = fontFamily
        self.colorScheme = colorScheme
        self.lineHeight = lineHeight
        self.lightBackgroundHex = Self.normalizedHex(lightBackgroundHex) ?? Self.defaultLightBackgroundHex
        self.darkBackgroundHex = Self.normalizedHex(darkBackgroundHex) ?? Self.defaultDarkBackgroundHex
        self.speechRate = speechRate
        self.speechVoiceIdentifier = speechVoiceIdentifier
        self.naturalVoiceEnabled = naturalVoiceEnabled
        self.updatedAt = updatedAt
    }

    /// `true` when every field matches the factory defaults (used for the
    /// "customised" dot on the settings button).
    public var isDefault: Bool {
        var d = Self.defaults
        d.updatedAt = updatedAt
        return self == d
    }

    // MARK: Effective appearance

    /// Which background hex applies for the current system appearance.
    /// - Parameter systemIsDark: pass `UITraitCollection.current.userInterfaceStyle == .dark`
    ///   (or SwiftUI `@Environment(\.colorScheme)`) from the call site so this
    ///   stays a pure function.
    public func effectiveBackgroundHex(systemIsDark: Bool) -> String {
        switch colorScheme {
        case .light: return lightBackgroundHex
        case .dark: return darkBackgroundHex
        case .system: return systemIsDark ? darkBackgroundHex : lightBackgroundHex
        }
    }

    public func resolvedTheme(systemIsDark: Bool) -> ReaderResolvedTheme {
        ReaderResolvedTheme.resolve(backgroundHex: effectiveBackgroundHex(systemIsDark: systemIsDark))
    }

    // MARK: Hex normalisation

    /// Normalises `#RGB`, `#RRGGBB`, `RGB`, `RRGGBB` to uppercase `#RRGGBB`.
    public static func normalizedHex(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 {
            s = s.map { "\($0)\($0)" }.joined()
        }
        guard s.count == 6, s.allSatisfy({ $0.isHexDigit }) else { return nil }
        return "#" + s
    }
}

// MARK: - Resolved Theme (background → full palette)

// Foreground colours are derived from the background's luminance so a freely
// picked background always stays readable. Computed in Swift (testable) and
// passed into the template as explicit CSS vars.
public struct ReaderResolvedTheme: Equatable, Sendable {
    public let backgroundHex: String
    public let foregroundHex: String
    public let mutedHex: String
    public let metaHex: String
    public let linkHex: String
    public let dividerRGBA: String
    public let codeBackgroundRGBA: String
    public let isDark: Bool

    public static func resolve(backgroundHex: String) -> Self {
        let bg = ReaderReadingSettings.normalizedHex(backgroundHex)
            ?? ReaderReadingSettings.defaultLightBackgroundHex
        let lum = relativeLuminance(hex: bg)
        let dark = lum < 0.4
        if dark {
            return Self(
                backgroundHex: bg,
                foregroundHex: "#F0F0EC",
                mutedHex: "#9A9A9A",
                metaHex: "#777777",
                linkHex: "#4EA8E8",
                dividerRGBA: "rgba(255,255,255,0.14)",
                codeBackgroundRGBA: "rgba(255,255,255,0.08)",
                isDark: true
            )
        } else {
            return Self(
                backgroundHex: bg,
                foregroundHex: "#1A1A1A",
                mutedHex: "#6B6B6B",
                metaHex: "#999999",
                linkHex: "#0071E3",
                dividerRGBA: "rgba(0,0,0,0.10)",
                codeBackgroundRGBA: "rgba(0,0,0,0.05)",
                isDark: false
            )
        }
    }

    /// WCAG relative luminance of a `#RRGGBB` colour, 0 (black) – 1 (white).
    public static func relativeLuminance(hex: String) -> Double {
        func channel(_ v: Double) -> Double {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let r = Double(Int(hex.dropFirst(1).prefix(2), radix: 16) ?? 0) / 255.0
        let g = Double(Int(hex.dropFirst(3).prefix(2), radix: 16) ?? 0) / 255.0
        let b = Double(Int(hex.dropFirst(5).prefix(2), radix: 16) ?? 0) / 255.0
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }
}

// MARK: - Background Presets

public extension ReaderReadingSettings {
    static let lightPresets: [String] = [
        "#FAFAF8", // Paper (default)
        "#FFFFFF", // White
        "#F5EFDC", // Cream
        "#EFE3C8", // Sepia
        "#F1F1EF", // Grey
        "#E8EDF3", // Cool mist
    ]

    static let darkPresets: [String] = [
        "#141414", // Dark (default)
        "#000000", // True black
        "#1C1917", // Warm charcoal
        "#101828", // Navy ink
        "#12261A", // Forest night
        "#261A12", // Espresso
    ]
}

// MARK: - Store (UserDefaults + iCloud Key-Value Store)

/// Persists `ReaderReadingSettings` locally and mirrors it to iCloud Key-Value
/// Store so reading appearance follows the user across devices.
///
/// Merge policy is last-writer-wins on `updatedAt`: every local mutation bumps
/// `updatedAt` and pushes to KVS; incoming KVS changes win only when newer.
/// Requires the `com.apple.developer.ubiquity-kvstore-identifier` entitlement;
/// without iCloud (signed out, tests) the store silently degrades to local-only.
@MainActor
public final class ReaderReadingSettingsStore: ObservableObject {
    public static let shared = ReaderReadingSettingsStore()

    static let defaultsKey = "FastTabMobile.readerReadingSettingsV1"
    static let cloudKey = "readerReadingSettingsV1"

    @Published public private(set) var settings: ReaderReadingSettings

    private let local: UserDefaults
    private let cloud: NSUbiquitousKeyValueStore?
    /// Set to `false` in tests to keep KVS out of the picture.
    var isCloudSyncEnabled: Bool
    /// `nonisolated(unsafe)` so `deinit` (nonisolated) can deregister it.
    /// Only ever touched from `init`/`deinit`; the singleton lives forever.
    private nonisolated(unsafe) var cloudObserver: NSObjectProtocol?

    init(
        local: UserDefaults = .standard,
        cloud: NSUbiquitousKeyValueStore? = .default,
        isCloudSyncEnabled: Bool = true
    ) {
        self.local = local
        self.cloud = cloud
        self.isCloudSyncEnabled = isCloudSyncEnabled
        self.settings = Self.loadLocal(from: local) ?? .defaults
        // Opportunistic merge: cloud may be newer than this device's disk copy.
        if isCloudSyncEnabled, let cloudSettings = Self.loadCloud(using: cloud) {
            if cloudSettings.updatedAt > settings.updatedAt {
                settings = cloudSettings
                persistLocal()
            }
        }
        cloudObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud,
            queue: .main
        ) { [weak self] _ in
            self?.mergeFromCloud()
        }
    }

    deinit {
        if let cloudObserver {
            NotificationCenter.default.removeObserver(cloudObserver)
        }
    }

    // MARK: - Mutations (each bumps updatedAt + persists both tiers)

    public func update(_ transform: (inout ReaderReadingSettings) -> Void) {
        var next = settings
        transform(&next)
        next.updatedAt = Date()
        settings = next
        persistLocal()
        pushToCloud()
    }

    public func setFontSize(_ size: Int) {
        update { $0.fontSize = min(max(size, ReaderReadingSettings.fontSizeRange.lowerBound), ReaderReadingSettings.fontSizeRange.upperBound) }
    }

    public func setFontFamily(_ family: ReaderFontFamily) {
        update { $0.fontFamily = family }
    }

    public func setColorScheme(_ scheme: ReaderColorScheme) {
        update { $0.colorScheme = scheme }
    }

    public func setLineHeight(_ height: ReaderLineHeight) {
        update { $0.lineHeight = height }
    }

    public func setLightBackground(hex: String) {
        guard let normalized = ReaderReadingSettings.normalizedHex(hex) else { return }
        update { $0.lightBackgroundHex = normalized }
    }

    public func setDarkBackground(hex: String) {
        guard let normalized = ReaderReadingSettings.normalizedHex(hex) else { return }
        update { $0.darkBackgroundHex = normalized }
    }

    public func setSpeechRate(_ rate: Double) {
        update { $0.speechRate = rate == ReaderReadingSettings.defaultSpeechRate ? nil : rate }
    }

    /// Nil = automatic voice for the article's language.
    public func setSpeechVoice(identifier: String?) {
        update { $0.speechVoiceIdentifier = identifier }
    }

    public func setNaturalVoiceEnabled(_ enabled: Bool) {
        update { $0.naturalVoiceEnabled = enabled }
    }

    public func resetToDefaults() {
        var next = ReaderReadingSettings.defaults
        next.updatedAt = Date()
        settings = next
        persistLocal()
        pushToCloud()
    }

    /// Applies an externally provided value (e.g. from a test or migration).
    /// Invalid hexes fall back to defaults via `ReaderReadingSettings.init`.
    func replaceAll(with next: ReaderReadingSettings) {
        settings = next
        persistLocal()
        pushToCloud()
    }

    // MARK: - Persistence

    private static func loadLocal(from local: UserDefaults) -> ReaderReadingSettings? {
        guard let data = local.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(ReaderReadingSettings.self, from: data) else {
            return nil
        }
        return decoded
    }

    private static func loadCloud(using cloud: NSUbiquitousKeyValueStore?) -> ReaderReadingSettings? {
        guard let data = cloud?.data(forKey: cloudKey),
              let decoded = try? JSONDecoder().decode(ReaderReadingSettings.self, from: data) else {
            return nil
        }
        return decoded
    }

    private func persistLocal() {
        guard let encoded = try? JSONEncoder().encode(settings) else { return }
        local.set(encoded, forKey: Self.defaultsKey)
    }

    private func pushToCloud() {
        guard isCloudSyncEnabled, let cloud,
              let encoded = try? JSONEncoder().encode(settings) else { return }
        cloud.set(encoded, forKey: Self.cloudKey)
        cloud.synchronize()
    }

    private func mergeFromCloud() {
        guard isCloudSyncEnabled,
              let incoming = Self.loadCloud(using: cloud),
              incoming.updatedAt > settings.updatedAt else { return }
        settings = incoming
        persistLocal()
    }
}

// MARK: - Hex → Color

public extension Color {
    init(readerHex hex: String) {
        let n = ReaderReadingSettings.normalizedHex(hex)
            ?? ReaderReadingSettings.defaultLightBackgroundHex
        let r = Double(Int(n.dropFirst(1).prefix(2), radix: 16) ?? 0) / 255.0
        let g = Double(Int(n.dropFirst(3).prefix(2), radix: 16) ?? 0) / 255.0
        let b = Double(Int(n.dropFirst(5).prefix(2), radix: 16) ?? 0) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}

public extension UIColor {
    convenience init(readerHex hex: String) {
        let n = ReaderReadingSettings.normalizedHex(hex)
            ?? ReaderReadingSettings.defaultLightBackgroundHex
        let r = CGFloat(Int(n.dropFirst(1).prefix(2), radix: 16) ?? 0) / 255.0
        let g = CGFloat(Int(n.dropFirst(3).prefix(2), radix: 16) ?? 0) / 255.0
        let b = CGFloat(Int(n.dropFirst(5).prefix(2), radix: 16) ?? 0) / 255.0
        self.init(red: r, green: g, blue: b, alpha: 1.0)
    }
}
