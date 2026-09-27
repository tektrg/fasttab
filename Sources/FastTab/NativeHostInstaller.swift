import Foundation
import OSLog

/// Stable identity shared by the app's native-messaging manifest and the
/// extension itself. The extension ID is derived from the public key pinned in
/// `extension/manifest.json` (`key`) — see that file. The private key is kept
/// OUT of the extension folder (so it never ships or gets loaded) at
/// `~/Library/Application Support/com.trungluong.FastTab/extension-key.pem`;
/// it's only needed for future self-signed CRX packaging. The Web Store and
/// `--load-unpacked` use the public key alone.
enum FastTabExtensionIdentity {
    /// Derived from the public key pinned in `extension/manifest.json` (`key`):
    /// SHA-256 of the DER public key, first 16 bytes, hex digits mapped 0-9a-f→a-p.
    static let id = "ilkkkeeabaikphnjoodhmmahiclaogbj"
    /// Chromium rejects uppercase in native-messaging host names with "Invalid
    /// native messaging host name specified" — this must stay lowercase. Matches
    /// `HOST_NAME` in `extension/background.js` and the manifest file name.
    static let nativeMessagingHostName = "com.trungluong.fasttab"
    /// Chrome Web Store listing — Edge and Brave install from it too.
    static let chromeWebStoreURL = URL(string: "https://chromewebstore.google.com/detail/\(id)")!
}

/// Writes/refreshes Chrome-family native-messaging host manifests so the
/// FastTab extension can spawn `FastTabNativeHost`.
///
/// Runs at every launch, idempotently: covers a browser installed later, an
/// app moved to a new path (the manifest pins an absolute host path), or a
/// manifest the user deleted. Presence is harmless when the beta is off —
/// behavior, not manifest presence, is gated by `ExtensionBetaPreference`.
final class NativeHostInstaller: Sendable {
    static let shared = NativeHostInstaller()

    private let logger = Logger(subsystem: "com.trungluong.FastTab", category: "NativeHostInstaller")

    private init() {}

    func installIfNeeded() {
        guard let hostPath = hostBinaryPath() else {
            logger.error("host binary path unresolved — skipping manifest install")
            return
        }
        for spec in ChromiumBrowserSpec.all {
            installManifest(for: spec, hostPath: hostPath)
        }
    }

    /// Absolute path to `FastTabNativeHost` inside this app bundle. The bundle
    /// is the source of truth so a relocated app rewrites the manifest to the
    /// new location on its next launch.
    private func hostBinaryPath() -> String? {
        guard let executableURL = Bundle.main.executableURL else { return nil }
        return executableURL
            .deletingLastPathComponent()
            .appendingPathComponent("FastTabNativeHost")
            .path
    }

    private func installManifest(for spec: ChromiumBrowserSpec, hostPath: String) {
        let directory = (spec.nativeMessagingHostsDirectory as NSString).expandingTildeInPath
        let fileURL = URL(fileURLWithPath: directory)
            .appendingPathComponent("\(FastTabExtensionIdentity.nativeMessagingHostName).json")

        guard let data = Self.manifestJSON(hostPath: hostPath) else {
            logger.error("manifest serialization failed for \(spec.appName, privacy: .public)")
            return
        }
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: fileURL, options: .atomic)
            logger.info("native host manifest installed for \(spec.appName, privacy: .public) at \(fileURL.path, privacy: .public)")
        } catch {
            logger.error("native host manifest install failed for \(spec.appName, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// The native-messaging manifest JSON. Exposed internally so the test
    /// target can verify its shape (name, type, pinned origin, absolute path)
    /// without writing to a real browser's support directory.
    static func manifestJSON(hostPath: String) -> Data? {
        let manifest: [String: Any] = [
            "name": FastTabExtensionIdentity.nativeMessagingHostName,
            "description": "FastTab companion native-messaging host",
            "path": hostPath,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(FastTabExtensionIdentity.id)/"]
        ]
        return try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    }
}
