import Combine
import Foundation
import IndieTelemetry

/// Fast Tab's anonymous usage events (portfolio telemetry flywheel), sent through IndieLibKit's
/// `IndieTelemetry` to theindie-api `POST /v1/events` as app "fasttab". All telemetry logic of the
/// Mac app lives here; call sites are one line each.
///
/// Three funnels (registry: `telemetry/funnels.yaml`):
/// - Onboard: first open → first tab switch. Installs that used Fast Tab before this build never
///   enter it (`isExistingUser`), so an update can't look like a first open.
/// - Activate: a result opened on 1, 2, 3 different days within 7 days of the first open
///   (new installs only).
/// - Upgrade, **per attempt** (`UpgradeAttempt`: a new Upgrade session after 30 min without an
///   Upgrade step): an upsell seen (trial banner, trial-ended paywall, Settings › License) → the
///   pricing page opened → a license activated on this Mac. Onboard/Activate keep their session.
///
/// Where events go (`Delivery`): Release builds send; Debug builds only with `-telemetryLive YES`
/// (else names are still checked, nothing leaves the Mac); unit tests never configure it.
/// Never sent: tab titles, URLs, search text, license keys, the license/feedback install ids
/// (IndieTelemetry makes its own).
@MainActor
enum FastTabTelemetry {
    static let app = "fasttab"

    /// Every event name in `telemetry/funnels.yaml`; `FastTabTelemetryTests` fails when they differ.
    nonisolated static let registry: Set<String> = [
        "uf_Onboard_01_FirstOpen",
        "uf_Onboard_02_FirstTabSwitch",
        "uf_Activate_01_FirstDay",
        "uf_Activate_02_SecondDay",
        "uf_Activate_03_ThirdDay",
        "uf_Upgrade_01_UpsellViewed",
        "uf_Upgrade_02_CheckoutOpened",
        "uf_Upgrade_03_Purchased",
    ]

    static let onboard = IndieTelemetry.funnel("Onboard")
    static let activate = IndieTelemetry.funnel("Activate")
    static let upgrade = IndieTelemetry.funnel("Upgrade")

    /// True once `start` configured a client (unit tests never do: every hook below is then a no-op
    /// and writes nothing to UserDefaults).
    private static var isStarted: Bool { IndieTelemetry.client != nil }

    // MARK: Start

    enum Delivery: Equatable {
        /// Sent to the server.
        case live
        /// Checked and queued in memory, never sent (Debug without `-telemetryLive`, tests).
        case offline
    }

    /// Release: live. Debug: live only with `-telemetryLive YES`. A test host: offline.
    nonisolated static func delivery(isDebug: Bool, isTestHost: Bool, defaults: UserDefaults) -> Delivery {
        if isTestHost { return .offline }
        if isDebug { return defaults.bool(forKey: "telemetryLive") ? .live : .offline }
        return .live
    }

    nonisolated static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    nonisolated static func isTestHost(_ processInfo: ProcessInfo = .processInfo) -> Bool {
        processInfo.environment["XCTestConfigurationFilePath"] != nil
            || processInfo.environment["XCTestSessionIdentifier"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    /// This Mac ran Fast Tab before this launch. Read it as early as possible (the app delegate's
    /// init): the tab poll starts writing recency/frecency soon after launch.
    /// - `onboarding.v1.completed`: every build since onboarding shipped (May 2026).
    /// - `launchAtLogin.didInitialize`: every build up to 1.3 wrote it on first launch.
    /// - `FastTab.lastActiveTimes` / `FastTab.frecencyV1`: any build that ever saw a tab switch.
    nonisolated static func isExistingUser(defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: "onboarding.v1.completed")
            || defaults.object(forKey: "launchAtLogin.didInitialize") != nil
            || defaults.object(forKey: "FastTab.lastActiveTimes") != nil
            || defaults.object(forKey: "FastTab.frecencyV1") != nil
    }

    private static var licenseObserver: AnyCancellable?

    /// Once at launch, before anything is tracked. `isExistingUser`: from `isExistingUser(defaults:)`,
    /// read at the app delegate's init. FirstOpen waits for the license state (≤ 3 s) so it
    /// carries the right plan.
    static func start(isExistingUser: Bool, license: LicenseService,
                      defaults: UserDefaults = .standard, processInfo: ProcessInfo = .processInfo) {
        let delivery = delivery(isDebug: isDebugBuild, isTestHost: isTestHost(processInfo), defaults: defaults)
        var appVersion = TelemetryOptions.bundleVersion()
        if isDebugBuild { appVersion += " debug" }  // a live Debug run stays tellable apart in the data
        var options = TelemetryOptions(appVersion: appVersion, registry: registry)
        let plan = plan(for: license.snapshot)
        switch delivery {
        case .live:
            IndieTelemetry.configure(app: app, plan: plan, options: options, defaults: defaults)
        case .offline:
            options.storage = .memory
            options.flushInterval = nil
            IndieTelemetry.configure(app: app, plan: plan, options: options, defaults: defaults,
                                     transport: TelemetryNoopTransport())
        }

        #if DEBUG
        // `-telemetryFreshInstall YES`: this launch counts as a first open (proof runs).
        let freshInstall = defaults.bool(forKey: "telemetryFreshInstall")
        if freshInstall {
            OnboardProgress(defaults: defaults).reset()
            ActivateProgress(defaults: defaults).reset()
        }
        #else
        let freshInstall = false
        #endif

        let installChannel = channel(isDebug: isDebugBuild, payment: .live)
        var handledFirstOpen = false
        licenseObserver = license.$snapshot
            .filter { $0 != .starting }  // still loading: the plan isn't known yet
            .sink { snapshot in
                IndieTelemetry.setPlan(Self.plan(for: snapshot))
                guard !handledFirstOpen else { return }
                handledFirstOpen = true
                let progress = OnboardProgress(defaults: defaults)
                guard progress.appOpened(isExistingUser: isExistingUser && !freshInstall) else { return }
                onboard.step(1, "FirstOpen", props: ["install_source": "unknown", "channel": .string(installChannel)])
                progress.firstOpenQueued()  // only now: quit before this, and the next launch sends it
                ActivateProgress(defaults: defaults).begin(at: Date())
            }
    }

    // MARK: Onboard

    /// Where this install is in the Onboard funnel (UserDefaults `fasttab.telemetry.onboard`).
    struct OnboardProgress {
        static let key = "fasttab.telemetry.onboard"
        let defaults: UserDefaults

        /// Says whether to send FirstOpen: an install that never used Fast Tab, until `firstOpenQueued()`.
        func appOpened(isExistingUser: Bool) -> Bool {
            guard defaults.string(forKey: Self.key) == nil else { return false }
            if isExistingUser { defaults.set("done", forKey: Self.key) }
            return !isExistingUser
        }

        /// FirstOpen is in the queue (kept on disk): FirstTabSwitch may follow.
        func firstOpenQueued() {
            if defaults.string(forKey: Self.key) == nil { defaults.set("opened", forKey: Self.key) }
        }

        /// Says whether to send FirstTabSwitch: the first tab switch after a recorded first open.
        func tabSwitched() -> Bool {
            guard defaults.string(forKey: Self.key) == "opened" else { return false }
            defaults.set("done", forKey: Self.key)
            return true
        }

        func reset() { defaults.removeObject(forKey: Self.key) }
    }

    /// The person opened a result from the bar (`BrowserTabService.activate`): a tab switch counts
    /// for Onboard, any result counts as a day of use for Activate.
    /// `browser`: the app that owns the tab ("Google Chrome", "Safari", "Finder"); no title, no URL.
    static func resultOpened(isTabSwitch: Bool, browser: String,
                             defaults: UserDefaults = .standard, now: Date = Date()) {
        guard isStarted else { return }
        if isTabSwitch, OnboardProgress(defaults: defaults).tabSwitched() {
            onboard.step(2, "FirstTabSwitch", props: ["browser": .string(String(browser.prefix(40)))])
        }
        if let step = ActivateProgress(defaults: defaults).dayUsed(at: now) {
            activate.step(step, ActivateProgress.stepNames[step - 1])
        }
    }

    // MARK: Activate

    /// "3rd day used in 7": the distinct local days (up to 3) on which a new install opened a
    /// result, within 7 days of its first open. Each step is sent once. Only installs that sent
    /// FirstOpen are tracked (`begin`), so existing users never enter it.
    struct ActivateProgress {
        static let startKey = "fasttab.telemetry.activate.start"
        static let daysKey = "fasttab.telemetry.activate.days"
        static let windowDays = 7
        static let stepNames = ["FirstDay", "SecondDay", "ThirdDay"]

        let defaults: UserDefaults
        var calendar: Calendar = .current

        /// The first open: day 1 of the 7-day window.
        func begin(at now: Date) {
            guard defaults.object(forKey: Self.startKey) == nil else { return }
            defaults.set(now, forKey: Self.startKey)
        }

        /// The step (1…3) to send for a use at `now`, or nil: not tracked, outside the window,
        /// a day already counted, or all three days reached.
        func dayUsed(at now: Date) -> Int? {
            guard let start = defaults.object(forKey: Self.startKey) as? Date else { return nil }
            var days = defaults.stringArray(forKey: Self.daysKey) ?? []
            guard days.count < Self.stepNames.count,
                  let offset = calendar.dateComponents([.day], from: calendar.startOfDay(for: start),
                                                       to: calendar.startOfDay(for: now)).day,
                  (0..<Self.windowDays).contains(offset) else { return nil }
            let today = dayID(now)
            guard !days.contains(today) else { return nil }
            days.append(today)
            defaults.set(days, forKey: Self.daysKey)
            return days.count
        }

        func reset() {
            defaults.removeObject(forKey: Self.startKey)
            defaults.removeObject(forKey: Self.daysKey)
        }

        private func dayID(_ date: Date) -> String {
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
        }
    }

    // MARK: Upgrade

    /// Where an upsell / Buy button lives. Raw values are the `placement` prop.
    enum Placement: String {
        case trialBanner = "trial_banner"
        case expiredPaywall = "expired_paywall"
        case settings
        case menuBar = "menu_bar"

        init(_ source: LicenseService.CheckoutSource) {
            switch source {
            case .trialBanner: self = .trialBanner
            case .expiredPaywall: self = .expiredPaywall
            case .settings: self = .settings
            case .menuBar: self = .menuBar
            }
        }
    }

    /// When an Upgrade attempt (a new Upgrade funnel session) starts: at the first upsell or
    /// checkout step after `idleGap` without any Upgrade step this launch, the same rule as
    /// Parklet and Strider. Everything in between (banner → pricing page → license pasted) is one
    /// attempt. An upsell placement is reported once per `idleGap` (the bar redraws the trial
    /// banner on every open; seen again in the afternoon, it counts again).
    struct UpgradeAttempt: Equatable {
        static let idleGap: TimeInterval = 30 * 60
        private var lastStep: Date?
        private var upsellReportedAt: [String: Date] = [:]

        /// False when this placement was reported less than `idleGap` ago (then nothing is sent).
        mutating func shouldReportUpsell(_ placement: String, at now: Date) -> Bool {
            if let last = upsellReportedAt[placement], Self.isRecent(last, now) { return false }
            upsellReportedAt[placement] = now
            return true
        }

        /// Records an upsell or checkout step; true when it starts a new attempt.
        mutating func step(at now: Date) -> Bool {
            defer { lastStep = now }
            return lastStep.map { !Self.isRecent($0, now) } ?? true
        }

        /// A clock that went back counts as not recent.
        private static func isRecent(_ earlier: Date, _ now: Date) -> Bool {
            now >= earlier && now.timeIntervalSince(earlier) < idleGap
        }
    }

    private static var attempt = UpgradeAttempt()
    /// Where the last Buy click was, for the Purchased step (this launch).
    private static var lastCheckout: Placement?

    /// An upsell became visible. `reason` (paywall only): expired_trial, revoked, major_upgrade.
    static func upsellViewed(_ placement: Placement, reason: String? = nil, now: Date = Date()) {
        guard isStarted, attempt.shouldReportUpsell(placement.rawValue, at: now) else { return }
        if attempt.step(at: now) { upgrade.startSession() }
        var props: [String: TelemetryValue] = ["placement": .string(placement.rawValue)]
        if let reason { props["reason"] = .string(reason) }
        upgrade.step(1, "UpsellViewed", props: props)
    }

    /// A Buy button opened the pricing page (`LicenseService.openCheckout`).
    static func checkoutOpened(_ placement: Placement, now: Date = Date()) {
        guard isStarted else { return }
        lastCheckout = placement
        if attempt.step(at: now) { upgrade.startSession() }
        upgrade.step(2, "CheckoutOpened", props: ["placement": .string(placement.rawValue)])
    }

    /// A license key was activated on this Mac (the purchase itself happens on the website). Sent in
    /// the current attempt's session; never starts one. `firstActivation`: Polar counts this as the
    /// key's only activation (a new purchase, not a second Mac or a reinstall).
    static func licenseActivated(tier: FastTabLicenseTier, firstActivation: Bool) {
        guard isStarted else { return }
        IndieTelemetry.setPlan(.paid)
        upgrade.step(3, "Purchased", props: [
            "placement": .string(lastCheckout?.rawValue ?? "unknown"),
            "tier": .string(tier.rawValue),
            "first_activation": .bool(firstActivation),
        ])
    }

    /// The `reason` prop of the paywall upsell.
    nonisolated static func paywallReason(_ access: EntitlementAccess) -> String? {
        switch access {
        case .expiredTrial: return "expired_trial"
        case .revoked: return "revoked"
        case .paidMajorUpgradeRequired: return "major_upgrade"
        case .trial, .licensed: return nil
        }
    }

    // MARK: Plan

    /// A license that unlocks the app → paid; the built-in 7-day trial running → trial; anything
    /// else (trial over, revoked, needs a paid major upgrade) → free.
    nonisolated static func plan(for snapshot: EntitlementSnapshot) -> TelemetryPlan {
        switch snapshot.access {
        case .licensed: return .paid
        case .trial: return .trial
        case .expiredTrial, .revoked, .paidMajorUpgradeRequired: return .free
        }
    }

    // MARK: Channel

    /// How this copy was built: `debug` (Debug build), `local` (a Release build from the repo:
    /// Polar sandbox or no Polar config, i.e. not `distribute.sh`), `direct` (the notarized DMG).
    nonisolated static func channel(isDebug: Bool, payment: PaymentConfiguration) -> String {
        if isDebug { return "debug" }
        if !payment.canActivateLicenses || payment.isSandboxEnvironment { return "local" }
        return "direct"
    }
}
