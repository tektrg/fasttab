import Foundation
import Testing
@testable import FastTab

@Test func searchResultsSortByTypePriorityBeforeRecency() async throws {
    let now = Date()
    let history = BrowserSearchResult(
        title: "Recent history",
        url: "https://example.com/history",
        browserName: "Google Chrome",
        type: .history,
        timestamp: now
    )
    let bookmark = BrowserSearchResult(
        title: "Older bookmark",
        url: "https://example.com/bookmark",
        browserName: "Google Chrome",
        type: .bookmark,
        timestamp: now.addingTimeInterval(-60)
    )
    let tab = BrowserSearchResult(
        title: "Old tab",
        url: "https://example.com/tab",
        browserName: "Microsoft Edge",
        type: .tab,
        timestamp: now.addingTimeInterval(-120)
    )

    let sorted = sortBrowserSearchResults([history, bookmark, tab])

    #expect(sorted.map(\.type) == [.tab, .bookmark, .history])
}

@Test func searchResultsSortNewestFirstWithinSameType() async throws {
    let now = Date()
    let olderBookmark = BrowserSearchResult(
        title: "Older bookmark",
        url: "https://example.com/older",
        browserName: "Google Chrome",
        type: .bookmark,
        timestamp: now.addingTimeInterval(-300)
    )
    let newerBookmark = BrowserSearchResult(
        title: "Newer bookmark",
        url: "https://example.com/newer",
        browserName: "Google Chrome",
        type: .bookmark,
        timestamp: now
    )

    let sorted = sortBrowserSearchResults([olderBookmark, newerBookmark])

    #expect(sorted.map(\.title) == ["Newer bookmark", "Older bookmark"])
}

@Test func searchResultMatchesTitleOrURLCaseInsensitively() async throws {
    let result = BrowserSearchResult(
        title: "Command Bar Spec",
        url: "https://docs.example.com/command-bar",
        browserName: "Google Chrome",
        type: .bookmark,
        timestamp: .now
    )

    #expect(result.matches(query: "spec"))
    #expect(result.matches(query: "DOCS.EXAMPLE.COM"))
    #expect(!result.matches(query: "calendar"))
}

@Test func searchResultUsesURLWhenSourceTitleIsEmpty() async throws {
    let result = BrowserSearchResult(
        title: "  ",
        url: "https://example.com/loading",
        browserName: "Microsoft Edge",
        type: .tab,
        timestamp: .now
    )

    #expect(result.title == "https://example.com/loading")
}

@Test func searchResultStripsMediaIndicatorFromWindowNameOnly() async throws {
    let result = BrowserSearchResult(
        title: "\u{1F50A} Playing tab title",
        url: "https://example.com/audio",
        browserName: "Google Chrome",
        type: .tab,
        timestamp: .now,
        windowName: "\u{1F50A} Shared audio window"
    )

    #expect(result.title == "\u{1F50A} Playing tab title")
    #expect(result.windowName == "Shared audio window")
}

@Test func browserWindowMediaIndicatorMapsToOnlyMatchingTab() async throws {
    #expect(browserWindowMediaIndicatorBelongsToTab(
        tabTitle: "How to Claim Your Leadership Power | Michael Timms | TED - YouTube",
        windowName: "\u{1F50A} How to Claim Your Leadership P…Michael Timms | TED - YouTube"
    ))
    #expect(!browserWindowMediaIndicatorBelongsToTab(
        tabTitle: "Extensions",
        windowName: "\u{1F50A} How to Claim Your Leadership P…Michael Timms | TED - YouTube"
    ))
}

@Test func normalizedBrowserWindowNameStripsTrailingMediaIndicator() async throws {
    #expect(normalizedBrowserWindowName("Shared audio window \u{1F50A}") == "Shared audio window")
}

@Test func quickOpenVisibleTabsSkipsCurrentFlowActiveTab() async throws {
    let now = Date()
    let activeTab = BrowserSearchResult(
        title: "Active tab",
        url: "https://example.com/active",
        browserName: "Microsoft Edge",
        type: .tab,
        timestamp: now,
        isCurrentFlowActiveTab: true
    )
    let previousTab = BrowserSearchResult(
        title: "Previous tab",
        url: "https://example.com/previous",
        browserName: "Microsoft Edge",
        type: .tab,
        timestamp: now.addingTimeInterval(-10)
    )
    let olderTab = BrowserSearchResult(
        title: "Older tab",
        url: "https://example.com/older",
        browserName: "Microsoft Edge",
        type: .tab,
        timestamp: now.addingTimeInterval(-20)
    )

    let visibleTabs = quickOpenVisibleTabs(from: [activeTab, previousTab, olderTab], limit: 2)

    #expect(visibleTabs.map(\.title) == ["Previous tab", "Older tab"])
}

@Test func tabRecencyKeyDistinguishesDuplicateURLsByTabSlot() async throws {
    let first = BrowserSearchResult(
        title: "First duplicate",
        url: "https://example.com/shared",
        browserName: "Google Chrome",
        type: .tab,
        timestamp: .now,
        windowIndex: 1,
        tabIndex: 1
    )
    let second = BrowserSearchResult(
        title: "Second duplicate",
        url: "https://example.com/shared",
        browserName: "Google Chrome",
        type: .tab,
        timestamp: .now,
        windowIndex: 2,
        tabIndex: 1
    )

    #expect(first.tabRecencyKey != second.tabRecencyKey)
    #expect(first.tabRecencyKey == makeTabRecencyKey(
        browserName: "Google Chrome",
        windowIndex: 1,
        tabIndex: 1,
        url: "https://example.com/shared"
    ))
}

@Test func commandBarCanvasExpandsToLargeDisplay() async throws {
    let displayFrame = CGRect(x: -1920, y: 0, width: 2560, height: 1440)

    let canvasFrame = CommandBarLayout.canvasFrame(for: displayFrame)

    #expect(canvasFrame == displayFrame)
}

@Test func commandBarCanvasKeepsSurfaceVisibleOnTinyDisplay() async throws {
    let displayFrame = CGRect(x: 100, y: 200, width: 500, height: 320)

    let canvasFrame = CommandBarLayout.canvasFrame(for: displayFrame)

    #expect(canvasFrame.size == CommandBarLayout.surfaceSize)
    #expect(canvasFrame.midX == displayFrame.midX)
    #expect(canvasFrame.midY == displayFrame.midY)
}

@Test func commandBarShadowBackdropOverscansCanvas() async throws {
    let canvasSize = CGSize(width: 2560, height: 1440)

    let backdropSize = CommandBarLayout.shadowBackdropSize(for: canvasSize)

    #expect(backdropSize.width == canvasSize.width + CommandBarLayout.shadowOverscan)
    #expect(backdropSize.height == canvasSize.height + CommandBarLayout.shadowOverscan)
}

@Test func trialPolicyExpiresAfterSevenDays() async throws {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let trial = TrialRecord(startedAt: start)

    #expect(TrialPolicy.access(for: trial, now: start) == .trial(daysRemaining: 7))
    #expect(TrialPolicy.access(for: trial, now: start.addingTimeInterval(6 * 24 * 60 * 60)) == .trial(daysRemaining: 1))
    #expect(TrialPolicy.access(for: trial, now: start.addingTimeInterval(7 * 24 * 60 * 60)) == .expiredTrial)
}

@Test func personalLicenseRequiresPaidUpgradeForFutureMajorVersion() async throws {
    let license = makeStoredLicense(
        tier: .personal,
        status: .granted,
        licensedMajorVersion: 1
    )

    #expect(LicenseEntitlementPolicy.access(for: license, currentMajorVersion: 2) == .paidMajorUpgradeRequired(.personal))
}

@Test func lifetimeLicenseCoversFutureMajorVersion() async throws {
    let license = makeStoredLicense(
        tier: .lifetime,
        status: .granted,
        licensedMajorVersion: Int.max
    )

    #expect(LicenseEntitlementPolicy.access(for: license, currentMajorVersion: 9) == .licensed(.lifetime))
}

@Test func revokedLicenseBlocksImmediately() async throws {
    let license = makeStoredLicense(
        tier: .lifetime,
        status: .revoked,
        licensedMajorVersion: Int.max
    )

    #expect(LicenseEntitlementPolicy.access(for: license, currentMajorVersion: 1) == .revoked)
}

@Test func paymentConfigurationMapsTierFromConfiguredBenefitIDOnly() async throws {
    let configuration = PaymentConfiguration(
        organizationID: "org",
        personalBenefitID: "personal-benefit",
        lifetimeBenefitID: "lifetime-benefit",
        teamBenefitID: "team-benefit",
        personalCheckoutURL: nil,
        lifetimeCheckoutURL: nil,
        teamCheckoutURL: nil,
        manageLicenseURL: nil,
        supportURL: nil,
        currentMajorVersion: 1,
        personalLicensedMajorVersion: 1,
        apiBaseURL: URL(string: "https://api.polar.sh")!
    )

    #expect(configuration.tier(for: "team-benefit") == .team)
    #expect(configuration.tier(for: "unknown-benefit") == .unknown)
    #expect(configuration.validatesBenefitID("team-benefit"))
    #expect(!configuration.validatesBenefitID("unknown-benefit"))
}

@Test func polarLicenseKeyDecodesFractionalAndStandardDates() async throws {
    let fractionalJSON = """
    {
      "id": "license-id",
      "benefit_id": "benefit-id",
      "display_key": "****-KEY",
      "status": "granted",
      "limit_activations": 3,
      "usage": 1,
      "last_validated_at": "2024-09-02T13:57:00.977363Z"
    }
    """.data(using: .utf8)!

    let standardJSON = """
    {
      "id": "license-id",
      "benefit_id": "benefit-id",
      "display_key": "****-KEY",
      "status": "granted",
      "limit_activations": 3,
      "usage": 1,
      "last_validated_at": "2024-09-02T13:57:00Z"
    }
    """.data(using: .utf8)!

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom(PolarDateDecoder.decode)

    #expect(try decoder.decode(PolarLicenseKey.self, from: fractionalJSON).lastValidatedAt != nil)
    #expect(try decoder.decode(PolarLicenseKey.self, from: standardJSON).lastValidatedAt != nil)
}

@MainActor
@Test func licenseServiceRefreshesTrialExpiryWithoutStorageRead() async throws {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let storage = InMemoryLicenseStorage(trial: TrialRecord(startedAt: start))
    let service = LicenseService(
        configuration: testPaymentConfiguration(),
        storage: storage,
        client: NoopPolarLicenseClient()
    )

    #expect(service.snapshot.access == .trial(daysRemaining: 7))

    service.refreshTimeSensitiveState(now: start.addingTimeInterval(7 * 24 * 60 * 60))

    #expect(service.snapshot.access == .expiredTrial)
    #expect(storage.loadTrialCount == 1)
}

private func makeStoredLicense(
    tier: FastTabLicenseTier,
    status: PolarLicenseStatus,
    licensedMajorVersion: Int
) -> StoredLicense {
    StoredLicense(
        key: "license-key",
        activationID: "activation-id",
        licenseKeyID: "license-id",
        displayKey: "****-KEY",
        benefitID: "benefit-id",
        tier: tier,
        status: status,
        activationLimit: 5,
        activationUsage: 1,
        licensedMajorVersion: licensedMajorVersion,
        lastValidatedAt: Date(timeIntervalSince1970: 1_800_000_000),
        device: DeviceActivationIdentity(installID: "install-id", label: "Test Mac")
    )
}

private func testPaymentConfiguration() -> PaymentConfiguration {
    PaymentConfiguration(
        organizationID: "org",
        personalBenefitID: "personal-benefit",
        lifetimeBenefitID: "lifetime-benefit",
        teamBenefitID: "team-benefit",
        personalCheckoutURL: nil,
        lifetimeCheckoutURL: nil,
        teamCheckoutURL: nil,
        manageLicenseURL: nil,
        supportURL: nil,
        currentMajorVersion: 1,
        personalLicensedMajorVersion: 1,
        apiBaseURL: URL(string: "https://api.polar.sh")!
    )
}

@MainActor
private final class InMemoryLicenseStorage: LicenseStorage {
    var trial: TrialRecord?
    var license: StoredLicense?
    var device: DeviceActivationIdentity?
    var loadTrialCount = 0

    init(trial: TrialRecord? = nil, license: StoredLicense? = nil) {
        self.trial = trial
        self.license = license
    }

    func loadTrial() throws -> TrialRecord? {
        loadTrialCount += 1
        return trial
    }

    func saveTrial(_ trial: TrialRecord) throws {
        self.trial = trial
    }

    func loadLicense() throws -> StoredLicense? {
        license
    }

    func saveLicense(_ license: StoredLicense) throws {
        self.license = license
    }

    func deleteLicense() throws {
        license = nil
    }

    func loadDeviceIdentity() throws -> DeviceActivationIdentity? {
        device
    }

    func saveDeviceIdentity(_ identity: DeviceActivationIdentity) throws {
        device = identity
    }
}

@MainActor
private struct NoopPolarLicenseClient: PolarLicenseClient {
    func activate(
        key: String,
        organizationID: String,
        label: String,
        conditions: [String: Int],
        meta: [String: String]
    ) async throws -> PolarActivationResponse {
        throw PolarLicenseClientError.invalidResponse
    }

    func validate(
        key: String,
        organizationID: String,
        activationID: String,
        conditions: [String: Int]
    ) async throws -> PolarLicenseKey {
        throw PolarLicenseClientError.invalidResponse
    }
}
