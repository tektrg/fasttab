import Foundation

enum FastTabLicenseTier: String, Codable, Equatable {
    case personal
    case lifetime
    case team
    case unknown

    var displayName: String {
        switch self {
        case .personal:
            return "Personal"
        case .lifetime:
            return "Lifetime"
        case .team:
            return "Team"
        case .unknown:
            return "FastTab"
        }
    }

    var includesFutureMajorVersions: Bool {
        switch self {
        case .lifetime, .team:
            return true
        case .personal, .unknown:
            return false
        }
    }
}

enum PolarLicenseStatus: String, Codable, Equatable {
    case granted
    case revoked
    case disabled
}

struct TrialRecord: Codable, Equatable {
    let startedAt: Date
}

struct DeviceActivationIdentity: Codable, Equatable {
    let installID: String
    let label: String

    static func current() -> DeviceActivationIdentity {
        DeviceActivationIdentity(
            installID: UUID().uuidString,
            label: Host.current().localizedName ?? "Mac"
        )
    }
}

struct StoredLicense: Codable, Equatable {
    let key: String
    let activationID: String
    let licenseKeyID: String
    let displayKey: String
    let benefitID: String
    let tier: FastTabLicenseTier
    let status: PolarLicenseStatus
    let activationLimit: Int?
    let activationUsage: Int
    let licensedMajorVersion: Int
    let lastValidatedAt: Date
    let device: DeviceActivationIdentity
}

enum EntitlementAccess: Equatable {
    case trial(daysRemaining: Int)
    case licensed(FastTabLicenseTier)
    case expiredTrial
    case revoked
    case paidMajorUpgradeRequired(FastTabLicenseTier)
}

struct EntitlementSnapshot: Equatable {
    let access: EntitlementAccess
    let trial: TrialRecord?
    let license: StoredLicense?
    let lastErrorMessage: String?

    var allowsCommandBarUtility: Bool {
        switch access {
        case .trial, .licensed:
            return true
        case .expiredTrial, .revoked, .paidMajorUpgradeRequired:
            return false
        }
    }

    var trialDaysRemaining: Int? {
        if case .trial(let daysRemaining) = access {
            return daysRemaining
        }
        return nil
    }

    static let starting = EntitlementSnapshot(
        access: .trial(daysRemaining: TrialPolicy.trialDurationDays),
        trial: nil,
        license: nil,
        lastErrorMessage: nil
    )
}

struct TrialPolicy {
    static let trialDurationDays = 7

    static func access(for record: TrialRecord, now: Date = Date()) -> EntitlementAccess {
        let endDate = record.startedAt.addingTimeInterval(TimeInterval(trialDurationDays * 24 * 60 * 60))
        guard now < endDate else { return .expiredTrial }

        let secondsRemaining = endDate.timeIntervalSince(now)
        let daysRemaining = max(1, Int(ceil(secondsRemaining / (24 * 60 * 60))))
        return .trial(daysRemaining: min(trialDurationDays, daysRemaining))
    }
}

struct LicenseEntitlementPolicy {
    static func access(
        for license: StoredLicense,
        currentMajorVersion: Int
    ) -> EntitlementAccess {
        guard license.status == .granted else { return .revoked }

        if !license.tier.includesFutureMajorVersions,
           license.licensedMajorVersion < currentMajorVersion {
            return .paidMajorUpgradeRequired(license.tier)
        }

        return .licensed(license.tier)
    }
}

struct PolarLicenseKey: Decodable, Equatable {
    let id: String
    let benefitID: String
    let displayKey: String
    let status: PolarLicenseStatus
    let limitActivations: Int?
    let usage: Int
    let lastValidatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case benefitID = "benefit_id"
        case displayKey = "display_key"
        case status
        case limitActivations = "limit_activations"
        case usage
        case lastValidatedAt = "last_validated_at"
    }

    init(
        id: String,
        benefitID: String,
        displayKey: String,
        status: PolarLicenseStatus,
        limitActivations: Int?,
        usage: Int,
        lastValidatedAt: Date?
    ) {
        self.id = id
        self.benefitID = benefitID
        self.displayKey = displayKey
        self.status = status
        self.limitActivations = limitActivations
        self.usage = usage
        self.lastValidatedAt = lastValidatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        benefitID = try container.decode(String.self, forKey: .benefitID)
        displayKey = try container.decode(String.self, forKey: .displayKey)
        status = try container.decode(PolarLicenseStatus.self, forKey: .status)
        limitActivations = try container.decodeIfPresent(Int.self, forKey: .limitActivations)
        usage = try container.decode(Int.self, forKey: .usage)
        lastValidatedAt = try container.decodeIfPresent(Date.self, forKey: .lastValidatedAt)
    }
}

struct PolarActivationResponse: Decodable, Equatable {
    let id: String
    let licenseKeyID: String
    let label: String
    let licenseKey: PolarLicenseKey

    enum CodingKeys: String, CodingKey {
        case id
        case licenseKeyID = "license_key_id"
        case label
        case licenseKey = "license_key"
    }
}
