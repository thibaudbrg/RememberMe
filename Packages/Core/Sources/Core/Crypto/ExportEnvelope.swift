import CryptoKit
import Foundation

/// Wire format for the encrypted export file (`.rmex`):
///
/// ```
/// [4 bytes ] magic = "RMEX"  (ASCII)
/// [4 bytes ] header_length   (uint32 little-endian)
/// [N bytes ] header_json     (UTF-8 JSON, see Header below)
/// [rest    ] ChaChaPoly combined ciphertext (ciphertext || 16-byte tag)
/// ```
///
/// The header tells a future reader **how** to derive the key (KDF, salt, m/t/p) and
/// which nonce + AAD was used, so we never have to ship a separate file or rely on
/// parameters baked into the binary. Format version `v=1`.
public enum ExportEnvelope {
    public static let magic = Data("RMEX".utf8)
    public static let aad = Data("rememberme-export-v1".utf8)
    public static let version = 1

    public enum Failure: Error, Equatable {
        case badMagic
        case truncated
        case unsupportedVersion(Int)
        case unsupportedKDF(String)
        case headerDecode(String)
        case decryptionFailed
    }

    /// JSON-encoded header. Fields are snake_case to match the file-format spec in
    /// `docs/data-formats/rememberme-export-v1.md`.
    public struct Header: Codable, Equatable, Sendable {
        public let v: Int
        public let kdf: String          // "argon2id"
        public let m: Int               // memory in KiB
        public let t: Int               // iterations
        public let p: Int               // parallelism
        public let salt: String         // base64
        public let nonce: String        // base64
        public let aad: String          // ASCII tag, must match `ExportEnvelope.aad`
    }

    /// Seals `payload` under a key derived from `passphrase`. Generates a fresh salt and
    /// nonce on every call — never reuse an envelope's nonce.
    public static func seal(
        payload: Data,
        passphrase: String,
        parameters: PassphraseKDF.Parameters = .strong
    ) throws -> Data {
        let salt = try SecureRandom.bytes(16)
        let nonceBytes = try SecureRandom.bytes(12)
        let nonce = try ChaChaPoly.Nonce(data: nonceBytes)
        let key = try PassphraseKDF.deriveKey(
            passphrase: passphrase,
            salt: salt,
            parameters: parameters
        )
        let sealed = try ChaChaPoly.seal(
            payload,
            using: key,
            nonce: nonce,
            authenticating: aad
        )

        let header = Header(
            v: version,
            kdf: "argon2id",
            m: parameters.memoryKiB,
            t: parameters.iterations,
            p: parameters.parallelism,
            salt: salt.base64EncodedString(),
            nonce: nonceBytes.base64EncodedString(),
            aad: String(decoding: aad, as: UTF8.self)
        )
        let headerJSON = try JSONEncoder.envelope.encode(header)

        // Spec: tail = ciphertext || tag (NOT sealed.combined, which prepends the nonce).
        // The nonce lives in the header so the file is self-describing without prefixing it
        // twice.
        var output = Data()
        output.append(magic)
        output.append(uint32LE(UInt32(headerJSON.count)))
        output.append(headerJSON)
        output.append(sealed.ciphertext)
        output.append(sealed.tag)
        return output
    }

    /// Opens an envelope. Throws on malformed input, wrong passphrase, or modified bytes.
    public static func open(envelope: Data, passphrase: String) throws -> Data {
        guard envelope.count >= 8 else { throw Failure.truncated }
        let magicSlice = envelope.subdata(in: 0 ..< 4)
        guard magicSlice == magic else { throw Failure.badMagic }

        let headerLen = Int(readUInt32LE(envelope, at: 4))
        let headerStart = 8
        let headerEnd = headerStart + headerLen
        guard envelope.count >= headerEnd else { throw Failure.truncated }
        let headerData = envelope.subdata(in: headerStart ..< headerEnd)
        let ciphertext = envelope.subdata(in: headerEnd ..< envelope.count)

        let header: Header
        do {
            header = try JSONDecoder.envelope.decode(Header.self, from: headerData)
        } catch {
            throw Failure.headerDecode(String(describing: error))
        }
        guard header.v == version else { throw Failure.unsupportedVersion(header.v) }
        guard header.kdf == "argon2id" else { throw Failure.unsupportedKDF(header.kdf) }
        guard let salt = Data(base64Encoded: header.salt),
              let nonceBytes = Data(base64Encoded: header.nonce)
        else {
            throw Failure.headerDecode("invalid base64 in salt/nonce")
        }

        let params = PassphraseKDF.Parameters(
            memoryKiB: header.m,
            iterations: header.t,
            parallelism: header.p,
            keyLengthBytes: 32
        )
        let key = try PassphraseKDF.deriveKey(
            passphrase: passphrase,
            salt: salt,
            parameters: params
        )
        let nonce = try ChaChaPoly.Nonce(data: nonceBytes)
        let aadBytes = Data(header.aad.utf8)
        // ciphertext slice is ct||tag (last 16 bytes are the auth tag). SealedBox builder
        // accepts these split, which avoids re-prepending the nonce.
        guard ciphertext.count >= 16 else { throw Failure.truncated }
        let tagStart = ciphertext.count - 16
        let ctBody = ciphertext.subdata(in: 0 ..< tagStart)
        let tag = ciphertext.subdata(in: tagStart ..< ciphertext.count)
        do {
            let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ctBody, tag: tag)
            return try ChaChaPoly.open(box, using: key, authenticating: aadBytes)
        } catch {
            throw Failure.decryptionFailed
        }
    }

    // MARK: - Helpers

    private static func uint32LE(_ value: UInt32) -> Data {
        var v = value.littleEndian
        return withUnsafeBytes(of: &v) { Data($0) }
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        let slice = data.subdata(in: offset ..< offset + 4)
        return slice.withUnsafeBytes { raw in
            raw.load(as: UInt32.self).littleEndian
        }
    }
}

extension JSONEncoder {
    /// Deterministic JSON encoding for envelope headers — sorted keys keep the byte layout
    /// stable across runs (useful for fixture-based tests, even though decryption doesn't
    /// rely on it).
    static let envelope: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}

extension JSONDecoder {
    static let envelope: JSONDecoder = JSONDecoder()
}
