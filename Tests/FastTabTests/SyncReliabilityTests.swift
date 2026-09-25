import Testing
import Foundation
@testable import FastTab
import FastTabSync

private enum SyncDelegateCallbackContext {
    @TaskLocal static var isActive = false
}

private actor SyncSendProbe {
    struct Snapshot {
        let delegateContextValues: [Bool]
        let maximumConcurrentSends: Int
    }

    private var delegateContextValues: [Bool] = []
    private var activeSendCount = 0
    private var maximumConcurrentSends = 0
    private var firstSendStarted = false
    private var firstSendContinuation: CheckedContinuation<Void, Never>?

    func send() async {
        activeSendCount += 1
        maximumConcurrentSends = max(maximumConcurrentSends, activeSendCount)
        delegateContextValues.append(SyncDelegateCallbackContext.isActive)

        if !firstSendStarted {
            firstSendStarted = true
            await withCheckedContinuation { continuation in
                firstSendContinuation = continuation
            }
        }

        activeSendCount -= 1
    }

    func waitForFirstSendToStart() async {
        while !firstSendStarted {
            await Task.yield()
        }
    }

    func releaseFirstSend() {
        firstSendContinuation?.resume()
        firstSendContinuation = nil
    }

    func snapshot() -> Snapshot {
        Snapshot(
            delegateContextValues: delegateContextValues,
            maximumConcurrentSends: maximumConcurrentSends
        )
    }
}

@Suite("Sync Reliability")
struct SyncReliabilityTests {
    @Test("Sync sends detach from delegate callbacks and coalesce overlapping requests")
    func syncSendsDetachAndSerialize() async {
        let probe = SyncSendProbe()
        let coordinator = SyncSendCoordinator {
            await probe.send()
        }

        await SyncDelegateCallbackContext.$isActive.withValue(true) {
            await coordinator.requestSend()
        }
        await probe.waitForFirstSendToStart()

        for _ in 0..<20 {
            await coordinator.requestSend()
        }

        await probe.releaseFirstSend()
        await coordinator.waitUntilIdle()

        let snapshot = await probe.snapshot()
        #expect(snapshot.delegateContextValues == [false, false])
        #expect(snapshot.maximumConcurrentSends == 1)
    }

    @Test("Source-scoped fetch cannot replace authoritative all-browser tabs")
    func scopedFetchPreservesOtherBrowsers() {
        let chrome = BrowserSearchResult(
            title: "Chrome",
            url: "https://chrome.example",
            browserName: "Google Chrome",
            type: .tab,
            timestamp: Date(),
            tabID: 1
        )
        let safari = BrowserSearchResult(
            title: "Safari",
            url: "https://safari.example",
            browserName: "Safari",
            type: .tab,
            timestamp: Date(),
            tabID: 2
        )
        var snapshot = AuthoritativeLiveTabSnapshot()

        snapshot.applyAllBackends([chrome, safari])
        snapshot.observeScopedFetch([chrome])

        #expect(snapshot.isHydrated)
        #expect(Set(snapshot.tabs.map(\.browserName)) == ["Google Chrome", "Safari"])
    }

    @Test("Completed command response survives journal reinitialization")
    func commandResultOutboxRestoresAfterCrash() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("command-journal.json")
        let pending = SyncCommand(
            id: "close_once",
            kind: .closeTab,
            targetDeviceID: "mac",
            sourceDeviceName: "iPhone",
            payloadJSON: "{}"
        )
        var completed = pending
        completed.status = .done
        completed.statusReason = "Tab closed on Mac"
        completed.completedAt = Date()

        let firstProcess = SyncCommandJournal(fileURL: fileURL)
        try firstProcess.markExecuting(pending)
        try firstProcess.storeCompletedResponse(completed)

        let relaunchedProcess = SyncCommandJournal(fileURL: fileURL)

        #expect(relaunchedProcess.completedResponses == [completed])
    }

    @Test("Duplicate pending close uses durable executing or completed state")
    func duplicatePendingCommandDecision() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-journal.json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let pending = SyncCommand(
            id: "duplicate_close",
            kind: .closeTab,
            targetDeviceID: "mac",
            sourceDeviceName: "iPhone",
            payloadJSON: "{}"
        )
        let journal = SyncCommandJournal(fileURL: fileURL)

        #expect(journal.decision(for: pending) == .execute)

        try journal.markExecuting(pending)
        #expect(journal.decision(for: pending) == .reconcileExecuting(pending))

        var completed = pending
        completed.status = .done
        completed.completedAt = Date()
        try journal.storeCompletedResponse(completed)
        #expect(journal.decision(for: pending) == .resendCompleted(completed))
    }
}
