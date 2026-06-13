@testable import Core
import XCTest

final class ExportEnvelopeTests: XCTestCase {
    // Test parameters: smallest values the envelope's `open` bounds-check accepts (m=8 MiB,
    // t=1, p=1) to keep the suite fast. Real exports use `.strong`. The envelope code shouldn't
    // care beyond the range validation.
    private let fastParams = PassphraseKDF.Parameters(
        memoryKiB: 8192,
        iterations: 1,
        parallelism: 1,
        keyLengthBytes: 32
    )

    func testRoundtripSucceedsWithCorrectPassphrase() throws {
        let payload = Data("hello, encrypted world".utf8)
        let sealed = try ExportEnvelope.seal(payload: payload, passphrase: "correct horse", parameters: fastParams)
        let opened = try ExportEnvelope.open(envelope: sealed, passphrase: "correct horse")
        XCTAssertEqual(opened, payload)
    }

    func testWrongPassphraseFails() throws {
        let payload = Data("secrets".utf8)
        let sealed = try ExportEnvelope.seal(payload: payload, passphrase: "right", parameters: fastParams)
        XCTAssertThrowsError(try ExportEnvelope.open(envelope: sealed, passphrase: "wrong")) { error in
            XCTAssertEqual(error as? ExportEnvelope.Failure, .decryptionFailed)
        }
    }

    func testTamperedCiphertextFails() throws {
        let payload = Data("don't change me".utf8)
        var sealed = try ExportEnvelope.seal(payload: payload, passphrase: "pw", parameters: fastParams)
        // Flip one byte in the ciphertext (last 32 bytes are tag + a bit of ciphertext).
        let idx = sealed.count - 1
        sealed[idx] ^= 0x01
        XCTAssertThrowsError(try ExportEnvelope.open(envelope: sealed, passphrase: "pw")) { error in
            XCTAssertEqual(error as? ExportEnvelope.Failure, .decryptionFailed)
        }
    }

    func testBadMagicFails() throws {
        var bytes = Data("ZZZZ".utf8)
        bytes.append(Data(count: 100))
        XCTAssertThrowsError(try ExportEnvelope.open(envelope: bytes, passphrase: "pw")) { error in
            XCTAssertEqual(error as? ExportEnvelope.Failure, .badMagic)
        }
    }

    func testTruncatedFails() throws {
        let bytes = Data("RMEX".utf8) + Data([0x10, 0x00, 0x00, 0x00])  // claims 16-byte header, but nothing follows
        XCTAssertThrowsError(try ExportEnvelope.open(envelope: bytes, passphrase: "pw")) { error in
            XCTAssertEqual(error as? ExportEnvelope.Failure, .truncated)
        }
    }

    func testRejectsOutOfRangeKDFParameters() throws {
        // Hostile cost params must be rejected before deriving (m far above the 512 MiB cap
        // would otherwise trap/OOM in Argon2Swift). Re-emit the header with each bad value,
        // keeping the body intact so the failure can only come from the bounds check.
        let badHeaders = [
            headerOverriding(m: 8_000_000),  // ~8 GiB
            headerOverriding(m: -1),         // negative
            headerOverriding(t: 0),          // below floor
            headerOverriding(t: 17),         // above ceiling
            headerOverriding(p: 0),
            headerOverriding(p: 5),
        ]
        for header in badHeaders {
            let envelope = try rebuiltEnvelope(header: header)
            XCTAssertThrowsError(try ExportEnvelope.open(envelope: envelope, passphrase: "pw")) { error in
                guard case .headerDecode = error as? ExportEnvelope.Failure else {
                    return XCTFail("expected .headerDecode for header \(header), got \(error)")
                }
            }
        }
    }

    func testRejectsMismatchedAAD() throws {
        let envelope = try rebuiltEnvelope(header: headerOverriding(aad: "rememberme-export-v2"))
        XCTAssertThrowsError(try ExportEnvelope.open(envelope: envelope, passphrase: "pw")) { error in
            guard case .headerDecode = error as? ExportEnvelope.Failure else {
                return XCTFail("expected .headerDecode, got \(error)")
            }
        }
    }

    /// A valid header captured from a real seal, reused as the base for tampering tests.
    private lazy var sealedHeader: ExportEnvelope.Header = {
        let sealed = try! ExportEnvelope.seal(payload: Data("x".utf8), passphrase: "pw", parameters: fastParams)
        let headerLen = Int(sealed.subdata(in: 4 ..< 8).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian })
        let headerData = sealed.subdata(in: 8 ..< 8 + headerLen)
        return try! JSONDecoder().decode(ExportEnvelope.Header.self, from: headerData)
    }()

    /// Returns the captured valid header with one field overridden (its `let` fields require a
    /// full reconstruction).
    private func headerOverriding(
        m: Int? = nil, t: Int? = nil, p: Int? = nil, aad: String? = nil
    ) -> ExportEnvelope.Header {
        let base = sealedHeader
        return ExportEnvelope.Header(
            v: base.v, kdf: base.kdf,
            m: m ?? base.m, t: t ?? base.t, p: p ?? base.p,
            salt: base.salt, nonce: base.nonce, aad: aad ?? base.aad
        )
    }

    /// Re-emits an RMEX envelope around `header`, copying the body from a fresh seal so only the
    /// header differs. Decryption would fail (the body's nonce/salt won't match a tampered
    /// header), but these tests only exercise checks that fire *before* derivation.
    private func rebuiltEnvelope(header: ExportEnvelope.Header) throws -> Data {
        let sealed = try ExportEnvelope.seal(payload: Data("x".utf8), passphrase: "pw", parameters: fastParams)
        let headerLen = Int(sealed.subdata(in: 4 ..< 8).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian })
        let body = sealed.subdata(in: 8 + headerLen ..< sealed.count)

        let headerJSON = try JSONEncoder().encode(header)
        var output = Data()
        output.append(ExportEnvelope.magic)
        var len = UInt32(headerJSON.count).littleEndian
        output.append(withUnsafeBytes(of: &len) { Data($0) })
        output.append(headerJSON)
        output.append(body)
        return output
    }

    func testEmptyPassphraseRejectedAtSeal() throws {
        XCTAssertThrowsError(
            try ExportEnvelope.seal(payload: Data("x".utf8), passphrase: "", parameters: fastParams)
        ) { error in
            XCTAssertEqual(error as? PassphraseKDF.Failure, .emptyPassphrase)
        }
    }

    func testRoundtripOnRealisticPayload() throws {
        // JSON-shaped, similar size to a small export. Catches encoding-format bugs the trivial
        // string case wouldn't.
        var events: [ExportedEvent] = []
        for index in 0 ..< 50 {
            let visit = ExportedVisit(
                placeID: "place-\(index)",
                lat: 48.85 + Double(index) * 0.001,
                lon: 2.35 + Double(index) * 0.001,
                semanticType: "Unknown",
                hierarchyLevel: 0,
                probability: 0.5
            )
            events.append(ExportedEvent(
                id: "event-\(index)",
                kind: "visit",
                startTs: 1_700_000_000 + Int64(index * 600),
                startTzOffsetMin: 60,
                endTs: 1_700_000_000 + Int64(index * 600 + 300),
                endTzOffsetMin: 60,
                source: "test",
                importedAt: 1_700_000_000,
                visit: visit
            ))
        }
        let payload = ExportPayload(
            version: 1,
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
            events: events,
            places: []
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payloadJSON = try encoder.encode(payload)

        let sealed = try ExportEnvelope.seal(payload: payloadJSON, passphrase: "long-passphrase-123", parameters: fastParams)
        let opened = try ExportEnvelope.open(envelope: sealed, passphrase: "long-passphrase-123")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ExportPayload.self, from: opened)
        XCTAssertEqual(decoded, payload)
    }
}
