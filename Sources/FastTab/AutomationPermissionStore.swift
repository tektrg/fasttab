import Foundation
import AppKit
import Combine
import os

/// Whether macOS lets FastTab send Apple Events to one source app
/// (Privacy & Security > Automation). One status model for every source, so
/// a denied Chrome/Edge/Brave/Finder is as visible as a denied Safari.
enum AutomationPermissionStatus: String, Sendable {
    case granted
    case denied
    /// macOS hasn't shown its prompt yet; the first script (or `requestAccess`) will.
    case notYetAsked
    /// macOS can only answer while the target app is running.
    case appNotRunning
    case unknown

    /// errAEEventWouldRequireUserConsent — not exported to Swift.
    static let wouldRequireConsentCode: OSStatus = -1744
    /// procNotFound — the target app isn't running.
    static let targetNotRunningCode: OSStatus = -600

    /// Maps an `AEDeterminePermissionToAutomateTarget` result to a status.
    init(appleEventResult: OSStatus) {
        switch appleEventResult {
        case OSStatus(noErr): self = .granted
        case OSStatus(errAEEventNotPermitted): self = .denied
        case Self.wouldRequireConsentCode: self = .notYetAsked
        case Self.targetNotRunningCode: self = .appNotRunning
        default: self = .unknown
        }
    }

    var displayText: String {
        switch self {
        case .granted: return "Allowed"
        case .denied: return "Denied"
        case .notYetAsked: return "Not yet asked"
        case .appNotRunning: return "Open the app to check"
        case .unknown: return "Unknown"
        }
    }
}

/// Automation permission status for every enabled + installed source.
///
/// `recheck()` never prompts (safe on focus/bar-open). `requestAccess(for:)`
/// does prompt — it's the hook for onboarding's "Connect" button.
@MainActor
final class AutomationPermissionStore: ObservableObject {
    static let shared = AutomationPermissionStore()

    static let automationSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!

    @Published private(set) var statuses: [SearchSource: AutomationPermissionStatus] = [:]
    /// Source whose system prompt is on screen; at most one at a time.
    @Published private(set) var requestInFlight: SearchSource?
    /// Browsers (by `appName`) whose extension is connected on a compatible protocol.
    @Published private(set) var extensionConnectedAppNames: Set<String> = []
    /// Browsers whose extension is connected on an incompatible protocol.
    @Published private(set) var extensionMismatchedAppNames: Set<String> = []
    /// Live mirror of `ExtensionBetaPreference` (Settings > Advanced toggle), so
    /// anything derived from it re-renders when the user flips it.
    @Published private(set) var isExtensionFeatureEnabled: Bool = ExtensionBetaPreference.isEnabled

    private let sourceSelection: SourceSelectionStore
    private let logger = Logger(subsystem: "com.trungluong.FastTab", category: "AutomationPermission")
    private var recheckTask: Task<Void, Never>?
    /// Bumped by each answered `requestAccess`, so a recheck that started
    /// earlier can't overwrite the fresher answer with a stale probe.
    private var requestGeneration = 0
    private var answeredGeneration: [SearchSource: Int] = [:]
    private var extensionStatusSubscription: AnyCancellable?
    private var extensionPreferenceSubscription: AnyCancellable?

    init(sourceSelection: SourceSelectionStore = .shared, extensionBridge: ExtensionBridge = .shared) {
        self.sourceSelection = sourceSelection
        // Bridge publishes `status` on main; mirroring it here re-renders the banner on (dis)connect.
        extensionStatusSubscription = extensionBridge.$status
            .sink { [weak self] statuses in
                let connected = statuses.filter(\.isConnected)
                let compatible = Set(connected.filter { !$0.versionMismatch }.map(\.appName))
                let mismatched = Set(connected.filter(\.versionMismatch).map(\.appName))
                guard let self else { return }
                if self.extensionConnectedAppNames != compatible { self.extensionConnectedAppNames = compatible }
                if self.extensionMismatchedAppNames != mismatched { self.extensionMismatchedAppNames = mismatched }
            }
        // The Settings toggle writes through @AppStorage; follow it without polling.
        extensionPreferenceSubscription = NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .map { _ in ExtensionBetaPreference.isEnabled }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self, self.isExtensionFeatureEnabled != enabled else { return }
                self.isExtensionFeatureEnabled = enabled
            }
    }

    /// Setup progress for onboarding / Settings: tells "not connected" apart
    /// from "connected but turned off" and "connected on a stale version".
    var extensionSetupState: ExtensionSetupState {
        ExtensionSetupState.resolve(
            extensionEnabled: isExtensionFeatureEnabled,
            compatibleAppNames: extensionConnectedAppNames,
            mismatchedAppNames: extensionMismatchedAppNames
        )
    }

    /// Switches the extension setting on (same effect as the Settings toggle).
    func turnOnExtensionFeature() {
        ExtensionBetaPreference.setEnabled(true)
        isExtensionFeatureEnabled = true
    }

    /// Enabled, installed sources in stable display order — the ones worth a status.
    var trackedSources: [SearchSource] {
        SearchSource.allCases.filter { sourceSelection.isEnabled($0) && $0.isInstalled }
    }

    /// Enabled sources the user has explicitly blocked — what the bar banner shows.
    var deniedSources: [SearchSource] {
        Self.deniedSources(
            tracked: trackedSources,
            statuses: statuses,
            extensionEnabled: isExtensionFeatureEnabled,
            extensionConnectedAppNames: extensionConnectedAppNames
        )
    }

    /// Browsers (by `appName`) whose tabs actually come through the extension:
    /// connected, compatible, and the extension feature switched on.
    var usableExtensionAppNames: Set<String> {
        Self.usableExtensionAppNames(
            extensionEnabled: isExtensionFeatureEnabled,
            connectedAppNames: extensionConnectedAppNames
        )
    }

    /// The one definition of "extension usable for browser X".
    nonisolated static func usableExtensionAppNames(
        extensionEnabled: Bool,
        connectedAppNames: Set<String>
    ) -> Set<String> {
        extensionEnabled ? connectedAppNames : []
    }

    /// Denied sources, minus Chromium browsers whose tabs arrive through the
    /// connected extension instead of Automation (matched per browser).
    nonisolated static func deniedSources(
        tracked: [SearchSource],
        statuses: [SearchSource: AutomationPermissionStatus],
        extensionEnabled: Bool,
        extensionConnectedAppNames: Set<String>
    ) -> [SearchSource] {
        let usable = usableExtensionAppNames(extensionEnabled: extensionEnabled, connectedAppNames: extensionConnectedAppNames)
        return tracked.filter { source in
            guard statuses[source] == .denied else { return false }
            guard let spec = ChromiumBrowserSpec.all.first(where: { $0.source == source }) else { return true }
            return !usable.contains(spec.appName)
        }
    }

    /// Re-probes every tracked source off the main thread. Never shows a prompt.
    func recheck() {
        let sources = trackedSources
        let startGeneration = requestGeneration
        recheckTask?.cancel()
        recheckTask = Task { [weak self] in
            var fresh: [SearchSource: AutomationPermissionStatus] = [:]
            for source in sources {
                fresh[source] = await Self.probe(source, askUserIfNeeded: false)
            }
            guard !Task.isCancelled, let self else { return }
            // Keep answers the user gave after this probe started.
            for (source, generation) in self.answeredGeneration where generation > startGeneration {
                fresh[source] = self.statuses[source]
            }
            self.statuses = fresh
            let summary = fresh.map { "\($0.key.rawValue)=\($0.value.rawValue)" }.sorted().joined(separator: ",")
            self.logger.info("automation recheck: \(summary, privacy: .public)")
        }
    }

    /// Asks macOS for Automation access to `source`, showing the system prompt
    /// if it hasn't been answered yet. Launches the app hidden first when it
    /// isn't running (macOS can't prompt for a non-running target). A prior
    /// denial can't be re-prompted — callers should then offer
    /// `openAutomationSettings()`. Ignored while another request is in flight.
    @discardableResult
    func requestAccess(for source: SearchSource) async -> AutomationPermissionStatus? {
        guard requestInFlight == nil else { return nil }
        requestInFlight = source
        defer { requestInFlight = nil }
        if !Self.isRunning(source) {
            await Self.launchHidden(source)
        }
        let status = await Self.promptForPermission(source)
        statuses[source] = status
        requestGeneration += 1
        answeredGeneration[source] = requestGeneration
        logger.info("automation request \(source.rawValue, privacy: .public) -> \(status.rawValue, privacy: .public)")
        return status
    }

    func openAutomationSettings() {
        NSWorkspace.shared.open(Self.automationSettingsURL)
    }

    // MARK: - Probing

    /// Non-prompting check; returns promptly, so a detached task is fine.
    private nonisolated static func probe(_ source: SearchSource, askUserIfNeeded: Bool) async -> AutomationPermissionStatus {
        let bundleID = source.bundleIdentifier
        return await Task.detached(priority: .utility) {
            AutomationPermissionStatus(appleEventResult: determinePermission(bundleID: bundleID, askUserIfNeeded: askUserIfNeeded))
        }.value
    }

    /// The prompting check blocks until the user answers, so it runs on its own
    /// thread rather than parking a Swift-concurrency pool thread.
    private nonisolated static let promptQueue = DispatchQueue(label: "com.trungluong.FastTab.automation-prompt", qos: .userInitiated)

    private nonisolated static func promptForPermission(_ source: SearchSource) async -> AutomationPermissionStatus {
        let bundleID = source.bundleIdentifier
        return await withCheckedContinuation { continuation in
            promptQueue.async {
                continuation.resume(returning: AutomationPermissionStatus(
                    appleEventResult: determinePermission(bundleID: bundleID, askUserIfNeeded: true)
                ))
            }
        }
    }

    private nonisolated static func determinePermission(bundleID: String, askUserIfNeeded: Bool) -> OSStatus {
        var addressDesc = AEAddressDesc()
        let createStatus: OSErr = bundleID.withCString { cstr in
            AECreateDesc(DescType(typeApplicationBundleID), cstr, Int(strlen(cstr)), &addressDesc)
        }
        guard createStatus == noErr else { return OSStatus(createStatus) }
        defer { AEDisposeDesc(&addressDesc) }
        return AEDeterminePermissionToAutomateTarget(&addressDesc, typeWildCard, typeWildCard, askUserIfNeeded)
    }

    private static func isRunning(_ source: SearchSource) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: source.bundleIdentifier).isEmpty
    }

    private static let launchWaitAttempts = 20
    private static let launchPollInterval: Duration = .milliseconds(250)

    /// Opens the app without stealing focus, then waits (≤5s) for it to register.
    private static func launchHidden(_ source: SearchSource) async {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.bundleIdentifier) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        _ = try? await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        var attempts = 0
        while !isRunning(source), attempts < launchWaitAttempts {
            try? await Task.sleep(for: launchPollInterval)
            attempts += 1
        }
    }
}
