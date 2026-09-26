import Foundation
import AppKit
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

    private let sourceSelection: SourceSelectionStore
    private let logger = Logger(subsystem: "com.trungluong.FastTab", category: "AutomationPermission")
    private var recheckTask: Task<Void, Never>?

    init(sourceSelection: SourceSelectionStore = .shared) {
        self.sourceSelection = sourceSelection
    }

    /// Enabled, installed sources in stable display order — the ones worth a status.
    var trackedSources: [SearchSource] {
        SearchSource.allCases.filter { sourceSelection.isEnabled($0) && $0.isInstalled }
    }

    /// Enabled sources the user has explicitly blocked — what the bar banner shows.
    var deniedSources: [SearchSource] {
        trackedSources.filter { statuses[$0] == .denied }
    }

    /// Re-probes every tracked source off the main thread. Never shows a prompt.
    func recheck() {
        let sources = trackedSources
        recheckTask?.cancel()
        recheckTask = Task { [weak self] in
            var fresh: [SearchSource: AutomationPermissionStatus] = [:]
            for source in sources {
                fresh[source] = await Self.probe(source, askUserIfNeeded: false)
            }
            guard !Task.isCancelled, let self else { return }
            self.statuses = fresh
            let summary = fresh.map { "\($0.key.rawValue)=\($0.value.rawValue)" }.sorted().joined(separator: ",")
            self.logger.info("automation recheck: \(summary, privacy: .public)")
        }
    }

    /// Asks macOS for Automation access to `source`, showing the system prompt
    /// if it hasn't been answered yet. Launches the app hidden first when it
    /// isn't running (macOS can't prompt for a non-running target). A prior
    /// denial can't be re-prompted — callers should then offer
    /// `openAutomationSettings()`.
    @discardableResult
    func requestAccess(for source: SearchSource) async -> AutomationPermissionStatus {
        if !Self.isRunning(source) {
            await Self.launchHidden(source)
        }
        let status = await Self.probe(source, askUserIfNeeded: true)
        statuses[source] = status
        logger.info("automation request \(source.rawValue, privacy: .public) -> \(status.rawValue, privacy: .public)")
        return status
    }

    func openAutomationSettings() {
        NSWorkspace.shared.open(Self.automationSettingsURL)
    }

    // MARK: - Probing

    /// Runs on a background thread: with `askUserIfNeeded` the call blocks
    /// until the user answers the system prompt.
    private nonisolated static func probe(_ source: SearchSource, askUserIfNeeded: Bool) async -> AutomationPermissionStatus {
        let bundleID = source.bundleIdentifier
        return await Task.detached(priority: .utility) {
            AutomationPermissionStatus(appleEventResult: determinePermission(bundleID: bundleID, askUserIfNeeded: askUserIfNeeded))
        }.value
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
