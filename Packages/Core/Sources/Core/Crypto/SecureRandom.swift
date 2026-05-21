import Foundation
import Security

/// Thin wrapper around `SecRandomCopyBytes`. Centralised so every consumer goes through one place.
public enum SecureRandom {
    /// Returns `count` cryptographically-random bytes. Throws on the rare event the
    /// system RNG is unavailable (kernel panic territory — but we don't silently fall back).
    public static func bytes(_ count: Int) throws -> Data {
        precondition(count > 0, "SecureRandom.bytes(_:) requires a positive count")
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        guard status == errSecSuccess else {
            throw KeyStoreError.randomGenerationFailed(status: status)
        }
        return data
    }
}
