import IndieAccount
import IndieLibKit
import IndieShareSync

// Fast Tab's values for the portfolio account and sharing (IndieLibKit's `IndieAccount` +
// `IndieShareSync`). The account is live (FastTabMobileApp builds the one `AccountSession`
// from `.fastTab`; YouTube transcripts use its token). Sharing isn't wired yet: only the
// tests build a coordinator.
// Once an account ships, none of these values may change: another keychain service signs
// every user out, another key prefix loses every phone's inbox position.

extension IndieAccountConfiguration {
    /// Each app signs in separately (owner decision 2026-09-27), so Fast Tab keeps its own
    /// keychain service rather than Parklet's `app.theindie.account`: device keys are stored
    /// per account, not per app, so a later shared keychain group would otherwise hand both
    /// apps one device key.
    static let fastTab = IndieAccountConfiguration(
        appSlug: "fasttab",
        keychainService: "app.theindie.fasttab.account",
        developmentServerURLDefaultsKey: "fasttab.devAccountServerURL",
        developmentServerURLInfoPlistKey: "TheIndieDevServerURL"
    )
}

extension IndieShareSyncConfiguration {
    static let fastTab = IndieShareSyncConfiguration(
        logSubsystem: "app.theindie.FastTab",
        userDefaultsKeyPrefix: "fasttab.",
        unnamedPersonName: "Someone"
    )
}

extension ItemSource {
    /// A tab or bookmark the user shared from Fast Tab on iPhone.
    static let fastTabShared = ItemSource(rawValue: "fasttab.ios")
    /// A link someone shared with the user.
    static let fastTabReceived = ItemSource(rawValue: "fasttab.received")
}
