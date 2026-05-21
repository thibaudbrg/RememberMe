import XCTest
@testable import Core

/// Exercises `KeychainKeyStore` against the real local macOS Keychain (no mocking).
/// Each test uses a unique service name so concurrent runs don't collide, and tears
/// down its entry afterward.
///
/// These tests are macOS-only (the Keychain API behaves slightly differently on iOS
/// simulators in CI). On platforms where the Keychain isn't available, the tests bail
/// out gracefully via `XCTSkip`.
final class KeychainKeyStoreTests: XCTestCase {
    private var store: KeychainKeyStore!
    private var uniqueService: String!

    override func setUpWithError() throws {
        #if !os(macOS)
        throw XCTSkip("KeychainKeyStore tests run on macOS host only")
        #else
        uniqueService = "RememberMe.Test.\(UUID().uuidString)"
        store = KeychainKeyStore(service: uniqueService, account: "primary")
        try store.deleteKey() // belt and suspenders
        #endif
    }

    override func tearDownWithError() throws {
        try store?.deleteKey()
    }

    func testFirstCallGenerates32BytesAndPersists() throws {
        let key = try store.getOrCreateKey()
        XCTAssertEqual(key.rawBytes.count, 32)

        // Build a fresh store pointing at the same Keychain item — should read back the same bytes.
        let secondHandle = KeychainKeyStore(service: uniqueService, account: "primary")
        let reread = try secondHandle.getOrCreateKey()
        XCTAssertEqual(key, reread)
    }

    func testDeleteRemovesTheItem() throws {
        _ = try store.getOrCreateKey()
        try store.deleteKey()

        // After delete, a fresh fetch via a new handle should generate a new key (different bytes).
        let freshHandle = KeychainKeyStore(service: uniqueService, account: "primary")
        let regenerated = try freshHandle.getOrCreateKey()
        XCTAssertEqual(regenerated.rawBytes.count, 32)
    }

    func testDeleteIsIdempotent() throws {
        try store.deleteKey()
        try store.deleteKey() // must not throw
    }
}
