import SwiftUI

/// "License" tab of Settings: trial/license status and activation.
struct LicenseSettingsView: View {
    @EnvironmentObject var licenseService: LicenseService
    @State private var licenseKey: String = ""

    var body: some View {
        Form {
            Section("License") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(licenseStatusTitle)
                        .font(.callout.weight(.medium))
                    Text(licenseStatusDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    SecureField("License key", text: $licenseKey)
                    Button(licenseService.isActivating ? "Activating…" : "Activate") {
                        Task {
                            await licenseService.activateLicense(key: licenseKey)
                            if licenseService.snapshot.license != nil {
                                licenseKey = ""
                            }
                        }
                    }
                    .disabled(licenseService.isActivating || licenseKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                HStack {
                    Button("Buy FastTab") {
                        licenseService.openCheckout(source: .settings)
                    }
                    Button("Manage License") {
                        licenseService.openManageLicense()
                    }
                    if licenseService.snapshot.license != nil {
                        Button("Remove License") {
                            licenseService.clearLicense()
                        }
                    }
                }

                if let lastErrorMessage = licenseService.snapshot.lastErrorMessage {
                    Text(lastErrorMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var licenseStatusTitle: String {
        switch licenseService.snapshot.access {
        case .trial(let daysRemaining):
            return "Trial active: \(daysRemaining) day\(daysRemaining == 1 ? "" : "s") left"
        case .licensed(let tier):
            return "\(tier.displayName) license active"
        case .expiredTrial:
            return "Trial ended"
        case .revoked:
            return "License needs attention"
        case .paidMajorUpgradeRequired:
            return "Paid upgrade required"
        }
    }

    private var licenseStatusDetail: String {
        if let license = licenseService.snapshot.license {
            let activationText = license.activationLimit.map { "\(license.activationUsage)/\($0) activations" } ?? "\(license.activationUsage) activations"
            return "\(license.displayKey) · \(activationText) · Last checked \(license.lastValidatedAt.formatted(date: .abbreviated, time: .shortened))"
        }

        switch licenseService.snapshot.access {
        case .trial:
            return "FastTab is fully unlocked during the 7-day trial."
        case .expiredTrial:
            return "Buy once or paste a Polar license key to continue using FastTab."
        case .revoked:
            return "This license is revoked or disabled. Contact support if this looks wrong."
        case .paidMajorUpgradeRequired(let tier):
            return "The \(tier.displayName) license does not include this paid major version."
        case .licensed:
            return "FastTab is unlocked."
        }
    }
}
