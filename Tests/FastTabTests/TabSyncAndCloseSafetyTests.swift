import Foundation
import AppKit
import Testing
@testable import FastTab

struct TabSyncAndCloseSafetyTests {
    @Test func closeScriptDoesNotContainBlindPositionalFallback() {
        let script = ChromiumBackend.buildCloseTabScript(
            appName: "Microsoft Edge",
            url: "https://example.com/target",
            fallbackWindow: 1,
            fallbackTab: 2,
            allowPositionalFallback: false
        )
        // Must NOT contain unconditional close of fallbackTab
        #expect(!script.contains("close tab 2 of window 1"))
        #expect(script.contains("return \"not_found\""))
    }

    @Test func safariCloseScriptDoesNotContainBlindPositionalFallback() {
        let script = SafariBackend.buildCloseTabScript(
            appName: "Safari",
            url: "https://example.com/target",
            fallbackWindow: 1,
            fallbackTab: 2,
            allowPositionalFallback: false
        )
        #expect(!script.contains("close tab 2 of window 1"))
        #expect(script.contains("return \"not_found\""))
    }

    @Test func tabRecencyPreservedAcrossTabPositionShift() {
        let baselinePositionalKey = makeTabRecencyKey(
            browserName: "Microsoft Edge",
            windowIndex: 1,
            tabIndex: 5,
            url: "https://example.com/page"
        )
        let urlKey = makeTabURLRecencyKey(
            browserName: "Microsoft Edge",
            url: "https://example.com/page"
        )

        let visitedAt = Date(timeIntervalSince1970: 1700000000)
        let activeTimes: [String: Date] = [
            baselinePositionalKey: visitedAt,
            urlKey: visitedAt
        ]

        // Now tab moves to index 4 because another tab was closed
        let newPositionalKey = makeTabRecencyKey(
            browserName: "Microsoft Edge",
            windowIndex: 1,
            tabIndex: 4,
            url: "https://example.com/page"
        )

        // Positional lookup fails for new index
        #expect(activeTimes[newPositionalKey] == nil)

        // Fallback lookup by URL recovers the exact timestamp
        let resolved = activeTimes[newPositionalKey] ?? activeTimes[urlKey]
        #expect(resolved == visitedAt)
    }

    @Test func browserCloseWithoutPendingIntentVanishesSlot() {
        let tabA = BrowserSearchResult(
            title: "A",
            url: "https://a.com",
            browserName: "Microsoft Edge",
            type: .tab,
            timestamp: Date(),
            windowIndex: 1,
            tabIndex: 1
        )
        let tabB = BrowserSearchResult(
            title: "B",
            url: "https://b.com",
            browserName: "Microsoft Edge",
            type: .tab,
            timestamp: Date(),
            windowIndex: 1,
            tabIndex: 2
        )

        let initial = MyOrderReconciler.reconcile(
            currentSlots: [],
            liveTabs: [tabA, tabB],
            runningBrowsers: ["Microsoft Edge"],
            pendingCloses: []
        )
        #expect(initial.slots.count == 2)

        // Tab A was closed directly in Edge (not via FastTab pendingCloses)
        let afterBrowserClose = MyOrderReconciler.reconcile(
            currentSlots: initial.slots,
            liveTabs: [tabB],
            runningBrowsers: ["Microsoft Edge"],
            pendingCloses: []
        )

        // Tab A MUST vanish completely (not become a ghost!)
        #expect(afterBrowserClose.slots.count == 1)
        #expect(afterBrowserClose.slots[0].title == "B")
        #expect(afterBrowserClose.slots[0].state == .live)
    }

    @Test func settingTimestampPreservesAllMetadata() {
        let original = BrowserSearchResult(
            title: "Test Tab",
            url: "https://example.com/item",
            browserName: "Microsoft Edge",
            type: .tab,
            timestamp: Date(timeIntervalSince1970: 0),
            windowIndex: 2,
            tabIndex: 7,
            windowName: "Edge Window",
            isCurrentFlowActiveTab: false,
            hasMediaIndicator: true,
            tabID: 99,
            tabGroupTitle: "Work"
        )
        let newDate = Date(timeIntervalSince1970: 1725430000)
        let updated = original.settingTimestamp(newDate)

        #expect(updated.timestamp == newDate)
        #expect(updated.title == original.title)
        #expect(updated.url == original.url)
        #expect(updated.browserName == original.browserName)
        #expect(updated.type == original.type)
        #expect(updated.windowIndex == original.windowIndex)
        #expect(updated.tabIndex == original.tabIndex)
        #expect(updated.tabID == original.tabID)
        #expect(updated.windowName == original.windowName)
        #expect(updated.isCurrentFlowActiveTab == original.isCurrentFlowActiveTab)
        #expect(updated.hasMediaIndicator == original.hasMediaIndicator)
        #expect(updated.tabGroupTitle == original.tabGroupTitle)
    }

    @Test func tabURLRecencyKeyMatchesFormat() {
        let tab = BrowserSearchResult(
            title: "Test Tab",
            url: "https://example.com/test",
            browserName: "Google Chrome",
            type: .tab,
            timestamp: Date()
        )
        #expect(tab.tabURLRecencyKey == "Google Chrome|https://example.com/test")
    }

    @Test func closeScriptChecksExactIndexBeforeScanAndHandlesDuplicates() {
        let scriptLocal = ChromiumBackend.buildCloseTabScript(
            appName: "Microsoft Edge",
            url: "https://example.com/target",
            fallbackWindow: 1,
            fallbackTab: 3,
            allowPositionalFallback: true
        )
        // Must check exact index URL first
        #expect(scriptLocal.contains("if (item 3 of tabURLs) is equal to targetURL then"))
        #expect(scriptLocal.contains("close tab 3 of w"))
        // When allowPositionalFallback is true, must NOT refuse ambiguous duplicates
        #expect(!scriptLocal.contains("refused:ambiguous"))

        let scriptRemote = ChromiumBackend.buildCloseTabScript(
            appName: "Microsoft Edge",
            url: "https://example.com/target",
            fallbackWindow: 1,
            fallbackTab: 1,
            allowPositionalFallback: false
        )
        // For blind remote commands, ambiguous duplicates are safely refused
        #expect(scriptRemote.contains("refused:ambiguous"))
    }

    @Test func safariCloseScriptChecksExactIndexBeforeScanAndHandlesDuplicates() {
        let scriptLocal = SafariBackend.buildCloseTabScript(
            appName: "Safari",
            url: "https://example.com/target",
            fallbackWindow: 2,
            fallbackTab: 4,
            allowPositionalFallback: true
        )
        #expect(scriptLocal.contains("if thisURL is equal to targetURL then"))
        #expect(scriptLocal.contains("close tab 4 of w"))
        #expect(!scriptLocal.contains("refused:ambiguous"))

        let scriptRemote = SafariBackend.buildCloseTabScript(
            appName: "Safari",
            url: "https://example.com/target",
            fallbackWindow: 1,
            fallbackTab: 1,
            allowPositionalFallback: false
        )
        #expect(scriptRemote.contains("refused:ambiguous"))
    }

    @Test func finderCloseScriptTargetsWindowIDWhenAvailable() {
        let script = FinderBackend.buildCloseTabScript(
            path: "/Users/test/Desktop",
            targetTabID: 438,
            fallbackWindow: 1,
            allowPositionalFallback: true
        )
        #expect(script.contains("close Finder window id 438"))
        #expect(script.contains("return \"closed\""))
    }

    @Test func finderCloseScriptHandlesDuplicatesWhenPositionalAllowed() {
        let scriptLocal = FinderBackend.buildCloseTabScript(
            path: "/Users/test/Desktop",
            targetTabID: nil,
            fallbackWindow: 1,
            allowPositionalFallback: true
        )
        // Must NOT refuse duplicate folder windows when allowPositionalFallback is true
        #expect(!scriptLocal.contains("refused:ambiguous"))
        #expect(scriptLocal.contains("close item matchedWin of theWindows"))

        let scriptRemote = FinderBackend.buildCloseTabScript(
            path: "/Users/test/Desktop",
            targetTabID: nil,
            fallbackWindow: 1,
            allowPositionalFallback: false
        )
        // Blind remote close without tabID must refuse ambiguous duplicates
        #expect(scriptRemote.contains("refused:ambiguous"))
    }

    @Test func finderCloseScriptNormalizesTrailingSlashes() {
        let script = FinderBackend.buildCloseTabScript(
            path: "/Users/test/Desktop",
            targetTabID: nil,
            fallbackWindow: 1,
            allowPositionalFallback: true
        )
        // Must check slash variants so /Desktop and /Desktop/ match
        #expect(script.contains("(p is equal to targetPath)"))
        #expect(script.contains("((p & \"/\") is equal to targetPath)"))
    }

    @Test func extensionBackedBackendRecoversTimestampViaURLKey() {
        let urlKey = makeTabURLRecencyKey(browserName: "Google Chrome", url: "https://example.com/restored")
        let savedTime = Date(timeIntervalSince1970: 1720000000)
        let activeTimes: [String: Date] = [urlKey: savedTime]

        // When tab is restored from previous session (not in view.activationTimes and shifted index)
        let positionalKey = makeTabRecencyKey(browserName: "Google Chrome", windowIndex: 1, tabIndex: 10, url: "https://example.com/restored")
        #expect(activeTimes[positionalKey] == nil)
        let resolvedTime = activeTimes[positionalKey] ?? activeTimes[urlKey]
        #expect(resolvedTime == savedTime)
    }

    @Test func liveDiagnosisEdgeTabs() {
        let backend = ChromiumBackend(
            appName: "Microsoft Edge",
            bundleIdentifier: "com.microsoft.edgemac",
            supportDirectory: "~/Library/Application Support/Microsoft Edge"
        )
        var activeTimes: [String: Date] = [:]
        let appleScriptTabs = backend.fetchLiveTabs(fetchStart: Date(), activeTimes: &activeTimes, currentFlowSourceAppBundleIdentifier: nil)
        print("DIAG_RESULT: AppleScript live tabs count = \(appleScriptTabs.count)")
        let profiles = backend.profiles()
        print("DIAG_RESULT: profiles count = \(profiles.count), names = \(profiles.map(\.name))")
        let living = backend.livingProfileNames()
        print("DIAG_RESULT: livingProfileNames = \(String(describing: living))")
        let isEdgeRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.microsoft.edgemac").isEmpty
        if isEdgeRunning {
            #expect(appleScriptTabs.count > 0)
        }
    }

    @Test func liveDiagnosisFinderTabs() {
        let backend = FinderBackend()
        var activeTimes: [String: Date] = [:]
        let tabs = backend.fetchLiveTabs(fetchStart: Date(), activeTimes: &activeTimes, currentFlowSourceAppBundleIdentifier: nil)
        print("DIAG_FINDER: live tabs count = \(tabs.count)")
        for t in tabs {
            print("DIAG_FINDER_TAB: title='\(t.title)' url='\(t.url)' tabID=\(String(describing: t.tabID)) winIndex=\(String(describing: t.windowIndex))")
        }
        #expect(tabs.count > 0)
    }

    @Test func liveCloseTemporaryFinderWindow() {
        let scriptOpen = "tell application \"Finder\" to open POSIX file \"/private/tmp\""
        _ = runProcess(launchPath: "/usr/bin/osascript", arguments: ["-e", scriptOpen])
        Thread.sleep(forTimeInterval: 0.5)

        let backend = FinderBackend()
        var activeTimes: [String: Date] = [:]
        let tabs = backend.fetchLiveTabs(fetchStart: Date(), activeTimes: &activeTimes, currentFlowSourceAppBundleIdentifier: nil)
        guard let tmpTab = tabs.first(where: { $0.url == "/private/tmp/" || $0.url == "/private/tmp" }) else {
            Issue.record("Failed to find tmp window in live tabs")
            return
        }
        print("Closing tmp window: tabID=\(String(describing: tmpTab.tabID)) winIndex=\(String(describing: tmpTab.windowIndex))")
        let closeResult = backend.closeTabWithResult(tmpTab, allowPositionalFallback: true)
        print("Close result: \(closeResult)")
        #expect(closeResult == .closed)
    }

    @Test func liveCloseTemporaryFinderWindowWithoutTabID() {
        let scriptOpen = "tell application \"Finder\" to open POSIX file \"/private/var/tmp\""
        _ = runProcess(launchPath: "/usr/bin/osascript", arguments: ["-e", scriptOpen])
        Thread.sleep(forTimeInterval: 0.5)

        let backend = FinderBackend()
        var activeTimes: [String: Date] = [:]
        let tabs = backend.fetchLiveTabs(fetchStart: Date(), activeTimes: &activeTimes, currentFlowSourceAppBundleIdentifier: nil)
        guard let tmpTab = tabs.first(where: { $0.url.contains("var/tmp") }) else {
            Issue.record("Failed to find var/tmp window in live tabs")
            return
        }
        // Strip tabID to force positional/path fallback
        let fallbackTab = BrowserSearchResult(
            title: tmpTab.title,
            url: tmpTab.url,
            browserName: tmpTab.browserName,
            type: tmpTab.type,
            timestamp: tmpTab.timestamp,
            windowIndex: tmpTab.windowIndex,
            tabIndex: tmpTab.tabIndex,
            windowName: tmpTab.windowName,
            tabID: nil
        )
        let closeResult = backend.closeTabWithResult(fallbackTab, allowPositionalFallback: true)
        #expect(closeResult == .closed)
    }
}

