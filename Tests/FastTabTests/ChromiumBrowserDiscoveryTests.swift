import Foundation
import IndieBrowserTabs
import Testing
@testable import FastTab

struct ChromiumBrowserDiscoveryTests {
    @Test func ardiaSupportDirectoryResolvesToKnownChromiumPath() {
        let dir = ChromiumBrowserDiscovery.resolveSupportDirectory(
            appName: "Ardia",
            bundleIdentifier: "com.ardia.browser"
        )
        #expect(dir == "~/Library/Application Support/com.ardia.browser/Chromium")
    }

    @Test func resolvesUnknownChromiumBrowserSupportDirectoryFromDisk() throws {
        let fm = FileManager.default
        let tempHome = fm.temporaryDirectory.appendingPathComponent("fasttab-discovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tempHome) }

        let userData = tempHome.appendingPathComponent("Library/Application Support/NovaBrowser/User Data", isDirectory: true)
        let defaultProfile = userData.appendingPathComponent("Default", isDirectory: true)
        try fm.createDirectory(at: defaultProfile, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: userData.appendingPathComponent("Local State"))
        try Data().write(to: defaultProfile.appendingPathComponent("History"))

        let resolved = ChromiumBrowserDiscovery.resolveSupportDirectory(
            appName: "NovaBrowser",
            bundleIdentifier: "com.example.novabrowser",
            homeDirectory: tempHome
        )
        #expect(resolved == "~/Library/Application Support/NovaBrowser/User Data")
    }

    @Test func rejectsElectronAppSupportFolderWithoutBrowserProfiles() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("fasttab-electron-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tempDir) }

        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: tempDir.appendingPathComponent("Local State"))

        #expect(!ChromiumBrowserDiscovery.looksLikeChromiumUserDataDirectory(tempDir))
    }

    @Test func detectsChromiumAndRejectsElectronBundles() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("fasttab-bundles-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        // Chromium fork with renamed framework + Helpers
        let forkApp = root.appendingPathComponent("Fork.app", isDirectory: true)
        let helperApp = forkApp.appendingPathComponent(
            "Contents/Frameworks/Fork Framework.framework/Versions/1.0/Helpers/Fork Helper.app",
            isDirectory: true
        )
        try fm.createDirectory(at: helperApp, withIntermediateDirectories: true)
        #expect(ChromiumBrowserDiscovery.isChromiumBrowserBundle(at: forkApp, bundleIdentifier: "com.example.fork"))

        // Electron app
        let electronApp = root.appendingPathComponent("Notes.app", isDirectory: true)
        let electronFW = electronApp.appendingPathComponent("Contents/Frameworks/Electron Framework.framework", isDirectory: true)
        try fm.createDirectory(at: electronFW, withIntermediateDirectories: true)
        #expect(!ChromiumBrowserDiscovery.isChromiumBrowserBundle(at: electronApp, bundleIdentifier: "com.example.notes"))
    }

    @Test func extensionBridgeMatchesBrowserExecutablePath() {
        let ardiaSpec = ChromiumBrowserSpec(
            appName: "Ardia",
            bundleIdentifier: "com.ardia.browser",
            supportDirectory: "~/Library/Application Support/com.ardia.browser/Chromium"
        )
        let matched = ExtensionBridge.matchBrowserAppName(
            executablePath: "/Applications/Ardia.app/Contents/Frameworks/Chromium Framework.framework/Versions/158.0/Helpers/Chromium Helper.app/Contents/MacOS/Chromium Helper",
            specs: [ChromiumBrowserSpec.chrome, ardiaSpec]
        )
        #expect(matched == "Ardia")
    }

    @Test func chromiumScriptsIncludeArdiaFallbacks() {
        let browser = ScriptableBrowser(bundleID: "com.ardia.browser", appName: "Ardia", dialect: .chromium)
        let readScript = BrowserTabScripts.readScript(browser, timeoutSeconds: nil)
        #expect(readScript.contains("title of window w"))
        #expect(readScript.contains("name of window w"))
        #expect(readScript.contains("«property GNam» of window w"))
        #expect(readScript.contains("«property acPr» of window w"))
        #expect(!readScript.contains("given name"))

        let fs = "\u{1F}"
        let parsed = BrowserTabScripts.parse(
            "1\(fs)1\(fs)true\(fs)Dashboard\(fs)https://example.com\(fs)Dashboard\(fs)\(fs)\(fs)\(fs)AptusFit"
        )
        #expect(parsed.count == 1)
        #expect(parsed[0].windowProfileName == "AptusFit")

        let focusScript = BrowserTabScripts.focusScript(browser, url: "https://example.com", window: 1, tab: 2, timeoutSeconds: nil)
        #expect(focusScript.contains("set index of w to 1"))
        #expect(focusScript.contains("focus (tab i of w)"))
    }

    @Test func ardiaSessionJSONOverridesGenericChromiumProfileNames() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("fasttab-ardia-profiles-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let chromium = root.appendingPathComponent("Chromium", isDirectory: true)
        let defaultDir = chromium.appendingPathComponent("Default", isDirectory: true)
        let secondDir = chromium.appendingPathComponent("Profile p-mwyp8kdos1f6-16", isDirectory: true)
        try fm.createDirectory(at: defaultDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: secondDir, withIntermediateDirectories: true)
        try Data().write(to: defaultDir.appendingPathComponent("History"))
        try Data().write(to: secondDir.appendingPathComponent("History"))

        let localState = """
        {"profile":{"info_cache":{"Default":{"name":"Your Ardia"},"Profile p-mwyp8kdos1f6-16":{"name":"Person 1"}}}}
        """
        try Data(localState.utf8).write(to: chromium.appendingPathComponent("Local State"))

        let sessionJSON = """
        {"profiles":{"default":{"id":"default","name":"SSV"},"p-mwyp8kdos1f6-16":{"id":"p-mwyp8kdos1f6-16","name":"AptusFit"}}}
        """
        try Data(sessionJSON.utf8).write(to: root.appendingPathComponent("session.json"))

        let profiles = ChromiumProfiles.list(base: chromium)
        #expect(profiles.map(\.directory) == ["Default", "Profile p-mwyp8kdos1f6-16"])
        #expect(profiles.map(\.displayName) == ["SSV", "AptusFit"])
    }

    @Test func searchSourceCustomChromiumIdentityAndShortName() {
        let spec = ChromiumBrowserSpec(
            appName: "Ardia",
            bundleIdentifier: "com.ardia.browser",
            supportDirectory: "~/Library/Application Support/com.ardia.browser/Chromium"
        )
        let source = SearchSource.customChromium(spec)
        #expect(source.rawValue == "chromium:com.ardia.browser")
        #expect(source.displayName == "Ardia")
        #expect(source.shortName == "Ardia")
        #expect(source.bundleIdentifier == "com.ardia.browser")
    }
}
