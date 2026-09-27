import XCTest
@testable import FastTabMobile

/// Tests for Tier-A reading settings: fonts, backgrounds, contrast derivation,
/// local persistence and the iCloud Key-Value Store merge policy.
@MainActor
final class ReaderSettingsTests: XCTestCase {

    private var suite: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ReaderSettingsTests.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeStore() -> ReaderReadingSettingsStore {
        // `cloud: nil` + disabled sync keeps KVS out of unit tests entirely.
        ReaderReadingSettingsStore(local: suite, cloud: nil, isCloudSyncEnabled: false)
    }

    // MARK: - Font families (Tier A: built-in only)

    func testAllFontFamiliesHaveNonEmptyCSSStacks() {
        for family in ReaderFontFamily.allCases {
            XCTAssertFalse(family.cssBodyStack.isEmpty, "\(family.rawValue) body stack")
            XCTAssertFalse(family.cssTitleStack.isEmpty, "\(family.rawValue) title stack")
            XCTAssertFalse(family.label.isEmpty, "\(family.rawValue) label")
        }
    }

    func testMonoFamilyKeepsSansTitle() {
        // Headings must not render in monospace.
        XCTAssertFalse(ReaderFontFamily.menlo.cssTitleStack.lowercased().contains("menlo"))
        XCTAssertFalse(ReaderFontFamily.menlo.cssTitleStack.lowercased().contains("monospace"))
    }

    // MARK: - Value validation

    func testFontSizeClampedToRange() {
        XCTAssertEqual(ReaderReadingSettings(fontSize: 40).fontSize, 32)
        XCTAssertEqual(ReaderReadingSettings(fontSize: 8).fontSize, 14)
        XCTAssertEqual(ReaderReadingSettings(fontSize: 22).fontSize, 22)
    }

    func testHexNormalisation() {
        XCTAssertEqual(ReaderReadingSettings.normalizedHex("#fff"), "#FFFFFF")
        XCTAssertEqual(ReaderReadingSettings.normalizedHex("fafaf8"), "#FAFAF8")
        XCTAssertEqual(ReaderReadingSettings.normalizedHex("  #141414  "), "#141414")
        XCTAssertNil(ReaderReadingSettings.normalizedHex("zzz"))
        XCTAssertNil(ReaderReadingSettings.normalizedHex("#12345"))
        XCTAssertNil(ReaderReadingSettings.normalizedHex(""))
    }

    func testInvalidBackgroundHexFallsBackToDefault() {
        let s = ReaderReadingSettings(lightBackgroundHex: "not-a-colour")
        XCTAssertEqual(s.lightBackgroundHex, ReaderReadingSettings.defaultLightBackgroundHex)
    }

    func testDefaultsRoundTrip() throws {
        let data = try JSONEncoder().encode(ReaderReadingSettings.defaults)
        let decoded = try JSONDecoder().decode(ReaderReadingSettings.self, from: data)
        XCTAssertEqual(decoded, ReaderReadingSettings.defaults)
        XCTAssertTrue(decoded.isDefault)
    }

    // MARK: - Store persistence (local tier)

    func testStoreMutationsPersistAcrossInstances() {
        let store = makeStore()
        XCTAssertTrue(store.settings.isDefault)

        store.setFontFamily(.georgia)
        store.setFontSize(24)
        store.setColorScheme(.dark)
        store.setLineHeight(.relaxed)
        store.setLightBackground(hex: "#F5EFDC")
        store.setDarkBackground(hex: "#000000")

        // A fresh instance over the same UserDefaults suite sees everything.
        let reloaded = makeStore()
        XCTAssertEqual(reloaded.settings.fontFamily, .georgia)
        XCTAssertEqual(reloaded.settings.fontSize, 24)
        XCTAssertEqual(reloaded.settings.colorScheme, .dark)
        XCTAssertEqual(reloaded.settings.lineHeight, .relaxed)
        XCTAssertEqual(reloaded.settings.lightBackgroundHex, "#F5EFDC")
        XCTAssertEqual(reloaded.settings.darkBackgroundHex, "#000000")
        XCTAssertFalse(reloaded.settings.isDefault)
    }

    func testStoreIgnoresInvalidHex() {
        let store = makeStore()
        store.setLightBackground(hex: "garbage")
        XCTAssertEqual(store.settings.lightBackgroundHex, ReaderReadingSettings.defaultLightBackgroundHex)
    }

    func testStoreResetToDefaults() {
        let store = makeStore()
        store.setFontFamily(.palatino)
        store.setFontSize(30)
        XCTAssertFalse(store.settings.isDefault)

        store.resetToDefaults()
        XCTAssertTrue(makeStore().settings.isDefault)
    }

    // MARK: - Effective background

    func testEffectiveBackgroundHexFollowsScheme() {
        let store = makeStore()
        store.setLightBackground(hex: "#FFFFFF")
        store.setDarkBackground(hex: "#000000")

        store.setColorScheme(.light)
        XCTAssertEqual(store.settings.effectiveBackgroundHex(systemIsDark: true), "#FFFFFF")
        XCTAssertEqual(store.settings.effectiveBackgroundHex(systemIsDark: false), "#FFFFFF")

        store.setColorScheme(.dark)
        XCTAssertEqual(store.settings.effectiveBackgroundHex(systemIsDark: false), "#000000")

        store.setColorScheme(.system)
        XCTAssertEqual(store.settings.effectiveBackgroundHex(systemIsDark: true), "#000000")
        XCTAssertEqual(store.settings.effectiveBackgroundHex(systemIsDark: false), "#FFFFFF")
    }

    // MARK: - Contrast derivation

    func testDarkBackgroundResolvesToLightForeground() {
        let theme = ReaderResolvedTheme.resolve(backgroundHex: "#000000")
        XCTAssertTrue(theme.isDark)
        XCTAssertEqual(theme.foregroundHex, "#F0F0EC")
        XCTAssertEqual(theme.linkHex, "#4EA8E8")
    }

    func testLightBackgroundResolvesToDarkForeground() {
        let theme = ReaderResolvedTheme.resolve(backgroundHex: "#FFFFFF")
        XCTAssertFalse(theme.isDark)
        XCTAssertEqual(theme.foregroundHex, "#1A1A1A")
        XCTAssertEqual(theme.linkHex, "#0071E3")
    }

    func testCustomSepiaBackgroundStaysReadable() {
        // A freely picked mid-tone background must still pick the dark-ink side.
        let theme = ReaderResolvedTheme.resolve(backgroundHex: "#EFE3C8")
        XCTAssertFalse(theme.isDark)
        XCTAssertEqual(theme.foregroundHex, "#1A1A1A")
    }

    func testInvalidHexFallsBackToLightDefault() {
        let theme = ReaderResolvedTheme.resolve(backgroundHex: "!!!")
        XCTAssertEqual(theme.backgroundHex, ReaderReadingSettings.defaultLightBackgroundHex)
        XCTAssertFalse(theme.isDark)
    }

    // MARK: - WebView bridge

    func testSettingsJSContainsEveryVariable() {
        let settings = ReaderReadingSettings(
            fontSize: 22, fontFamily: .georgia, colorScheme: .dark,
            lineHeight: .relaxed, lightBackgroundHex: "#FFFFFF", darkBackgroundHex: "#000000"
        )
        let theme = ReaderResolvedTheme.resolve(backgroundHex: "#000000")
        let js = ReaderWebView.settingsJS(settings: settings, theme: theme)

        for token in ["--reader-font-size", "--reader-font-body", "--reader-font-title",
                      "--reader-line-height", "--bg", "--fg", "--fg-muted", "--fg-meta",
                      "--link", "--divider", "--code-bg", "dataset.theme"] {
            XCTAssertTrue(js.contains(token), "missing \(token)")
        }
        XCTAssertTrue(js.contains("22px"))
        XCTAssertTrue(js.contains("Georgia"))
        XCTAssertTrue(js.contains("#000000"))
    }

    // MARK: - ViewModel wiring

    func testViewModelMirrorsSharedStoreSettings() {
        let vm = ReaderViewModel(url: URL(string: "https://example.com/vm-settings")!, title: "T", statsRecorder: .isolatedForTests())
        XCTAssertEqual(vm.fontSize, ReaderReadingSettingsStore.shared.settings.fontSize)
        XCTAssertEqual(vm.readerSettings, ReaderReadingSettingsStore.shared.settings)
    }

    func testViewModelFontSizeStepsPersistToSharedStore() {
        let before = ReaderReadingSettingsStore.shared.settings.fontSize
        defer { ReaderReadingSettingsStore.shared.setFontSize(before) }

        let vm = ReaderViewModel(url: URL(string: "https://example.com/vm-steps")!, title: "T", statsRecorder: .isolatedForTests())
        vm.increaseFontSize()
        XCTAssertEqual(
            ReaderReadingSettingsStore.shared.settings.fontSize,
            min(before + 2, ReaderReadingSettings.fontSizeRange.upperBound)
        )
        vm.decreaseFontSize()
        vm.decreaseFontSize()
        XCTAssertEqual(
            ReaderReadingSettingsStore.shared.settings.fontSize,
            max(before - 2, ReaderReadingSettings.fontSizeRange.lowerBound)
        )
    }
}
