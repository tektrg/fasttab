import SwiftUI

struct LicenseIssueBanner: View {
    let message: String
    let onSupport: () -> Void

    var body: some View {
        PermissionBanner(
            icon: "exclamationmark.triangle.fill",
            tint: .orange,
            message: message,
            actionTitle: "Support"
        ) {
            onSupport()
        }
    }
}

struct TrialStatusBanner: View {
    let daysRemaining: Int
    let onBuy: () -> Void
    let onActivate: () -> Void

    var body: some View {
        PermissionBanner(
            icon: isUrgent ? "clock.badge.exclamationmark" : "sparkles",
            tint: isUrgent ? .orange : .accentColor,
            message: message,
            actionTitle: "Buy FastTab",
            secondaryActionTitle: "Enter License Key",
            secondaryAction: onActivate
        ) {
            onBuy()
        }
    }

    private var isUrgent: Bool { daysRemaining <= 3 }

    private var message: String {
        let dayWord = daysRemaining == 1 ? "day" : "days"
        if isUrgent {
            return "Trial ends in \(daysRemaining) \(dayWord) — keep FastTab unlocked."
        }
        return "Trial active — \(daysRemaining) \(dayWord) left."
    }
}

struct PaywallView: View {
    let snapshot: EntitlementSnapshot
    let onBuy: () -> Void
    let onActivate: () -> Void
    let onSupport: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 12)
            Image(systemName: iconName)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.primary)
            VStack(spacing: 6) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button("Activate License") {
                    onActivate()
                }
                .controlSize(.large)

                Button("Buy FastTab") {
                    onBuy()
                }
                .commandBarProminentButtonStyle()
                .controlSize(.large)
            }
            Button("Contact Support") {
                onSupport()
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer(minLength: 12)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .frame(height: 300)
        .background(CommandBarSurfaceBackground(cornerRadius: 16))
    }

    private var iconName: String {
        switch snapshot.access {
        case .revoked:
            return "lock.trianglebadge.exclamationmark"
        case .paidMajorUpgradeRequired:
            return "arrow.up.circle"
        case .expiredTrial:
            return "lock.circle"
        case .trial, .licensed:
            return "checkmark.circle"
        }
    }

    private var title: String {
        switch snapshot.access {
        case .revoked:
            return "License Needs Attention"
        case .paidMajorUpgradeRequired:
            return "Upgrade Required"
        case .expiredTrial:
            return "Your Trial Has Ended"
        case .trial:
            return "Trial Active"
        case .licensed:
            return "FastTab Activated"
        }
    }

    private var message: String {
        switch snapshot.access {
        case .revoked:
            return "This license is no longer active. Buy a new license or contact support if this looks wrong."
        case .paidMajorUpgradeRequired:
            return "This license does not include this paid major version of FastTab."
        case .expiredTrial:
            return "Buy once to keep switching browser tabs at native speed."
        case .trial:
            return "Your trial is still active."
        case .licensed:
            return "Your license is active."
        }
    }
}

struct LicenseActivationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var licenseService: LicenseService
    @State private var licenseKey = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Activate FastTab")
                    .font(.title3.weight(.semibold))
                Text("Paste the Polar license key from your purchase email.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            SecureField("License key", text: $licenseKey)
                .textFieldStyle(.roundedBorder)

            if let lastErrorMessage = licenseService.snapshot.lastErrorMessage {
                Text(lastErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                Spacer()
                Button(licenseService.isActivating ? "Activating…" : "Activate") {
                    Task {
                        await licenseService.activateLicense(key: licenseKey)
                        if licenseService.snapshot.allowsCommandBarUtility {
                            dismiss()
                        }
                    }
                }
                .commandBarProminentButtonStyle()
                .disabled(licenseService.isActivating || licenseKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 420)
    }
}
