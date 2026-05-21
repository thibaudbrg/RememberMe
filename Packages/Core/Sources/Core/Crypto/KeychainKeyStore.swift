import Foundation
import Security

/// `KeyStore` that persists the database key in the iOS / macOS Keychain.
///
/// Storage attributes:
/// - `kSecClass = kSecClassGenericPassword`
/// - `kSecAttrService = <service>` (defaults to `"RememberMe.DB"`)
/// - `kSecAttrAccount = <account>` (defaults to `"primary"`)
/// - `kSecAttrAccessible = kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
/// - `kSecAttrSynchronizable = false`
///
/// `WhenUnlocked` means the key is unreadable while the device is locked. Pairs with
/// `NSFileProtectionComplete` on the DB file. Tradeoff is documented in SECURITY.md.
public final class KeychainKeyStore: KeyStore, @unchecked Sendable {
    public let service: String
    public let account: String

    public init(service: String = "RememberMe.DB", account: String = "primary") {
        self.service = service
        self.account = account
    }

    public func getOrCreateKey() throws -> DatabaseKey {
        if let existing = try fetchKey() {
            return existing
        }
        let fresh = try DatabaseKey(rawBytes: SecureRandom.bytes(DatabaseKey.lengthInBytes))
        try storeKey(fresh)
        return fresh
    }

    public func deleteKey() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        // errSecItemNotFound is fine — caller asked us to delete; it's already gone.
        if status != errSecSuccess, status != errSecItemNotFound {
            throw KeyStoreError.keychainOperationFailed(status: status)
        }
    }

    // MARK: - Internals

    private func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
        // On iOS, opting into the Data Protection Keychain avoids the simulator falling back to
        // a legacy code path that wants `keychain-access-groups` entitlements. On macOS this
        // setting forces the iOS-style keychain, which CLI tests (no entitlements) can't access.
        #if os(iOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    private func fetchKey() throws -> DatabaseKey? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw KeyStoreError.unexpectedKeychainData
            }
            return try DatabaseKey(rawBytes: data)
        case errSecItemNotFound:
            return nil
        default:
            throw KeyStoreError.keychainOperationFailed(status: status)
        }
    }

    private func storeKey(_ key: DatabaseKey) throws {
        var attributes = baseQuery()
        attributes[kSecValueData as String] = key.rawBytes
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeyStoreError.keychainOperationFailed(status: status)
        }
    }
}
