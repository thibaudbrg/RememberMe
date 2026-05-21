import XCTest
@testable import Core

final class InMemoryKeyStoreTests: XCTestCase {
    func testGeneratesA32ByteKey() throws {
        let store = InMemoryKeyStore()
        let key = try store.getOrCreateKey()
        XCTAssertEqual(key.rawBytes.count, 32)
    }

    func testRepeatedCallsReturnSameKey() throws {
        let store = InMemoryKeyStore()
        let first = try store.getOrCreateKey()
        let second = try store.getOrCreateKey()
        XCTAssertEqual(first, second)
    }

    func testDeleteThenRegenerateProducesDifferentKey() throws {
        let store = InMemoryKeyStore()
        let original = try store.getOrCreateKey()
        try store.deleteKey()
        let fresh = try store.getOrCreateKey()
        XCTAssertNotEqual(original, fresh, "wipe should produce a brand new key, not the cached one")
    }

    func testHexBlobIsCorrectFormat() throws {
        let key = try DatabaseKey(rawBytes: Data(repeating: 0xAB, count: 32))
        XCTAssertEqual(key.hexBlob, "x'\(String(repeating: "ab", count: 32))'")
    }

    func testRejectsWrongLengthKey() {
        XCTAssertThrowsError(try DatabaseKey(rawBytes: Data(repeating: 0, count: 16))) { error in
            guard case let KeyStoreError.invalidKeyLength(got, expected) = error else {
                return XCTFail("expected .invalidKeyLength, got \(error)")
            }
            XCTAssertEqual(got, 16)
            XCTAssertEqual(expected, 32)
        }
    }
}
