import Argon2Swift
import CryptoKit
import Foundation

/// Derives a `SymmetricKey` from a user passphrase using **Argon2id**.
///
/// Used only by the encrypted-export envelope (`RMEX`). The on-disk SQLCipher DB uses a
/// separate 32-byte random key held in the Keychain — passphrase derivation is reserved
/// for the export path where the user explicitly chooses the secret.
///
/// Defaults (`m = 64 MiB, t = 3, p = 1, 32-byte key`) match OWASP 2026's "strong" Argon2id
/// recommendation. Parameters are stamped into the envelope header so we can raise them
/// later without breaking existing files.
public enum PassphraseKDF {
    /// Argon2id parameters. Memory is in KiB; iterations is the time cost.
    public struct Parameters: Sendable, Equatable {
        public let memoryKiB: Int
        public let iterations: Int
        public let parallelism: Int
        public let keyLengthBytes: Int

        public init(memoryKiB: Int, iterations: Int, parallelism: Int, keyLengthBytes: Int) {
            self.memoryKiB = memoryKiB
            self.iterations = iterations
            self.parallelism = parallelism
            self.keyLengthBytes = keyLengthBytes
        }

        /// 64 MiB, 3 iterations, 1 lane, 32-byte output. Comfortable for one-shot
        /// passphrase derivation on modern iPhones (sub-second on A17 Pro).
        public static let strong = Parameters(
            memoryKiB: 65_536,
            iterations: 3,
            parallelism: 1,
            keyLengthBytes: 32
        )
    }

    public enum Failure: Error, Equatable {
        case emptyPassphrase
        case underlying(String)
    }

    /// Runs Argon2id over `passphrase` and `salt`, producing a `SymmetricKey` suitable for
    /// ChaChaPoly. Argon2Swift is synchronous and the wrapper does no I/O, so callers can
    /// wrap this in `Task.detached` to keep the main actor responsive.
    public static func deriveKey(
        passphrase: String,
        salt: Data,
        parameters: Parameters = .strong
    ) throws -> SymmetricKey {
        guard !passphrase.isEmpty else { throw Failure.emptyPassphrase }
        let saltWrapper = Salt(bytes: salt)
        do {
            let result = try Argon2Swift.hashPasswordString(
                password: passphrase,
                salt: saltWrapper,
                iterations: parameters.iterations,
                memory: parameters.memoryKiB,
                parallelism: parameters.parallelism,
                length: parameters.keyLengthBytes,
                type: .id,
                version: .V13
            )
            return SymmetricKey(data: result.hashData())
        } catch {
            throw Failure.underlying(String(describing: error))
        }
    }
}
