import Foundation

struct PaymentConfiguration: Equatable {
    let organizationID: String
    let personalBenefitID: String
    let lifetimeBenefitID: String
    let teamBenefitID: String
    let personalCheckoutURL: URL?
    let lifetimeCheckoutURL: URL?
    let teamCheckoutURL: URL?
    let manageLicenseURL: URL?
    let supportURL: URL?
    let currentMajorVersion: Int
    let personalLicensedMajorVersion: Int
    let apiBaseURL: URL

    static var live: PaymentConfiguration {
        let bundle = Bundle.main
        return PaymentConfiguration(
            organizationID: bundle.infoString(forKey: "FastTabPolarOrganizationID"),
            personalBenefitID: bundle.infoString(forKey: "FastTabPolarPersonalBenefitID"),
            lifetimeBenefitID: bundle.infoString(forKey: "FastTabPolarLifetimeBenefitID"),
            teamBenefitID: bundle.infoString(forKey: "FastTabPolarTeamBenefitID"),
            personalCheckoutURL: bundle.infoURL(forKey: "FastTabPolarPersonalCheckoutURL"),
            lifetimeCheckoutURL: bundle.infoURL(forKey: "FastTabPolarLifetimeCheckoutURL"),
            teamCheckoutURL: bundle.infoURL(forKey: "FastTabPolarTeamCheckoutURL"),
            manageLicenseURL: bundle.infoURL(forKey: "FastTabPolarManageLicenseURL"),
            supportURL: bundle.infoURL(forKey: "FastTabSupportURL") ?? URL(string: "mailto:support@theindie.app"),
            currentMajorVersion: bundle.fastTabMajorVersion,
            personalLicensedMajorVersion: bundle.infoInt(forKey: "FastTabPersonalLicensedMajorVersion") ?? 1,
            apiBaseURL: bundle.infoURL(forKey: "FastTabPolarAPIBaseURL") ?? URL(string: "https://api.polar.sh")!
        )
    }

    var canActivateLicenses: Bool {
        !organizationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var bestCheckoutURL: URL? {
        lifetimeCheckoutURL ?? personalCheckoutURL ?? teamCheckoutURL
    }

    var configuredBenefitIDs: Set<String> {
        [personalBenefitID, lifetimeBenefitID, teamBenefitID]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .reduce(into: Set<String>()) { result, benefitID in
                result.insert(benefitID)
            }
    }

    func tier(for benefitID: String) -> FastTabLicenseTier {
        if !personalBenefitID.isEmpty, benefitID == personalBenefitID { return .personal }
        if !lifetimeBenefitID.isEmpty, benefitID == lifetimeBenefitID { return .lifetime }
        if !teamBenefitID.isEmpty, benefitID == teamBenefitID { return .team }
        return .unknown
    }

    func validatesBenefitID(_ benefitID: String) -> Bool {
        let configuredBenefitIDs = configuredBenefitIDs
        guard !configuredBenefitIDs.isEmpty else {
            return false
        }
        return configuredBenefitIDs.contains(benefitID)
    }
}

private extension Bundle {
    func infoString(forKey key: String) -> String {
        object(forInfoDictionaryKey: key) as? String ?? ""
    }

    func infoURL(forKey key: String) -> URL? {
        let value = infoString(forKey: key).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return URL(string: value)
    }

    func infoInt(forKey key: String) -> Int? {
        let value = infoString(forKey: key).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return Int(value)
    }

    var fastTabMajorVersion: Int {
        let version = infoString(forKey: "CFBundleShortVersionString")
        return Int(version.split(separator: ".").first ?? "1") ?? 1
    }
}
