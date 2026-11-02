import Foundation
import Testing

/// Regression: Settings > Highlights crashed the deployed Mac app (SIGTRAP in `Bundle.module`).
/// SwiftPM puts a dependency's resources in `<Package>_<Target>.bundle` next to the binary; the
/// build scripts copy only the executable into `FastTab.app`, so `IndieLibKit_IndieTable.bundle`
/// (holding `table-core.js`) was missing. It only worked on the build Mac, where SwiftPM's lookup
/// falls back to the build folder.
struct AppResourceBundleTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Where SwiftPM left this test run's resource bundles (`swift test` is a debug build).
    private static var productsDir: URL { repoRoot.appendingPathComponent(".build/debug") }

    private func run(_ script: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [Self.repoRoot.appendingPathComponent(script).path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @Test func installerPutsTableCoreInsideTheApp() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("fasttab-test-\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: app) }
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)

        let result = try run("scripts/install-resource-bundles.sh", [Self.productsDir.path, app.path])
        #expect(result.status == 0, "\(result.output)")

        // This is the path SwiftPM's generated `Bundle.module` searches inside an app (`Bundle.main.resourceURL`).
        let tableCore = app.appendingPathComponent("Contents/Resources/IndieLibKit_IndieTable.bundle")
        let bundle = Bundle(url: tableCore)
        #expect(bundle?.url(forResource: "table-core", withExtension: "js") != nil)
    }

    /// Only runtime bundles ship: a stray `*Tests.bundle` (test fixtures SwiftPM leaves in the same
    /// folder) or an unknown bundle must stay out of the app.
    @Test func installerShipsOnlyRuntimeBundles() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("fasttab-allow-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin")
        let app = root.appendingPathComponent("X.app")
        try fm.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.copyItem(at: Self.productsDir.appendingPathComponent("IndieLibKit_IndieTable.bundle"),
                        to: bin.appendingPathComponent("IndieLibKit_IndieTable.bundle"))
        for name in ["GRDB_GRDB.bundle", "FastTabPackage_AgentBarTests.bundle", "IndieLibKit_IndieTableTests.bundle", "Some_Unused.bundle"] {
            try fm.createDirectory(at: bin.appendingPathComponent(name), withIntermediateDirectories: true)
        }

        // The build refreshes an existing app in place, so a bundle shipped by an older build lingers.
        try fm.createDirectory(at: app.appendingPathComponent("Contents/Resources/FastTabPackage_AgentBarTests.bundle"),
                               withIntermediateDirectories: true)

        let result = try run("scripts/install-resource-bundles.sh", [bin.path, app.path])
        #expect(result.status == 0, "\(result.output)")

        let shipped = try fm.contentsOfDirectory(atPath: app.appendingPathComponent("Contents/Resources").path).sorted()
        #expect(shipped == ["GRDB_GRDB.bundle", "IndieLibKit_IndieTable.bundle"], "shipped: \(shipped)")
        #expect(!shipped.contains { $0.hasSuffix("Tests.bundle") })
    }

    @Test func installerFailsLoudlyWhenAnExpectedBundleIsMissing() throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("fasttab-empty-\(UUID().uuidString)")
        let app = empty.appendingPathComponent("X.app")
        defer { try? FileManager.default.removeItem(at: empty) }
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)

        let result = try run("scripts/install-resource-bundles.sh", [empty.path, app.path])
        #expect(result.status != 0)
        #expect(result.output.contains("IndieLibKit_IndieTable.bundle"))
    }

    @Test func everyAppBuildScriptInstallsResourceBundles() throws {
        for script in ["scripts/fasttab-build-mac-app.sh", "scripts/distribute.sh"] {
            let text = try String(contentsOf: Self.repoRoot.appendingPathComponent(script), encoding: .utf8)
            #expect(text.contains("install-resource-bundles.sh"), "\(script) must install SwiftPM resource bundles into the app")
        }
    }
}
