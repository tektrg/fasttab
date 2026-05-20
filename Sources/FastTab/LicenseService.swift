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
    private let client: PolarLicenseClient
    private let logger = Logger(subsystem: "com.trungluong.FastTab", category: "LicenseService")
    private let lastValidationVersionKey = "FastTab.license.lastValidationVersion"
    private var pendingLaunchValidationVersion: String?

    init(
        configuration: PaymentConfiguration,
        storage: LicenseStorage,
        client: PolarLicenseClient
    ) {
        self.configuration = configuration
        self.storage = storage
        self.client = client
        refreshCachedState()
    }

    func refreshCachedState(now: Date = Date()) {
        do {
            var trial = try storage.loadTrial()
            if trial == nil {
                trial = TrialRecord(startedAt: now)
                try storage.saveTrial(trial!)
            }

            if let license = try storage.loadLicense() {
                let access = LicenseEntitlementPolicy.access(
                    for: license,
                    currentMajorVersion: configuration.currentMajorVersion
                )
                snapshot = EntitlementSnapshot(access: access, trial: trial, license: license, lastErrorMessage: nil)
                return
            }

            snapshot = EntitlementSnapshot(
                access: TrialPolicy.access(for: trial!, now: now),
                trial: trial,
                license: nil,
                lastErrorMessage: nil
            )
        } catch {
            logger.error("Failed to refresh license state: \(error.localizedDescription, privacy: .public)")
            snapshot = EntitlementSnapshot(
                access: .expiredTrial,
                trial: nil,
                license: nil,
                lastErrorMessage: "License storage is unavailable."
            )
        }
    }

    func refreshTimeSensitiveState(now: Date = Date()) {
        guard snapshot.license == nil, let trial = snapshot.trial else { return }
        let nextAccess = TrialPolicy.access(for: trial, now: now)
        guard nextAccess != snapshot.access else { return }
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

        do {
            let device = try ensureDeviceIdentity()
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
            try storage.saveLicense(stored)
            snapshot = EntitlementSnapshot(
                access: LicenseEntitlementPolicy.access(
                    for: stored,
                    currentMajorVersion: configuration.currentMajorVersion
                ),
                trial: try storage.loadTrial(),
                license: stored,
                lastErrorMessage: nil
            )
        } catch {
            logger.error("License activation failed: \(error.localizedDescription, privacy: .public)")
            setError(error.localizedDescription)
        }
    }

    func clearLicense() {
        do {
            try storage.deleteLicense()
            refreshCachedState()
        } catch {
            setError("Could not remove the saved license.")
        }
    }

    func openCheckout(preferredTier: FastTabLicenseTier? = nil) {
        let url: URL?
        switch preferredTier {
        case .personal:
            url = configuration.personalCheckoutURL ?? configuration.bestCheckoutURL
        case .lifetime:
            url = configuration.lifetimeCheckoutURL ?? configuration.bestCheckoutURL
        case .team:
            url = configuration.teamCheckoutURL ?? configuration.bestCheckoutURL
        case .unknown, nil:
            url = configuration.bestCheckoutURL
        }

        guard let url else {
            setError("Checkout is not configured in this build.")
            return
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

    private func ensureDeviceIdentity() throws -> DeviceActivationIdentity {
        if let existing = try storage.loadDeviceIdentity() {
            return existing
        }
        let identity = DeviceActivationIdentity.current()
        try storage.saveDeviceIdentity(identity)
        return identity
    }

    private func revalidateCachedLicense(_ license: StoredLicense) async -> Bool {
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
            try storage.saveLicense(updated)
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
            logger.error("License validation failed: \(error.localizedDescription, privacy: .public)")
            snapshot = EntitlementSnapshot(
                access: snapshot.access,
                trial: snapshot.trial,
                license: snapshot.license,
                lastErrorMessage: "Could not validate license. Cached access remains active while offline."
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
        snapshot = EntitlementSnapshot(
            access: snapshot.access,
            trial: snapshot.trial,
            license: snapshot.license,
            lastErrorMessage: message
        )
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
