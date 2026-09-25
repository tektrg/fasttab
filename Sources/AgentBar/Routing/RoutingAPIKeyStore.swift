import Foundation
import Security

/// Stores the OpenRouter API key used by Jev message routing. The key is a secret and never
/// lives in `UserDefaults` (see `RoutingSettings`, which holds only the non-secret prefs).
/// Never log or print the value this returns.
protocol RoutingAPIKeyStoring: Sendable {
    /// The stored key, or nil if none is set.
    func get() -> String?
    /// Sets the key. `nil`, or a string that is empty or only whitespace, deletes it instead.
    func set(_ key: String?) throws
}

enum RoutingAPIKeyStoreError: Error, LocalizedError {
    case unhandledStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unhandledStatus(let status):
            return "Keychain returned status \(status)."
        }
    }
}

/// Keychain-backed store for the Jev/OpenRouter API key, scoped to AgentBar's own routing
/// feature — a separate service string from FastTab's license Keychain item
/// (`Sources/FastTab/LicenseStorage.swift`) and from AgentBar's `UserDefaults`-backed settings.
final class KeychainRoutingAPIKeyStore: RoutingAPIKeyStoring, @unchecked Sendable {
    private let service = "com.trungluong.AgentBar.routing"
    private let account = "openrouterApiKey"

    func get() -> String? {
        var query = baseQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func set(_ key: String?) throws {
        guard let key, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            try delete()
            return
        }
        guard let data = key.data(using: .utf8) else { return }

        var addQuery = baseQuery()
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            let update: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else { throw RoutingAPIKeyStoreError.unhandledStatus(updateStatus) }
            return
        }
        guard addStatus == errSecSuccess else { throw RoutingAPIKeyStoreError.unhandledStatus(addStatus) }
    }

    private func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw RoutingAPIKeyStoreError.unhandledStatus(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
