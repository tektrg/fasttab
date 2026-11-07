import AppKit
import AuthenticationServices
import FastTabReader
import FastTabSync
import FastTabWebReader
import Foundation
import IndieAccount
import Network
import IndieSharing
import os

/// Experimental **Web Reader** (fasttab.theindie.app/web): while on, this Mac uploads an
/// end-to-end-encrypted snapshot of its tabs, bookmarks, FastTab List and reader articles for
/// the user's paired browsers, and imports the highlights/progress they send back.
/// Off by default; turning it off stops uploads and deletes everything on the server.
/// Contract: `memory/Projects/fasttab-web-reader/contract.md`.
@MainActor
final class WebReaderController: NSObject, ObservableObject {
    static let shared = WebReaderController()

    /// Settings > Experimental toggle (`@AppStorage` in the view reads the same key).
    static let enabledDefaultsKey = "FastTab.experimental.webReader"
    static let uploadDebounce: Duration = .seconds(30)
    static let pollInterval: Duration = .seconds(180)

    /// Portfolio account wiring for Fast Tab. Keep `keychainService` stable once shipped.
    /// TODO(owner): theindie-api APPS entry uses placeholder bundle id `app.theindie.FastTab`
    /// (matches the current Mac bundle id; confirm before production).
    static let accountConfiguration = IndieAccountConfiguration(
        appSlug: "fasttab",
        keychainService: "app.theindie.FastTab.account",
        developmentServerURLDefaultsKey: "FastTab.accountServerURL",
        developmentServerURLInfoPlistKey: "TheIndieDevServerURL"
    )

    @Published private(set) var isEnabled = UserDefaults.standard.bool(forKey: WebReaderController.enabledDefaultsKey)
    @Published private(set) var pairedBrowsers: [WebReaderDevice] = []
    @Published private(set) var status: String = ""
    @Published private(set) var lastUploadAt: Date?
    @Published var errorMessage: String?

    private(set) lazy var account: AccountSession = AccountSession.live(
        configuration: Self.accountConfiguration, deviceName: Host.current().localizedName)

    private let logger = Logger(subsystem: "com.trungluong.FastTab", category: "WebReader")
    private var latestTabs: [BrowserSearchResult] = []
    private var latestBookmarks: [BrowserSearchResult] = []
    private var uploadTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    private var lastRecipientIDs: Set<String> = []
    private var signInNonce: String?
    private let cleanup = WebReaderCleanup()
    private var cleanupTask: Task<Void, Never>?
    private var cleanupObserver: NSObjectProtocol?
    private var pathMonitor: NWPathMonitor?

    private lazy var api: any WebReaderAPI = LiveWebReaderAPI(
        baseURL: TheIndieServerConfiguration.baseURL(configuration: Self.accountConfiguration),
        token: { [keychainService = Self.accountConfiguration.keychainService] in
            SessionTokenStore(keychain: KeychainStore(service: keychainService)).token()
        })

    private lazy var uploader = WebSnapshotUploader(
        api: api, ledgerURL: SyncService.shared.fastTabSupportDirectory
            .appendingPathComponent("WebReader", isDirectory: true).appendingPathComponent("upload_ledger.json"))

    var isSignedIn: Bool { account.profile != nil }

    // MARK: - Lifecycle

    /// At launch: nothing happens unless the toggle is on.
    func start() {
        retryCleanupIfPending()
        guard isEnabled else { return }
        Task { await activate() }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledDefaultsKey)
        if enabled {
            cleanup.cancel() // back on: keep the server copy, nothing to delete
            stopCleanupRetries()
            Task { await activate() }
        } else {
            deactivate()
        }
    }

    private func activate() async {
        await account.restoreIfNeeded()
        guard isEnabled, isSignedIn else { status = "Sign in to pair a browser."; return }
        await refreshPairedBrowsers()
        startPolling()
        scheduleUpload(immediately: true)
    }

    private func deactivate() {
        uploadTask?.cancel()
        pollTask?.cancel()
        uploadTask = nil
        pollTask = nil
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
        status = "Off"
        cleanup.markPending() // persisted first: retried until the server is clean
        retryCleanupIfPending()
    }

    // MARK: - Toggle-off server cleanup (final poll → unpair browsers → delete snapshot)

    /// Called at launch, after sign-in, on app activate and when the network comes back.
    func retryCleanupIfPending() {
        guard cleanup.isPending else { stopCleanupRetries(); return }
        installCleanupTriggers()
        guard cleanupTask == nil else { return }
        cleanupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.cleanupTask = nil }
            await self.account.restoreIfNeeded()
            guard self.isSignedIn else { self.status = "Off. Sign in to delete the web copy."; return }
            let ok = await self.cleanup.runIfPending(api: self.api) { try await self.drainInbox() }
            if ok, !self.isEnabled {
                self.uploader.reset()
                self.pairedBrowsers = []
                self.status = "Off. Server copy deleted, browsers unpaired."
                self.stopCleanupRetries()
            } else if !ok, self.cleanup.isPending {
                self.status = "Off. Will delete the web copy when online."
            }
        }
    }

    private func installCleanupTriggers() {
        if cleanupObserver == nil {
            cleanupObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.retryCleanupIfPending() }
            }
        }
        if pathMonitor == nil {
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                guard path.status == .satisfied else { return }
                Task { @MainActor in self?.retryCleanupIfPending() }
            }
            monitor.start(queue: .global(qos: .utility))
            pathMonitor = monitor
        }
    }

    private func stopCleanupRetries() {
        if let cleanupObserver { NotificationCenter.default.removeObserver(cleanupObserver) }
        cleanupObserver = nil
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    // MARK: - Inputs (fed by SyncService)

    func noteTabs(_ tabs: [BrowserSearchResult]) {
        latestTabs = tabs.filter { $0.type == .tab }
        scheduleUpload()
    }

    func noteBookmarks(_ bookmarks: [BrowserSearchResult]) {
        latestBookmarks = bookmarks.filter { $0.type == .bookmark }
        scheduleUpload()
    }

    /// Debounced (~30 s): bursts of tab changes become one upload.
    func scheduleUpload(immediately: Bool = false) {
        guard isEnabled, isSignedIn else { return }
        uploadTask?.cancel()
        uploadTask = Task { @MainActor [weak self] in
            if !immediately { try? await Task.sleep(for: Self.uploadDebounce) }
            guard !Task.isCancelled, let self else { return }
            await self.uploadNow()
        }
    }

    private func uploadNow() async {
        do {
            let devices = try await api.devices()
            let browsers = devices.filter { $0.isWebBrowser && $0.app == "fasttab" }
            pairedBrowsers = browsers
            let recipients = browsers.compactMap { device -> WebReaderCrypto.Recipient? in
                (try? DevicePublicKey(base64URL: device.publicKey)).map { .init(deviceID: device.id, publicKey: $0) }
            }
            let ids = Set(recipients.map(\.deviceID))
            if ids != lastRecipientIDs { uploader.forgetUploadedArticles() }
            lastRecipientIDs = ids
            let build = WebSnapshotBuilder.build(makeInput())
            if let result = try await uploader.upload(build, to: recipients) {
                lastUploadAt = Date()
                status = "Uploaded v\(result.version) (\(build.snapshot.articles.count) articles)."
            } else {
                status = "No browser paired yet."
            }
        } catch {
            logger.error("Web snapshot upload failed: \(String(describing: error), privacy: .public)")
            status = "Upload failed: \(error)"
        }
    }

    private func makeInput() -> WebSnapshotInput {
        let listItems = FastTabListStore.shared.items
        let cache = MacReaderArticleCache(directory: MacReaderArticleCache.defaultDirectory)
        var urls = listItems.map(\.url)
        urls += latestTabs.map(\.url)
        var seen = Set<String>()
        let articles = urls.filter { seen.insert(FastTabListLibrary.itemID(for: $0)).inserted }.compactMap { url in
            cache.article(forURL: url).map {
                WebSnapshotInput.Article(url: $0.url.absoluteString, title: $0.title, byline: $0.byline,
                                         html: $0.content, extractedAt: $0.extractedAt)
            }
        }
        return WebSnapshotInput(
            macName: Host.current().localizedName ?? "Mac",
            tabs: latestTabs.map {
                .init(browserName: $0.browserName, profileName: $0.profileName, windowIndex: $0.windowIndex,
                      tabIndex: $0.tabIndex, tabID: $0.tabID, url: $0.url, title: $0.title, lastActiveAt: $0.timestamp)
            },
            bookmarks: latestBookmarks.map {
                .init(id: $0.bookmarkID ?? $0.url, browserName: $0.browserName, profileName: $0.profileName,
                      folderPath: $0.folderPath, title: $0.title, url: $0.url)
            },
            listItems: listItems,
            articles: articles)
    }

    // MARK: - Inbox (highlights + progress from the browser)

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.pollInbox()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
        if activationObserver == nil {
            activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in await self?.pollInbox() }
            }
        }
    }

    func pollInbox() async {
        guard isEnabled else { return }
        do {
            try await drainInbox()
        } catch {
            logger.error("Web inbox poll failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Imports + acks the whole inbox. Throws when it could not be drained (cleanup then waits).
    private func drainInbox() async throws {
        guard let identity = account.registeredDeviceIdentity, let deviceID = identity.deviceID,
              let keyPair = try? DeviceKeyPair(privateKeyRawRepresentation: identity.privateKey) else { return }
        let summary = try await WebInboxImporter.run(
            api: api, deviceID: deviceID.uuidString.lowercased(), keyPair: keyPair, sink: self)
        if summary.highlights > 0 {
            SyncService.shared.queueReaderChanges()
            NotificationCenter.default.post(name: .readerMirrorDidChange, object: nil)
        }
    }

    // MARK: - Pairing

    /// Accepts the browser's `fasttab://pair-web?id=…&code=…` link (QR / copy), or a pairing id
    /// and the 8-character code it shows.
    func approvePairing(linkOrID: String, code: String) async {
        errorMessage = nil
        var pairingID = linkOrID.trimmingCharacters(in: .whitespacesAndNewlines)
        var pairingCode = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if let components = URLComponents(string: pairingID), components.scheme == "fasttab" {
            pairingID = components.queryItems?.first { $0.name == "id" }?.value ?? ""
            if pairingCode.isEmpty { pairingCode = components.queryItems?.first { $0.name == "code" }?.value ?? "" }
        }
        guard !pairingID.isEmpty, pairingCode.count == 8 else {
            errorMessage = "Paste the pairing link (or id) and the 8-character code shown in the browser."
            return
        }
        do {
            try await api.approvePairing(id: pairingID, code: pairingCode)
            await refreshPairedBrowsers()
            scheduleUpload(immediately: true)
        } catch {
            errorMessage = "Pairing failed: \(error)"
        }
    }

    func refreshPairedBrowsers() async {
        guard isSignedIn else { return }
        pairedBrowsers = (try? await api.devices())?.filter { $0.isWebBrowser && $0.app == "fasttab" } ?? pairedBrowsers
    }

    func unpair(_ device: WebReaderDevice) async {
        do {
            try await api.removeDevice(id: device.id)
            await refreshPairedBrowsers()
            scheduleUpload(immediately: true)
        } catch {
            errorMessage = "Unpair failed: \(error)"
        }
    }

    // MARK: - Sign in with Apple (only when the toggle is on)

    func signIn() {
        let nonce = SignInNonce.makeRawNonce()
        signInNonce = nonce
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName]
        request.nonce = SignInNonce.sha256Hex(nonce)
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.performRequests()
    }

    func signOut() async {
        await account.signOut()
        objectWillChange.send()
    }
}

extension WebReaderController: ASAuthorizationControllerDelegate {
    nonisolated func authorizationController(controller: ASAuthorizationController,
                                             didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken else { return }
        let identityToken = String(decoding: tokenData, as: UTF8.self)
        let code = credential.authorizationCode.map { String(decoding: $0, as: UTF8.self) }
        let fullName = credential.fullName
        Task { @MainActor in
            guard let nonce = self.signInNonce else { return }
            let ok = await self.account.signIn(identityToken: identityToken, authorizationCode: code,
                                               rawNonce: nonce, fullName: fullName)
            self.objectWillChange.send()
            if ok { self.retryCleanupIfPending(); await self.activate() } else { self.errorMessage = "Sign in failed." }
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: any Error) {
        let message = error.localizedDescription
        Task { @MainActor in self.errorMessage = "Sign in with Apple failed: \(message)" }
    }
}

extension WebReaderController: WebInboxSink {
    func importHighlight(_ highlight: SyncedReaderHighlight) -> Bool {
        guard let mirror = SyncService.shared.readerSync.highlights as? ReaderMirror else { return false }
        mirror.addOwn(highlight)
        return true
    }

    func applyProgress(url: String, fraction: Double, updatedAt: Date) {
        guard let item = FastTabListStore.shared.items.first(where: {
            FastTabListLibrary.itemID(for: $0.url) == FastTabListLibrary.itemID(for: url)
        }), (item.progressUpdatedAt ?? .distantPast) < updatedAt else { return }
        FastTabListStore.shared.recordReaderProgress(url: item.url, progress: fraction)
    }
}
