import Foundation
import Testing
@testable import FastTab
import FastTabSync

/// Fixed reference instant. Every case below passes `now` / `to` explicitly, so
/// nothing in this file can drift with the wall clock.
private let referenceNow = Date(timeIntervalSince1970: 1_700_000_000)

private func relativeLabel(secondsAgo: TimeInterval) -> String {
    SyncStatusPresentation.relativeTimeLabel(
        from: referenceNow.addingTimeInterval(-secondsAgo),
        to: referenceNow
    )
}

@Suite("Sync Status Relative Time Labels")
struct SyncStatusRelativeTimeTests {

    @Test("Anything under 45s reads 'just now'; 45s flips to minutes")
    func justNowBoundary() {
        #expect(relativeLabel(secondsAgo: 0) == "just now")
        #expect(relativeLabel(secondsAgo: 44) == "just now")
        #expect(relativeLabel(secondsAgo: 44.999) == "just now")
        #expect(relativeLabel(secondsAgo: 45) == "1m ago")
    }

    @Test("A future timestamp (clock skew) reads 'just now', never a negative age")
    func negativeIntervalIsJustNow() {
        #expect(relativeLabel(secondsAgo: -1) == "just now")
        #expect(relativeLabel(secondsAgo: -60) == "just now")
        #expect(relativeLabel(secondsAgo: -86_400) == "just now")
    }

    @Test("Sub-minute ages clamp up to '1m ago' rather than showing '0m ago'")
    func minuteFloorIsClampedToOne() {
        #expect(relativeLabel(secondsAgo: 59) == "1m ago")
        #expect(relativeLabel(secondsAgo: 60) == "1m ago")
        #expect(relativeLabel(secondsAgo: 119) == "1m ago")
        #expect(relativeLabel(secondsAgo: 120) == "2m ago")
    }

    @Test("Minutes give way to hours exactly at 3600s")
    func hourBoundary() {
        #expect(relativeLabel(secondsAgo: 3599) == "59m ago")
        #expect(relativeLabel(secondsAgo: 3600) == "1h ago")
        #expect(relativeLabel(secondsAgo: 7199) == "1h ago")
        #expect(relativeLabel(secondsAgo: 7200) == "2h ago")
    }

    @Test("Hours give way to days exactly at 86400s")
    func dayBoundary() {
        #expect(relativeLabel(secondsAgo: 86_399) == "23h ago")
        #expect(relativeLabel(secondsAgo: 86_400) == "1d ago")
        #expect(relativeLabel(secondsAgo: 2 * 86_400) == "2d ago")
    }

    @Test("Six days stays relative; seven days becomes an absolute date")
    func weekBoundarySwitchesToAbsoluteDate() {
        #expect(relativeLabel(secondsAgo: 7 * 86_400 - 1) == "6d ago")

        let atSevenDays = relativeLabel(secondsAgo: 7 * 86_400)
        #expect(atSevenDays.hasPrefix("on "))
        #expect(!atSevenDays.contains("ago"))
        #expect(atSevenDays.count > "on ".count)
    }

    @Test("The absolute label describes the original timestamp, not 'now'")
    func absoluteLabelUsesTheSourceDate() {
        // Two different old timestamps must not collapse to the same words.
        #expect(relativeLabel(secondsAgo: 7 * 86_400) != relativeLabel(secondsAgo: 60 * 86_400))
    }
}

@Suite("Sync Status Menu Line")
struct SyncStatusMenuLineTests {

    private func menuLine(_ health: SyncHealth, lastSync: Date?) -> String {
        SyncStatusPresentation.menuStatusLine(
            health: health,
            lastSuccessfulSyncAt: lastSync,
            now: referenceNow
        )
    }

    @Test("Healthy with a last-sync time appends the relative age")
    func okWithDate() {
        #expect(menuLine(.ok, lastSync: referenceNow.addingTimeInterval(-240)) == "Synced 4m ago")
        #expect(menuLine(.ok, lastSync: referenceNow.addingTimeInterval(-10)) == "Synced just now")
    }

    @Test("Healthy with no last-sync time is the bare label")
    func okWithoutDate() {
        #expect(menuLine(.ok, lastSync: nil) == "Synced")
    }

    @Test("Every non-healthy state falls back to the shared short label and ignores the last-sync time")
    func nonHealthyStatesUseShortLabelOnly() {
        let stale = referenceNow.addingTimeInterval(-3600)

        #expect(menuLine(.unknown, lastSync: stale) == "Checking iCloud…")
        #expect(menuLine(.unknown, lastSync: nil) == "Checking iCloud…")

        #expect(menuLine(.noAccount, lastSync: stale) == "Sign in to iCloud to sync")
        #expect(menuLine(.noAccount, lastSync: nil) == "Sign in to iCloud to sync")

        #expect(menuLine(.restricted, lastSync: stale) == "iCloud is restricted on this device")
        #expect(menuLine(.restricted, lastSync: nil) == "iCloud is restricted on this device")

        // The raw failure message never leaks into the menu line.
        #expect(menuLine(.failing("CKError 4097 connection interrupted"), lastSync: stale) == "Sync problem")
        #expect(menuLine(.failing("CKError 4097 connection interrupted"), lastSync: nil) == "Sync problem")
    }
}

@Suite("Sync Status Presentation")
struct SyncStatusPresentationTests {

    private func status(_ health: SyncHealth, lastSync: Date? = nil) -> SyncStatusPresentation {
        SyncStatusPresentation.status(
            health: health,
            lastSuccessfulSyncAt: lastSync,
            now: referenceNow
        )
    }

    private var fourMinutesAgo: Date { referenceNow.addingTimeInterval(-240) }

    @Test("Pre-flight 'unknown' is neutral, mentions the last sync, offers no action")
    func unknownIsNeutral() {
        let presentation = status(.unknown, lastSync: referenceNow.addingTimeInterval(-3600))

        #expect(presentation.symbolName == "icloud")
        #expect(presentation.severity == .neutral)
        #expect(presentation.title == "Checking iCloud…")
        #expect(presentation.detail == "Last synced 1h ago")
        #expect(presentation.showsICloudSettingsAction == false)

        #expect(status(.unknown).detail == nil)
    }

    @Test("Healthy is quiet, shows the last sync, offers no action")
    func okIsHealthy() {
        let presentation = status(.ok, lastSync: fourMinutesAgo)

        #expect(presentation.symbolName == "checkmark.icloud.fill")
        #expect(presentation.severity == .healthy)
        #expect(presentation.title == "Synced")
        #expect(presentation.detail == "Last synced 4m ago")
        #expect(presentation.showsICloudSettingsAction == false)

        // First-ever launch: healthy but nothing has landed yet.
        #expect(status(.ok).detail == nil)
    }

    @Test("Signed out is blocked and links to iCloud settings")
    func noAccountIsBlocked() {
        let presentation = status(.noAccount, lastSync: fourMinutesAgo)

        #expect(presentation.symbolName == "exclamationmark.icloud.fill")
        #expect(presentation.severity == .blocked)
        #expect(presentation.title == "Sign in to iCloud to sync")
        #expect(presentation.showsICloudSettingsAction == true)
        // The fix instructions replace the reassurance — no "Last synced" here,
        // even though a successful sync date was supplied.
        #expect(presentation.detail == SyncHealth.noAccount.detail)
        #expect(presentation.detail?.contains("Last synced") == false)
        #expect(status(.noAccount).detail == presentation.detail)
    }

    @Test("Managed restriction is blocked and links to iCloud settings")
    func restrictedIsBlocked() {
        let presentation = status(.restricted, lastSync: fourMinutesAgo)

        #expect(presentation.symbolName == "lock.icloud.fill")
        #expect(presentation.severity == .blocked)
        #expect(presentation.title == "iCloud is restricted on this device")
        #expect(presentation.showsICloudSettingsAction == true)
        #expect(presentation.detail == SyncHealth.restricted.detail)
        #expect(presentation.detail?.contains("Last synced") == false)
        #expect(status(.restricted).detail == presentation.detail)
    }

    @Test("A transient failure stays quiet, keeps the last-success reassurance, offers no action")
    func failingIsAttentionNotBlocked() {
        let presentation = status(.failing("Couldn't reach iCloud"), lastSync: fourMinutesAgo)

        #expect(presentation.symbolName == "arrow.triangle.2.circlepath.icloud")
        #expect(presentation.severity == .attention)
        #expect(presentation.title == "Sync problem")
        #expect(presentation.detail == "Couldn't reach iCloud · Last synced 4m ago")
        #expect(presentation.showsICloudSettingsAction == false)
    }

    @Test("A failure with no prior success shows only the failure message")
    func failingWithoutLastSyncShowsMessageOnly() {
        #expect(status(.failing("Couldn't reach iCloud")).detail == "Couldn't reach iCloud")
    }

    @Test("A failure carrying an empty message yields an empty detail, not nil")
    func failingWithEmptyMessageYieldsEmptyDetail() {
        // Documents current behaviour: `SyncHealth.failing("")` is non-nil, so
        // the `parts.isEmpty` guard never fires and the UI gets "" rather than
        // no detail at all. Harmless today (an empty row), but if a caller ever
        // publishes a blank message this is where it surfaces.
        #expect(status(.failing("")).detail == "")
        #expect(status(.failing(""), lastSync: fourMinutesAgo).detail == " · Last synced 4m ago")
    }
}

@Suite("Sync Status Pending Count Phrases")
struct SyncStatusCountPhraseTests {

    @Test("Pending-changes phrase hides at zero and pluralises above one")
    func pendingChangesPhrase() {
        #expect(SyncStatusPresentation.pendingChangesPhrase(count: 0) == nil)
        #expect(SyncStatusPresentation.pendingChangesPhrase(count: -3) == nil)
        #expect(SyncStatusPresentation.pendingChangesPhrase(count: 1) == "1 change waiting to upload")
        #expect(SyncStatusPresentation.pendingChangesPhrase(count: 2) == "2 changes waiting to upload")
        #expect(SyncStatusPresentation.pendingChangesPhrase(count: 42) == "42 changes waiting to upload")
    }
}
