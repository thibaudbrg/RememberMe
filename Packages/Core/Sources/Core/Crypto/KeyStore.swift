import Foundation

/// A 32-byte secret used to encrypt the on-device SQLCipher database.
///
/// The value is high-entropy and is **not** a password — passing it through SQLCipher's
/// passphrase-form PRAGMA would trigger a wasteful internal KDF. Callers use ``hexBlob``
/// to format the key for SQLCipher's raw-key PRAGMA.
public struct DatabaseKey: Hashable, Sendable {
    public static let lengthInBytes = 32

    public let rawBytes: Data

    public init(rawBytes: Data) throws {
        guard rawBytes.count == Self.lengthInBytes else {
            throw KeyStoreError.invalidKeyLength(got: rawBytes.count, expected: Self.lengthInBytes)
        }
        self.rawBytes = rawBytes
    }

    /// Render the key for `PRAGMA key = "x'<hex>'"`. SQLCipher accepts a 64-char hex blob
    /// inside `x'…'` and uses it directly as the key — no internal KDF runs.
    public var hexBlob: String {
        let hex = rawBytes.map { String(format: "%02x", $0) }.joined()
        return "x'\(hex)'"
    }
}

/// Errors that the key store layer can surface.
public enum KeyStoreError: Error, Equatable, LocalizedError, CustomStringConvertible {
    case invalidKeyLength(got: Int, expected: Int)
    case randomGenerationFailed(status: Int32)
    case keychainOperationFailed(status: Int32)
    case unexpectedKeychainData

    public var description: String {
        switch self {
        case let .invalidKeyLength(got, expected):
            "invalid key length: got \(got) bytes, expected \(expected)"
        case let .randomGenerationFailed(status):
            "SecRandomCopyBytes failed (OSStatus \(status))"
        case let .keychainOperationFailed(status):
            "Keychain operation failed (OSStatus \(status))"
        case .unexpectedKeychainData:
            "Keychain returned unexpected data type"
        }
    }

    public var errorDescription: String? {
        description
    }
}

/// Abstraction over "give me the DB key, generating a fresh one on first call".
///
/// The real implementation persists in the iOS Keychain. Tests use an in-memory
/// implementation so they don't pollute the developer's actual Keychain.
public protocol KeyStore: Sendable {
    /// Returns the existing key if one was generated previously, or creates and stores a fresh one.
    /// Idempotent — repeated calls return the same key bytes.
    func getOrCreateKey() throws -> DatabaseKey

    /// Removes the stored key. Used by the wipe path. No-op if no key exists.
    func deleteKey() throws
}
