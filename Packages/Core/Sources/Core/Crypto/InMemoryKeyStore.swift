import Foundation

/// In-memory `KeyStore` used by tests and for one-off ephemeral databases.
/// Generates a fresh random key on first `getOrCreateKey()` call, holds it for the lifetime of the instance.
public final class InMemoryKeyStore: KeyStore, @unchecked Sendable {
    private var cached: DatabaseKey?
    private let lock = NSLock()

    public init() {}

    public func getOrCreateKey() throws -> DatabaseKey {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let key = try DatabaseKey(rawBytes: SecureRandom.bytes(DatabaseKey.lengthInBytes))
        cached = key
        return key
    }

    public func deleteKey() throws {
        lock.lock()
        defer { lock.unlock() }
        cached = nil
    }
}
