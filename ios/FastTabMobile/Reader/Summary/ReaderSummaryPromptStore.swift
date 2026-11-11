import Foundation
import Observation

/// The slice of iCloud key-value storage the store needs (a fake in tests).
protocol PromptCloudStorage: AnyObject {
    func promptData(forKey key: String) -> Data?
    func setPromptData(_ data: Data?, forKey key: String)
}

extension NSUbiquitousKeyValueStore: PromptCloudStorage {
    func promptData(forKey key: String) -> Data? { data(forKey: key) }
    func setPromptData(_ data: Data?, forKey key: String) {
        if let data { set(data, forKey: key) } else { removeObject(forKey: key) }
        synchronize()
    }
}

/// The person's custom Summary prompt: saved on this iPhone and mirrored through iCloud so it
/// follows them to other devices. Last writer wins on `updatedAt`; a reset is a write too, so it
/// syncs. Without iCloud (signed out, tests) it quietly stays local.
@MainActor
@Observable
final class ReaderSummaryPromptStore {
    static let shared = ReaderSummaryPromptStore(local: .standard, cloud: NSUbiquitousKeyValueStore.default)

    static let defaultsKey = "FastTabMobile.readerSummaryPromptV1"
    static let cloudKey = "readerSummaryPromptV1"

    struct Setting: Codable, Equatable {
        /// nil = the server's default prompt.
        var instruction: String?
        var updatedAt: Date
    }

    private(set) var setting: Setting

    /// What `ReaderSummaryModel` sends: nil = default.
    var customInstruction: String? { setting.instruction }

    @ObservationIgnored private let local: UserDefaults
    @ObservationIgnored private let cloud: PromptCloudStorage?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private nonisolated(unsafe) var cloudObserver: NSObjectProtocol?

    init(local: UserDefaults, cloud: PromptCloudStorage?, now: @escaping () -> Date = { Date() }) {
        self.local = local
        self.cloud = cloud
        self.now = now
        setting = Self.decode(local.data(forKey: Self.defaultsKey)) ?? Setting(instruction: nil, updatedAt: .distantPast)
        mergeFromCloud()
        if cloud != nil {
            cloudObserver = NotificationCenter.default.addObserver(
                forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.mergeFromCloud() }
            }
        }
    }

    deinit {
        if let cloudObserver { NotificationCenter.default.removeObserver(cloudObserver) }
    }

    /// Saves what was typed (blank or the default text = back to default). Over the server's
    /// limit is refused and nothing changes.
    func save(instruction: String?) {
        let text = instruction ?? ""
        guard ReaderSummaryPrompt.length(of: text) <= ReaderSummaryPrompt.maxInstructionLength else { return }
        let normalized = ReaderSummaryPrompt.normalized(text)
        guard normalized != setting.instruction else { return } // no change: don't bump the sync clock
        commit(normalized)
    }

    /// Back to the default. Does nothing (and doesn't touch iCloud) when it already is.
    func reset() {
        guard setting.instruction != nil else { return }
        commit(nil)
    }

    /// Takes the iCloud copy when it is newer than this device's; pushes this device's when that is newer.
    func mergeFromCloud() {
        let remote = Self.decode(cloud?.promptData(forKey: Self.cloudKey))
        if let remote, remote.updatedAt > setting.updatedAt {
            setting = remote
            persistLocal()
        } else if cloud != nil, setting.updatedAt > .distantPast, remote.map({ setting.updatedAt > $0.updatedAt }) ?? true {
            // A write made while iCloud was unavailable never reached it; send it now.
            cloud?.setPromptData(Self.encode(setting), forKey: Self.cloudKey)
        }
    }

    private func commit(_ instruction: String?) {
        // Never earlier than what this device already holds: a device with a fast clock must not
        // lock the others out of editing (last writer wins by timestamp).
        let stamp = max(now(), setting.updatedAt.addingTimeInterval(0.001))
        setting = Setting(instruction: instruction, updatedAt: stamp)
        persistLocal()
        cloud?.setPromptData(Self.encode(setting), forKey: Self.cloudKey)
    }

    private func persistLocal() { local.set(Self.encode(setting), forKey: Self.defaultsKey) }

    private static func encode(_ setting: Setting) -> Data? { try? JSONEncoder().encode(setting) }

    private static func decode(_ data: Data?) -> Setting? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(Setting.self, from: data)
    }
}
