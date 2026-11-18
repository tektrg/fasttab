import SwiftUI
import Testing
import IndieUpdate
@testable import FastTab

/// Fast Tab's update banner after the move to IndieLibKit's `IndieUpdate`: the same words, icons,
/// buttons and close rules the app's own `updateBannerConfig` had (deleted with the move).
@MainActor
struct UpdateBannerTests {
    private func banner(_ status: UpdateStatus) -> UpdateBannerConfig? {
        UpdateService.bannerConfig(for: status)
    }

    @Test func noBannerWhileIdleCheckingOrUpToDate() {
        #expect(banner(.idle) == nil)
        #expect(banner(.checking) == nil)
        #expect(banner(.upToDate) == nil)
    }

    @Test func availableNamesFastTabAndAppendsNotes() throws {
        let withNotes = try #require(banner(.available(version: "1.7.0", releaseNotes: "Faster search.")))
        #expect(withNotes.message == "FastTab 1.7.0 is available. Faster search.")
        #expect(withNotes.actionTitle == "Update")
        #expect(withNotes.icon == "arrow.down.circle.fill")
        #expect(withNotes.tint == .blue)
        #expect(withNotes.dismissable)
        #expect(banner(.available(version: "1.7.0", releaseNotes: nil))?.message == "FastTab 1.7.0 is available.")
    }

    @Test func downloadAndPrepareCannotBeClosed() throws {
        let downloading = try #require(banner(.downloading(progress: 0.426)))
        #expect(downloading.message == "Downloading update... 43%")
        #expect(downloading.actionTitle == "Cancel")
        #expect(downloading.icon == "arrow.down.circle")
        #expect(!downloading.dismissable)
        let extracting = try #require(banner(.extracting(progress: 0.5)))
        #expect(extracting.message == "Preparing update...")
        #expect(extracting.actionTitle == "Cancel")
        #expect(!extracting.dismissable)
    }

    @Test func readyInstallingAndError() throws {
        let ready = try #require(banner(.readyToRestart(version: "1.7.0")))
        #expect(ready.message == "FastTab 1.7.0 is ready.")
        #expect(ready.actionTitle == "Restart to Update")
        #expect(ready.icon == "arrow.triangle.2.circlepath.circle.fill")
        #expect(ready.tint == .green)
        #expect(ready.dismissable)
        let installing = try #require(banner(.installing))
        #expect(installing.message == "Installing update...")
        #expect(installing.actionTitle == "Installing")
        #expect(!installing.dismissable)
        let failed = try #require(banner(.error("No network")))
        #expect(failed.message == "Update failed: No network")
        #expect(failed.actionTitle == "Retry")
        #expect(failed.icon == "exclamationmark.triangle.fill")
        #expect(failed.tint == .orange)
        #expect(failed.dismissable)
    }

    @Test func updaterKeepsFastTabsLoggerSubsystem() {
        #expect(UpdateService.loggerSubsystem == "com.trungluong.FastTab")
    }
}
