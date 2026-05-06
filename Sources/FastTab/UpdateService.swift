import Foundation
import SwiftUI
import OSLog
import Sparkle

@MainActor
final class UpdateService: NSObject, ObservableObject, SPUUserDriver {
    static let shared = UpdateService()

    @Published var status: UpdateStatus = .idle

    enum UpdateStatus: Equatable {
        case idle
        case checking
        case available(version: String, releaseNotes: String?)
        case downloading(progress: Double)
        case extracting(progress: Double)
        case installing
        case readyToRestart(version: String)
        case upToDate
        case error(String)
    }

    private let logger = Logger(subsystem: "com.trungluong.FastTab", category: "UpdateService")

    private var updater: SPUUpdater?

    // Replies stored from Sparkle delegate callbacks. Invoked when the user
    // taps the banner button to drive the next step.
    private var updateFoundReply: ((SPUUserUpdateChoice) -> Void)?
    private var readyToRelaunchReply: ((SPUUserUpdateChoice) -> Void)?
    private var checkCancellation: (() -> Void)?
    private var downloadCancellation: (() -> Void)?

    // Track download progress.
    private var expectedContentLength: UInt64 = 0
    private var receivedContentLength: UInt64 = 0

    // Latest appcast item info, kept so we can label states with version/notes.
    private var pendingVersion: String?
    private var pendingReleaseNotes: String?
    private var manualCheckInFlight = false

    override init() {
        super.init()
        let updater = SPUUpdater(
            hostBundle: Bundle.main,
            applicationBundle: Bundle.main,
            userDriver: self,
            delegate: nil
        )
        do {
            try updater.start()
            self.updater = updater
            logger.info("Sparkle updater started")
        } catch {
            logger.error("Sparkle updater failed to start: \(error.localizedDescription, privacy: .public)")
            status = .error("Update service unavailable")
        }
    }

    // MARK: - Public API

    func checkForUpdates(manual: Bool = false) {
        guard let updater else { return }
        manualCheckInFlight = manual
        if manual {
            updater.checkForUpdates()
        } else {
            updater.checkForUpdatesInBackground()
        }
    }

    /// Banner primary action — interpretation depends on current status.
    func performPrimaryAction() {
        switch status {
        case .available:
            if let reply = updateFoundReply {
                updateFoundReply = nil
                reply(.install)
            }
        case .readyToRestart:
            if let reply = readyToRelaunchReply {
                readyToRelaunchReply = nil
                reply(.install)
            }
        case .idle, .upToDate, .error:
            checkForUpdates(manual: true)
        case .checking, .downloading, .extracting, .installing:
            break
        }
    }

    func dismiss() {
        if let reply = updateFoundReply {
            updateFoundReply = nil
            reply(.dismiss)
        }
        if let reply = readyToRelaunchReply {
            readyToRelaunchReply = nil
            reply(.dismiss)
        }
        if let cancel = downloadCancellation {
            downloadCancellation = nil
            cancel()
        }
        if let cancel = checkCancellation {
            checkCancellation = nil
            cancel()
        }
        status = .idle
    }

    // MARK: - SPUUserDriver

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Send anonymous system profile data: no. Auto-check for updates: yes.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        checkCancellation = cancellation
        status = .checking
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        pendingVersion = appcastItem.displayVersionString
        let notes: String?
        if let body = appcastItem.itemDescription, !body.isEmpty {
            notes = stripHTML(body)
        } else {
            notes = nil
        }
        pendingReleaseNotes = notes
        updateFoundReply = reply
        status = .available(version: appcastItem.displayVersionString, releaseNotes: notes)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // No-op — using inline description from appcast.
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        logger.error("Release notes download failed: \(error.localizedDescription, privacy: .public)")
    }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        logger.info("No update found")
        status = manualCheckInFlight ? .upToDate : .idle
        manualCheckInFlight = false
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        logger.error("Updater error: \(error.localizedDescription, privacy: .public)")
        status = .error(error.localizedDescription)
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        downloadCancellation = cancellation
        expectedContentLength = 0
        receivedContentLength = 0
        status = .downloading(progress: 0)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        self.expectedContentLength = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedContentLength &+= length
        let progress: Double
        if expectedContentLength > 0 {
            progress = min(1.0, Double(receivedContentLength) / Double(expectedContentLength))
        } else {
            progress = 0
        }
        status = .downloading(progress: progress)
    }

    func showDownloadDidStartExtractingUpdate() {
        downloadCancellation = nil
        status = .extracting(progress: 0)
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        status = .extracting(progress: progress)
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        readyToRelaunchReply = reply
        let version = pendingVersion ?? ""
        status = .readyToRestart(version: version)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        status = .installing
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func showUpdateInFocus() {
        // No dedicated update window; banner suffices.
    }

    func dismissUpdateInstallation() {
        updateFoundReply = nil
        readyToRelaunchReply = nil
        downloadCancellation = nil
        checkCancellation = nil
        if case .readyToRestart = status { return }
        if case .installing = status { return }
        status = .idle
    }

    // MARK: - Helpers

    private func stripHTML(_ html: String) -> String {
        guard let data = html.data(using: .utf8) else { return html }
        let opts: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        if let attr = try? NSAttributedString(data: data, options: opts, documentAttributes: nil) {
            return attr.string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return html
    }
}
