import Foundation
import Security

@MainActor
protocol LicenseStorage {
    func loadTrial() throws -> TrialRecord?
    func saveTrial(_ trial: TrialRecord) throws
    func loadLicense() throws -> StoredLicense?
    func saveLicense(_ license: StoredLicense) throws
    func deleteLicense() throws
    func loadDeviceIdentity() throws -> DeviceActivationIdentity?
    func saveDeviceIdentity(_ identity: DeviceActivationIdentity) throws
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

@MainActor
final class KeychainLicenseStorage: LicenseStorage {
    static let shared = KeychainLicenseStorage()

    private let service = "com.trungluong.FastTab.payment"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func loadTrial() throws -> TrialRecord? {
        try load(TrialRecord.self, account: "trial")
    }

    func saveTrial(_ trial: TrialRecord) throws {
        try save(trial, account: "trial")
    }

    func loadLicense() throws -> StoredLicense? {
        try load(StoredLicense.self, account: "license")
    }

    func saveLicense(_ license: StoredLicense) throws {
        try save(license, account: "license")
    }

    func deleteLicense() throws {
        try delete(account: "license")
    }

    func loadDeviceIdentity() throws -> DeviceActivationIdentity? {
        try load(DeviceActivationIdentity.self, account: "device")
    }

    func saveDeviceIdentity(_ identity: DeviceActivationIdentity) throws {
        try save(identity, account: "device")
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
