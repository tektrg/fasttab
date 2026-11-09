import Foundation

/// Server cleanup when the Web Reader toggle goes off (contract: "Turning it off").
/// Order: final inbox poll (import + ack, so no web highlight is lost) → unpair every
/// `fasttab` web device (kills their sessions server-side) → DELETE the snapshot.
/// A persisted "pending" flag survives failures; it is retried until one run succeeds.
@MainActor
public final class WebReaderCleanup {
    public static let pendingDefaultsKey = "FastTab.experimental.webReader.pendingServerCleanup"

    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var isPending: Bool { defaults.bool(forKey: Self.pendingDefaultsKey) }

    /// Toggle off: mark pending before any network call.
    public func markPending() { defaults.set(true, forKey: Self.pendingDefaultsKey) }

    /// Toggle back on: the user wants the web copy again; drop the cleanup without deleting.
    public func cancel() { defaults.removeObject(forKey: Self.pendingDefaultsKey) }

    public enum Outcome: Equatable {
        /// Server clean, flag cleared.
        case clean
        /// Network/server error; flag kept for a retry.
        case failed
        /// Re-enabled mid-run. `touchedServer`: browsers were unpaired or the snapshot deleted,
        /// so the caller must reset its upload ledger before uploading again.
        case interrupted(touchedServer: Bool)
    }

    /// Runs the cleanup if pending. `finalPoll` must throw when the inbox could not be drained.
    public func run(api: any WebReaderAPI, finalPoll: () async throws -> Void) async -> Outcome {
        guard isPending else { return .clean }
        var touched = false
        do {
            try await finalPoll()
            guard isPending else { return .interrupted(touchedServer: false) }
            for device in try await api.devices() where device.isWebBrowser && device.app == "fasttab" {
                touched = true
                try await api.removeDevice(id: device.id)
            }
            guard isPending else { return .interrupted(touchedServer: touched) }
            touched = true
            try await api.deleteSnapshot()
            guard isPending else { return .interrupted(touchedServer: true) }
            cancel()
            return .clean
        } catch {
            return isPending ? .failed : .interrupted(touchedServer: touched)
        }
    }

    /// Bool form: true when the server is clean.
    @discardableResult
    public func runIfPending(api: any WebReaderAPI, finalPoll: () async throws -> Void) async -> Bool {
        await run(api: api, finalPoll: finalPoll) == .clean
    }
}
