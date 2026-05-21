@testable import Core
import XCTest

final class ExportEnvelopeTests: XCTestCase {
    // Test parameters: trivially small (m=8 KiB, t=1, p=1) to keep the suite fast.
    // Real exports use `.strong`. The envelope code shouldn't care.
    private let fastParams = PassphraseKDF.Parameters(
        memoryKiB: 8,
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
