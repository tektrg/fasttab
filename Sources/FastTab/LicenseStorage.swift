import Foundation
import Security

protocol LicenseStorage: Sendable {
    func loadTrial() async throws -> TrialRecord?
    func saveTrial(_ trial: TrialRecord) async throws
    func loadLicense() async throws -> StoredLicense?
    func saveLicense(_ license: StoredLicense) async throws
    func deleteLicense() async throws
    func loadDeviceIdentity() async throws -> DeviceActivationIdentity?
    func saveDeviceIdentity(_ identity: DeviceActivationIdentity) async throws
}

enum LicenseStorageError: Error, LocalizedError {
    case unhandledStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unhandledStatus(let status):
            return "Keychain returned status \(status)."
        }
    }
}

final class KeychainLicenseStorage: LicenseStorage, @unchecked Sendable {
    static let shared = KeychainLicenseStorage()

    private let service = "com.trungluong.FastTab.payment"
    private let queue = DispatchQueue(label: "com.trungluong.FastTab.license-keychain")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func loadTrial() async throws -> TrialRecord? {
        try await perform { try self.load(TrialRecord.self, account: "trial") }
    }

    func saveTrial(_ trial: TrialRecord) async throws {
        try await perform { try self.save(trial, account: "trial") }
    }

    func loadLicense() async throws -> StoredLicense? {
        try await perform { try self.load(StoredLicense.self, account: "license") }
    }

    func saveLicense(_ license: StoredLicense) async throws {
        try await perform { try self.save(license, account: "license") }
    }

    func deleteLicense() async throws {
        try await perform { try self.delete(account: "license") }
    }

    func loadDeviceIdentity() async throws -> DeviceActivationIdentity? {
        try await perform { try self.load(DeviceActivationIdentity.self, account: "device") }
    }

    func saveDeviceIdentity(_ identity: DeviceActivationIdentity) async throws {
        try await perform { try self.save(identity, account: "device") }
    }

    private func perform<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try operation() })
            }
        }
    }

    private func load<T: Decodable>(_ type: T.Type, account: String) throws -> T? {
        var query = baseQuery(account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw LicenseStorageError.unhandledStatus(status) }
        guard let data = item as? Data else { return nil }
        return try decoder.decode(T.self, from: data)
    }

    private func save<T: Encodable>(_ value: T, account: String) throws {
        let data = try encoder.encode(value)
        var query = baseQuery(account: account)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        query[kSecValueData as String] = data

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(baseQuery(account: account) as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else { throw LicenseStorageError.unhandledStatus(updateStatus) }
            return
        }
        guard status == errSecSuccess else { throw LicenseStorageError.unhandledStatus(status) }
    }

    private func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw LicenseStorageError.unhandledStatus(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
