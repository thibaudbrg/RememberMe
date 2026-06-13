import Foundation
import Security

/// `KeyStore` that persists the database key in the iOS / macOS Keychain.
///
/// Storage attributes:
/// - `kSecClass = kSecClassGenericPassword`
/// - `kSecAttrService = <service>` (defaults to `"RememberMe.DB"`)
/// - `kSecAttrAccount = <account>` (defaults to `"primary"`)
/// - `kSecAttrAccessible = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
/// - `kSecAttrSynchronizable = false`
///
/// `AfterFirstUnlock` means the key is readable once the device has been unlocked at least
/// once since boot, so background location relaunches (which can fire while the device is
/// locked in a pocket) can still open the encrypted DB. Pairs with the DB file's
/// `completeUntilFirstUserAuthentication` protection. Tradeoff is documented in SECURITY.md.
public final class KeychainKeyStore: KeyStore, @unchecked Sendable {
    public let service: String
    public let account: String

    public init(service: String = "RememberMe.DB", account: String = "primary") {
        self.service = service
        self.account = account
    }

    public func getOrCreateKey() throws -> DatabaseKey {
        if let existing = try fetchKey() {
            // Accessibility is fixed at `SecItemAdd` time, so items written before the
            // migration to `AfterFirstUnlock` keep the old `WhenUnlocked` class. Update them
            // in place on this (necessarily unlocked) read path. Idempotent for new items.
            migrateAccessibility()
            return existing
        }
        let fresh = try DatabaseKey(rawBytes: SecureRandom.bytes(DatabaseKey.lengthInBytes))
        do {
            try storeKey(fresh)
        } catch KeyStoreError.keychainOperationFailed(errSecDuplicateItem) {
            // Another caller raced us between fetchKey() and storeKey() and won — re-fetch
            // their key instead of failing. If the item somehow vanished again, surface that.
            guard let winner = try fetchKey() else {
                throw KeyStoreError.keychainOperationFailed(status: errSecDuplicateItem)
            }
            return winner
        }
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
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeyStoreError.keychainOperationFailed(status: status)
        }
    }

    /// Updates an existing item's accessibility to `AfterFirstUnlockThisDeviceOnly`. Best-effort
    /// and idempotent: a no-op once the item already has the target class. Called only after a
    /// successful fetch (the item is readable, i.e. the device is unlocked), so the update can
    /// proceed. Failures are ignored — the key is still usable; the next unlocked launch retries.
    private func migrateAccessibility() {
        let update: [String: Any] = [
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        _ = SecItemUpdate(baseQuery() as CFDictionary, update as CFDictionary)
    }
}
