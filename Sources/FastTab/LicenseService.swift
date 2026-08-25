import AppKit
import Foundation
import OSLog

@MainActor
final class LicenseService: ObservableObject {
    static let shared = LicenseService(
        configuration: .live,
        storage: KeychainLicenseStorage.shared,
        client: CustomerPortalPolarLicenseClient(apiBaseURL: PaymentConfiguration.live.apiBaseURL)
    )

    @Published private(set) var snapshot: EntitlementSnapshot = .starting
    @Published private(set) var isActivating = false

    private let configuration: PaymentConfiguration
    private let storage: LicenseStorage
    private let licenseMutations: OrderedLicenseMutationCoordinator
    private let client: PolarLicenseClient
    private let logger = Logger(subsystem: "com.trungluong.FastTab", category: "LicenseService")
    private let lastValidationVersionKey = "FastTab.license.lastValidationVersion"
    private let initialLoadTimeout: Duration
    private var pendingLaunchValidationVersion: String?
    private var launchValidationRequestedWhileLoading = false
    private var stateRevision: UInt = 0
    private var cachedStateLoadTask: Task<Void, Never>?
    private var cachedStateTimeoutTask: Task<Void, Never>?

    init(
        configuration: PaymentConfiguration,
        storage: LicenseStorage,
        client: PolarLicenseClient,
        initialLoadTimeout: Duration = .seconds(3)
    ) {
        self.configuration = configuration
        self.storage = storage
        self.licenseMutations = OrderedLicenseMutationCoordinator(storage: storage)
        self.client = client
        self.initialLoadTimeout = initialLoadTimeout
        refreshCachedState()
    }

    func refreshCachedState(now: Date = Date()) {
        cachedStateLoadTask?.cancel()
        cachedStateTimeoutTask?.cancel()
        let revision = beginStateOperation()

        cachedStateLoadTask = Task { [weak self] in
            await self?.loadCachedState(now: now, revision: revision)
        }
        let loadTimeout = initialLoadTimeout
        cachedStateTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: loadTimeout)
            } catch {
                return
            }
            guard let self, revision == self.stateRevision else { return }
            self.setStorageUnavailable(revision: revision)
        }
    }

    private func loadCachedState(now: Date, revision: UInt) async {
        do {
            var trial = try await storage.loadTrial()
            try Task.checkCancellation()
            let license = try await storage.loadLicense()
            try Task.checkCancellation()
            guard revision == stateRevision else { return }
            cachedStateTimeoutTask?.cancel()

            if trial == nil {
                trial = TrialRecord(startedAt: now)
                try await storage.saveTrial(trial!)
                try Task.checkCancellation()
            }

            guard revision == stateRevision else { return }
            if let license {
                let access = LicenseEntitlementPolicy.access(
                    for: license,
                    currentMajorVersion: configuration.currentMajorVersion
                )
                snapshot = EntitlementSnapshot(access: access, trial: trial, license: license, lastErrorMessage: nil)
                replayLatchedLaunchValidationIfNeeded()
                return
            }

            launchValidationRequestedWhileLoading = false
            snapshot = EntitlementSnapshot(
                access: TrialPolicy.access(for: trial!, now: now),
                trial: trial,
                license: nil,
                lastErrorMessage: nil
            )
        } catch {
            guard !(error is CancellationError), revision == stateRevision else { return }
            logger.error("Failed to refresh license state: \(error.localizedDescription, privacy: .public)")
            setStorageUnavailable(revision: revision)
        }
    }

    func refreshTimeSensitiveState(now: Date = Date()) {
        guard snapshot.license == nil, let trial = snapshot.trial else { return }
        let nextAccess = TrialPolicy.access(for: trial, now: now)
        guard nextAccess != snapshot.access else { return }
        _ = beginStateOperation()
        snapshot = EntitlementSnapshot(
            access: nextAccess,
            trial: trial,
            license: nil,
            lastErrorMessage: snapshot.lastErrorMessage
        )
    }

    func validateCachedLicenseIfNeeded(force: Bool = false, completion: ((Bool) -> Void)? = nil) {
        guard let license = snapshot.license else { return }
        guard configuration.canActivateLicenses else { return }
        guard force || Date().timeIntervalSince(license.lastValidatedAt) >= 7 * 24 * 60 * 60 else { return }

        Task {
            let succeeded = await revalidateCachedLicense(license)
            completion?(succeeded)
        }
    }

    func validateForLaunch() {
        guard snapshot != .starting else {
            launchValidationRequestedWhileLoading = true
            return
        }

        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let previousVersion = UserDefaults.standard.string(forKey: lastValidationVersionKey)
        let shouldForceValidation = !currentVersion.isEmpty && previousVersion != currentVersion

        if shouldForceValidation {
            pendingLaunchValidationVersion = currentVersion
            validateCachedLicenseIfNeeded(force: true) { [weak self] succeeded in
                guard succeeded, let self, self.pendingLaunchValidationVersion == currentVersion else { return }
                UserDefaults.standard.set(currentVersion, forKey: self.lastValidationVersionKey)
                self.pendingLaunchValidationVersion = nil
            }
        } else {
            validateCachedLicenseIfNeeded()
        }
    }

    private func replayLatchedLaunchValidationIfNeeded() {
        guard launchValidationRequestedWhileLoading else { return }
        launchValidationRequestedWhileLoading = false
        validateForLaunch()
    }

    func activateLicense(key rawKey: String) async {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            setError("Enter a license key.")
            return
        }
        guard configuration.canActivateLicenses else {
            setError("License activation is not configured in this build.")
            return
        }

        isActivating = true
        defer { isActivating = false }
        let revision = beginStateOperation()
        await licenseMutations.registerIntent(revision)

        do {
            let device = try await ensureDeviceIdentity()
            let conditions = licenseConditions
            let activation = try await client.activate(
                key: key,
                organizationID: configuration.organizationID,
                label: device.label,
                conditions: conditions,
                meta: ["install_id": device.installID]
            )
            let validated = try await client.validate(
                key: key,
                organizationID: configuration.organizationID,
                activationID: activation.id,
                conditions: conditions
            )
            let stored = try storedLicense(
                key: key,
                activationID: activation.id,
                activationLicenseKeyID: activation.licenseKeyID,
                licenseKey: validated,
                device: device,
                validatedAt: Date()
            )
            guard try await licenseMutations.save(stored, revision: revision) else { return }
            let trial = try await storage.loadTrial()
            guard revision == stateRevision else { return }
            snapshot = EntitlementSnapshot(
                access: LicenseEntitlementPolicy.access(
                    for: stored,
                    currentMajorVersion: configuration.currentMajorVersion
                ),
                trial: trial,
                license: stored,
                lastErrorMessage: nil
            )
        } catch {
            guard revision == stateRevision else { return }
            logger.error("License activation failed: \(error.localizedDescription, privacy: .public)")
            setError(error.localizedDescription)
        }
    }

    func clearLicense() {
        let revision = beginStateOperation()
        Task { [weak self] in
            guard let self else { return }
            do {
                await self.licenseMutations.registerIntent(revision)
                guard try await self.licenseMutations.delete(revision: revision) else { return }
                guard revision == self.stateRevision else { return }
                self.refreshCachedState()
            } catch {
                guard revision == self.stateRevision else { return }
                self.setError("Could not remove the saved license.")
            }
        }
    }

    /// Where the user clicked Buy, so the pricing page (and our analytics) can attribute
    /// conversion by surface. Stays out of the hot command-bar open/search path —
    /// only consulted when a click already happened.
    enum CheckoutSource: String {
        case trialBanner = "trial-banner"
        case expiredPaywall = "expired-paywall"
        case settings = "settings"
        case menuBar = "menu-bar"
    }

    /// Opens the pricing page where the user picks Personal / Lifetime / Team.
    /// The tier chooser intentionally lives on the website (single source of truth for price
    /// and launch-discount copy); see memory/Projects/monetization/payment-implementation-plan.md.
    func openCheckout(source: CheckoutSource? = nil) {
        guard let base = configuration.bestCheckoutURL else {
            setError("Checkout is not configured in this build.")
            return
        }

        let url: URL
        if let source,
           var components = URLComponents(url: base, resolvingAgainstBaseURL: false) {
            var items = components.queryItems ?? []
            items.append(URLQueryItem(name: "ref", value: source.rawValue))
            components.queryItems = items
            url = components.url ?? base
        } else {
            url = base
        }
        NSWorkspace.shared.open(url)
    }

    func openManageLicense() {
        guard let url = configuration.manageLicenseURL ?? configuration.supportURL else {
            setError("License management is not configured in this build.")
            return
        }
        NSWorkspace.shared.open(url)
    }

    func openSupport() {
        guard let url = configuration.supportURL else { return }
        NSWorkspace.shared.open(url)
    }

    func handleActivationURL(_ url: URL) {
        guard url.scheme == "fasttab", url.host == "activate" else { return }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let key = components.queryItems?.first(where: { $0.name == "key" })?.value,
              !key.isEmpty else {
            setError("Activation link did not include a license key.")
            return
        }

        Task {
            await activateLicense(key: key)
        }
    }

    private var licenseConditions: [String: Int] {
        ["major_version": configuration.currentMajorVersion]
    }

    private func ensureDeviceIdentity() async throws -> DeviceActivationIdentity {
        if let existing = try await storage.loadDeviceIdentity() {
            return existing
        }
        let identity = DeviceActivationIdentity.current()
        try await storage.saveDeviceIdentity(identity)
        return identity
    }

    private func revalidateCachedLicense(_ license: StoredLicense) async -> Bool {
        let revision = beginStateOperation()
        await licenseMutations.registerIntent(revision)
        do {
            let validated = try await client.validate(
                key: license.key,
                organizationID: configuration.organizationID,
                activationID: license.activationID,
                conditions: licenseConditions
            )
            let updated = try storedLicense(
                key: license.key,
                activationID: license.activationID,
                activationLicenseKeyID: license.licenseKeyID,
                licenseKey: validated,
                device: license.device,
                validatedAt: Date()
            )
            guard try await licenseMutations.save(updated, revision: revision) else { return false }
            guard revision == stateRevision else { return false }
            snapshot = EntitlementSnapshot(
                access: LicenseEntitlementPolicy.access(
                    for: updated,
                    currentMajorVersion: configuration.currentMajorVersion
                ),
                trial: snapshot.trial,
                license: updated,
                lastErrorMessage: nil
            )
            return true
        } catch {
            guard revision == stateRevision else { return false }
            logger.error("License validation failed: \(error.localizedDescription, privacy: .public)")
            // In sandbox/local dev builds, production license keys will always fail
            // to validate against the sandbox Polar API. Suppress the user-facing
            // banner there — keep cached access and the log entry only.
            let errorMessage: String? = configuration.isSandboxEnvironment
                ? nil
                : "Could not validate license. Cached access remains active while offline."
            snapshot = EntitlementSnapshot(
                access: snapshot.access,
                trial: snapshot.trial,
                license: snapshot.license,
                lastErrorMessage: errorMessage
            )
            return false
        }
    }

    private func storedLicense(
        key: String,
        activationID: String,
        activationLicenseKeyID: String,
        licenseKey: PolarLicenseKey,
        device: DeviceActivationIdentity,
        validatedAt: Date
    ) throws -> StoredLicense {
        guard configuration.validatesBenefitID(licenseKey.benefitID) else {
            throw LicenseValidationError.unsupportedBenefit
        }

        let tier = configuration.tier(for: licenseKey.benefitID)
        let licensedMajorVersion = tier.includesFutureMajorVersions
            ? Int.max
            : configuration.personalLicensedMajorVersion
        return StoredLicense(
            key: key,
            activationID: activationID,
            licenseKeyID: activationLicenseKeyID,
            displayKey: licenseKey.displayKey,
            benefitID: licenseKey.benefitID,
            tier: tier,
            status: licenseKey.status,
            activationLimit: licenseKey.limitActivations,
            activationUsage: licenseKey.usage,
            licensedMajorVersion: licensedMajorVersion,
            lastValidatedAt: licenseKey.lastValidatedAt ?? validatedAt,
            device: device
        )
    }

    private func setError(_ message: String) {
        _ = beginStateOperation()
        snapshot = EntitlementSnapshot(
            access: snapshot.access,
            trial: snapshot.trial,
            license: snapshot.license,
            lastErrorMessage: message
        )
    }

    @discardableResult
    private func beginStateOperation() -> UInt {
        stateRevision &+= 1
        return stateRevision
    }

    private func setStorageUnavailable(revision: UInt) {
        guard revision == stateRevision else { return }
        snapshot = EntitlementSnapshot(
            access: .expiredTrial,
            trial: nil,
            license: nil,
            lastErrorMessage: "License storage is unavailable."
        )
    }
}

private actor OrderedLicenseMutationCoordinator {
    private let storage: LicenseStorage
    private var latestIntentRevision: UInt = 0
    private var mutationTail: Task<Void, Never>?

    init(storage: LicenseStorage) {
        self.storage = storage
    }

    func registerIntent(_ revision: UInt) {
        latestIntentRevision = max(latestIntentRevision, revision)
    }

    func save(_ license: StoredLicense, revision: UInt) async throws -> Bool {
        guard revision == latestIntentRevision else { return false }
        let predecessor = mutationTail
        let operation = Task {
            await predecessor?.value
            try await storage.saveLicense(license)
        }
        mutationTail = Task { try? await operation.value }
        try await operation.value
        return revision == latestIntentRevision
    }

    func delete(revision: UInt) async throws -> Bool {
        guard revision == latestIntentRevision else { return false }
        let predecessor = mutationTail
        let operation = Task {
            await predecessor?.value
            try await storage.deleteLicense()
        }
        mutationTail = Task { try? await operation.value }
        try await operation.value
        return revision == latestIntentRevision
    }
}

private enum LicenseValidationError: Error, LocalizedError {
    case unsupportedBenefit

    var errorDescription: String? {
        switch self {
        case .unsupportedBenefit:
            return "This license key is not for FastTab."
        }
    }
}
