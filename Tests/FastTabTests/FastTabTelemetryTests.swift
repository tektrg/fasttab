import Foundation
import IndieTelemetry
import Testing
@testable import FastTab

/// `FastTabTelemetry`: the registry matches `telemetry/funnels.yaml`, who enters Onboard and
/// Activate, the Upgrade attempt rules, the plan rule, the channel, and when events may leave the Mac.
@MainActor
struct FastTabTelemetryTests {
    // MARK: Registry

    /// Every name in `telemetry/funnels.yaml`, flattened (funnel steps and plain events).
    private static func yamlNames() throws -> Set<String> {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appending(path: "telemetry/funnels.yaml"), encoding: .utf8)
        var names: Set<String> = []
        var section = ""
        var funnel: String?
        var stepNumber: Int?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") || trimmed.isEmpty { continue }
            let indent = line.prefix { $0 == " " }.count
            if indent == 0 { section = String(trimmed.split(separator: ":")[0]); continue }
            switch section {
            case "funnels":
                if indent == 2, trimmed.hasSuffix(":") { funnel = String(trimmed.dropLast()) }
                if trimmed.hasPrefix("- number:") {
                    stepNumber = Int(trimmed.dropFirst("- number:".count).trimmingCharacters(in: .whitespaces))
                }
                if trimmed.hasPrefix("name:"), let funnel, let number = stepNumber {
                    let step = trimmed.dropFirst("name:".count).trimmingCharacters(in: .whitespaces)
                    names.insert(TelemetryEventName.funnelStep(funnel: funnel, number: number, step: step))
                    stepNumber = nil
                }
            case "events":
                if indent == 2, trimmed.hasSuffix(":") { names.insert(String(trimmed.dropLast())) }
            default:
                break
            }
        }
        return names
    }

    @Test func registryMatchesFunnelsYaml() throws {
        let yaml = try Self.yamlNames()
        #expect(yaml.count >= 8, "the parser must see the funnels: \(yaml)")
        #expect(FastTabTelemetry.registry == yaml)
    }

    @Test func everyRegisteredNameIsWellFormed() {
        for name in FastTabTelemetry.registry {
            #expect(TelemetryEventName.isValid(name), "\(name)")
        }
    }

    // MARK: Helpers

    private func freshDefaults() -> UserDefaults {
        let suite = "FastTabTelemetryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// 2026-11-01 plus `days` days and `hours` hours, UTC.
    private func date(days: Int, hours: Int = 10) -> Date {
        let base = utc.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        return base.addingTimeInterval(TimeInterval(days * 86_400 + hours * 3_600))
    }

    // MARK: Existing user

    @Test func anEarlierRunOfFastTabMakesAnExistingUser() {
        #expect(!FastTabTelemetry.isExistingUser(defaults: freshDefaults()))
        for key in ["onboarding.v1.completed", "launchAtLogin.didInitialize", "FastTab.lastActiveTimes", "FastTab.frecencyV1"] {
            let defaults = freshDefaults()
            defaults.set(true, forKey: key)
            #expect(FastTabTelemetry.isExistingUser(defaults: defaults), "\(key)")
        }
    }

    // MARK: Onboard

    @Test func newInstallSendsFirstOpenOnceThenFirstTabSwitchOnce() {
        let progress = FastTabTelemetry.OnboardProgress(defaults: freshDefaults())
        #expect(progress.appOpened(isExistingUser: false))
        #expect(!progress.tabSwitched(), "no first switch before first open is queued")
        #expect(progress.appOpened(isExistingUser: false), "quit before it was queued: the next launch sends it")
        progress.firstOpenQueued()
        #expect(!progress.appOpened(isExistingUser: false), "second launch is not a first open")
        #expect(progress.tabSwitched())
        #expect(!progress.tabSwitched(), "only the first switch counts")
    }

    @Test func existingUserNeverEntersOnboard() {
        let progress = FastTabTelemetry.OnboardProgress(defaults: freshDefaults())
        #expect(!progress.appOpened(isExistingUser: true))
        #expect(!progress.tabSwitched())
        #expect(!progress.appOpened(isExistingUser: false), "an update stays out on later launches too")
    }

    // MARK: Activate

    @Test func activateCountsThreeDistinctDaysInsideSevenDays() {
        let progress = FastTabTelemetry.ActivateProgress(defaults: freshDefaults(), calendar: utc)
        progress.begin(at: date(days: 0, hours: 9))
        #expect(progress.dayUsed(at: date(days: 0, hours: 9)) == 1)
        #expect(progress.dayUsed(at: date(days: 0, hours: 20)) == nil, "same day counts once")
        #expect(progress.dayUsed(at: date(days: 2)) == 2)
        #expect(progress.dayUsed(at: date(days: 2, hours: 23)) == nil)
        #expect(progress.dayUsed(at: date(days: 6, hours: 23)) == 3, "day 7 is still inside the window")
        #expect(progress.dayUsed(at: date(days: 6, hours: 23)) == nil, "each step once")
    }

    @Test func activateStopsAfterTheSevenDayWindow() {
        let progress = FastTabTelemetry.ActivateProgress(defaults: freshDefaults(), calendar: utc)
        progress.begin(at: date(days: 0, hours: 23))
        #expect(progress.dayUsed(at: date(days: 1, hours: 1)) == 1, "the next calendar day is a new day")
        #expect(progress.dayUsed(at: date(days: 7)) == nil, "day 8 is outside")
        #expect(progress.dayUsed(at: date(days: -1)) == nil, "a clock set back is ignored")
    }

    @Test func activateIgnoresInstallsThatNeverSentFirstOpen() {
        let progress = FastTabTelemetry.ActivateProgress(defaults: freshDefaults(), calendar: utc)
        #expect(progress.dayUsed(at: date(days: 0)) == nil)
    }

    @Test func activateBeginKeepsTheFirstStart() {
        let progress = FastTabTelemetry.ActivateProgress(defaults: freshDefaults(), calendar: utc)
        progress.begin(at: date(days: 0))
        progress.begin(at: date(days: 5))
        #expect(progress.dayUsed(at: date(days: 7)) == nil, "the window still starts at the first open")
    }

    // MARK: Upgrade

    @Test func anAttemptIsActivityWithin30IdleMinutes() {
        var attempt = FastTabTelemetry.UpgradeAttempt()
        let t0 = date(days: 0)
        var started = attempt.step(at: t0)
        #expect(started, "the first upsell of a launch starts an attempt")
        started = attempt.step(at: t0.addingTimeInterval(10 * 60))
        #expect(!started, "Buy 10 min later joins it")
        started = attempt.step(at: t0.addingTimeInterval(35 * 60))
        #expect(!started, "the gap is measured from the last step")
        started = attempt.step(at: t0.addingTimeInterval(66 * 60))
        #expect(started, "31 idle minutes: a new attempt")
        started = attempt.step(at: t0)
        #expect(started, "a clock set back starts a new attempt")
    }

    @Test func anUpsellPlacementCountsOncePer30Minutes() {
        var attempt = FastTabTelemetry.UpgradeAttempt()
        let t0 = date(days: 0)
        var report = attempt.shouldReportUpsell("trial_banner", at: t0)
        #expect(report)
        report = attempt.shouldReportUpsell("trial_banner", at: t0.addingTimeInterval(5 * 60))
        #expect(!report, "banner redrawn on every bar open")
        report = attempt.shouldReportUpsell("expired_paywall", at: t0.addingTimeInterval(5 * 60))
        #expect(report, "each placement on its own")
        report = attempt.shouldReportUpsell("trial_banner", at: t0.addingTimeInterval(31 * 60))
        #expect(report, "seen again later, it counts again")
    }

    @Test func paywallReasonNamesWhyTheAppIsLocked() {
        #expect(FastTabTelemetry.paywallReason(.expiredTrial) == "expired_trial")
        #expect(FastTabTelemetry.paywallReason(.revoked) == "revoked")
        #expect(FastTabTelemetry.paywallReason(.paidMajorUpgradeRequired(.personal)) == "major_upgrade")
        #expect(FastTabTelemetry.paywallReason(.trial(daysRemaining: 2)) == nil)
        #expect(FastTabTelemetry.paywallReason(.licensed(.lifetime)) == nil)
    }

    @Test func checkoutSourcesMapToPlacements() {
        #expect(FastTabTelemetry.Placement(.trialBanner) == .trialBanner)
        #expect(FastTabTelemetry.Placement(.expiredPaywall) == .expiredPaywall)
        #expect(FastTabTelemetry.Placement(.settings) == .settings)
        #expect(FastTabTelemetry.Placement(.menuBar).rawValue == "menu_bar")
    }

    // MARK: Plan

    private func snapshot(_ access: EntitlementAccess) -> EntitlementSnapshot {
        EntitlementSnapshot(access: access, trial: nil, license: nil, lastErrorMessage: nil)
    }

    @Test func planFollowsWhatThePersonHas() {
        #expect(FastTabTelemetry.plan(for: snapshot(.licensed(.personal))) == .paid)
        #expect(FastTabTelemetry.plan(for: snapshot(.trial(daysRemaining: 3))) == .trial)
        #expect(FastTabTelemetry.plan(for: snapshot(.expiredTrial)) == .free)
        #expect(FastTabTelemetry.plan(for: snapshot(.revoked)) == .free)
        #expect(FastTabTelemetry.plan(for: snapshot(.paidMajorUpgradeRequired(.personal))) == .free)
    }

    // MARK: Channel

    private func payment(apiBase: String, organization: String) -> PaymentConfiguration {
        PaymentConfiguration(
            organizationID: organization, personalBenefitID: "", lifetimeBenefitID: "", teamBenefitID: "",
            personalCheckoutURL: nil, lifetimeCheckoutURL: nil, teamCheckoutURL: nil, pricingURL: nil,
            manageLicenseURL: nil, supportURL: nil, currentMajorVersion: 1, personalLicensedMajorVersion: 1,
            apiBaseURL: URL(string: apiBase)!
        )
    }

    @Test func channelNamesHowThisCopyWasBuilt() {
        let production = payment(apiBase: "https://api.polar.sh", organization: "org")
        #expect(FastTabTelemetry.channel(isDebug: true, payment: production) == "debug")
        #expect(FastTabTelemetry.channel(isDebug: false, payment: production) == "direct")
        #expect(FastTabTelemetry.channel(isDebug: false, payment: payment(apiBase: "https://sandbox-api.polar.sh", organization: "org")) == "local")
        #expect(FastTabTelemetry.channel(isDebug: false, payment: payment(apiBase: "https://api.polar.sh", organization: "")) == "local")
    }

    // MARK: Delivery

    @Test func eventsLeaveTheMacOnlyFromReleaseOrALiveDebugRun() {
        let defaults = freshDefaults()
        #expect(FastTabTelemetry.delivery(isDebug: false, isTestHost: false, defaults: defaults) == .live)
        #expect(FastTabTelemetry.delivery(isDebug: false, isTestHost: true, defaults: defaults) == .offline)
        #expect(FastTabTelemetry.delivery(isDebug: true, isTestHost: false, defaults: defaults) == .offline)
        defaults.set(true, forKey: "telemetryLive")
        #expect(FastTabTelemetry.delivery(isDebug: true, isTestHost: false, defaults: defaults) == .live)
        #expect(FastTabTelemetry.delivery(isDebug: true, isTestHost: true, defaults: defaults) == .offline)
    }

    @Test func thisTestProcessIsATestHost() {
        #expect(FastTabTelemetry.isTestHost())
    }

    @Test func hooksDoNothingBeforeStart() {
        // Unit tests never call `start`: a hook must not write onboarding state to the defaults.
        #expect(IndieTelemetry.client == nil)
        let defaults = freshDefaults()
        FastTabTelemetry.OnboardProgress(defaults: defaults).firstOpenQueued()
        FastTabTelemetry.resultOpened(isTabSwitch: true, browser: "Safari", defaults: defaults)
        #expect(defaults.string(forKey: FastTabTelemetry.OnboardProgress.key) == "opened", "untouched by the hook")
    }
}
