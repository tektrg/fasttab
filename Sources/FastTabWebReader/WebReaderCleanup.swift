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

    /// Runs the cleanup if pending. `finalPoll` must throw when the inbox could not be drained.
    /// Returns true when the server is clean (flag cleared); false keeps the flag for a retry.
    @discardableResult
    public func runIfPending(api: any WebReaderAPI, finalPoll: () async throws -> Void) async -> Bool {
        guard isPending else { return true }
        do {
            try await finalPoll()
            guard isPending else { return false } // re-enabled meanwhile
            for device in try await api.devices() where device.isWebBrowser && device.app == "fasttab" {
                try await api.removeDevice(id: device.id)
            }
            guard isPending else { return false }
            try await api.deleteSnapshot()
            cancel()
            return true
        } catch {
            return false
        }
    }
}
