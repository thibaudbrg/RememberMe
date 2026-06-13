import Core
import Security
import XCTest
@testable import RememberMe

final class RememberMeTests: XCTestCase {

    // MARK: - PhotoCluster

    /// Two photos closer than the threshold collapse into one cluster; the same input
    /// re-clustered produces the identical cluster id (so SwiftUI reuses annotations).
    func testClusterMergesNearbyPhotosDeterministically() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let photos = [
            GeoPhoto(id: "a", coordinate: Coordinate(latitude: 48.8566, longitude: 2.3522), creationDate: base),
            // ~10 m east of "a" — well under the 30 m default threshold.
            GeoPhoto(id: "b", coordinate: Coordinate(latitude: 48.8566, longitude: 2.35234), creationDate: base.addingTimeInterval(60)),
        ]

        let first = PhotoCluster.cluster(photos, cameraDistance: nil)
        XCTAssertEqual(first.count, 1, "two photos within the default threshold should merge")
        XCTAssertEqual(first[0].photos.count, 2)

        // Re-clustering the same input yields the same id (order-independent, sorted).
        let second = PhotoCluster.cluster(photos, cameraDistance: nil)
        XCTAssertEqual(first.map(\.id), second.map(\.id), "clustering must be deterministic")
        XCTAssertEqual(first[0].id, "a|b")
    }

    /// Photos far apart stay separate; tightening the threshold (deep zoom) splits a pair
    /// that merged at the default threshold.
    func testClusterThresholdScalesWithCameraDistance() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let photos = [
            GeoPhoto(id: "a", coordinate: Coordinate(latitude: 48.8566, longitude: 2.3522), creationDate: base),
            // ~20 m apart: merges at the default (30 m) but splits at street-level zoom.
            GeoPhoto(id: "b", coordinate: Coordinate(latitude: 48.8566, longitude: 2.35247), creationDate: base.addingTimeInterval(60)),
        ]

        // Default (cameraDistance nil → 30 m threshold): merged.
        XCTAssertEqual(PhotoCluster.cluster(photos, cameraDistance: nil).count, 1)

        // Deep zoom: cameraDistance 100 m → threshold max(15, 2.5) = 15 m, so the ~20 m
        // pair splits into two clusters.
        let tight = PhotoCluster.cluster(photos, cameraDistance: 100)
        XCTAssertEqual(tight.count, 2, "tighter threshold should split the pair")
    }

    func testClusterEmptyInputReturnsEmpty() {
        XCTAssertTrue(PhotoCluster.cluster([], cameraDistance: nil).isEmpty)
    }

    // MARK: - KeychainKeyStore (iOS data-protection keychain round-trip)

    /// Exercises Core's `KeychainKeyStore` against the real iOS keychain (the
    /// `kSecUseDataProtectionKeychain` branch only compiled on iOS, never run by the
    /// macOS-only Core tests). Uses a throwaway service/account so the developer's real
    /// DB key is untouched, and cleans up after itself.
    ///
    /// The data-protection keychain requires the host app's `application-identifier`
    /// entitlement, which is only injected under code signing. When the test host runs
    /// unsigned (e.g. `CODE_SIGNING_ALLOWED=NO` on CI) the keychain returns
    /// `errSecMissingEntitlement (-34018)`; skip in that case rather than fail, so the test
    /// still asserts the real round-trip on a normally-signed device/simulator build.
    func testKeychainKeyStoreRoundTrip() throws {
        let store = KeychainKeyStore(
            service: "RememberMe.Tests.\(UUID().uuidString)",
            account: "primary"
        )
        // Ensure a clean slate even if a prior crashed run left an item.
        try? store.deleteKey()

        let created: DatabaseKey
        do {
            created = try store.getOrCreateKey()
        } catch KeyStoreError.keychainOperationFailed(errSecMissingEntitlement) {
            throw XCTSkip("data-protection keychain needs a signed host (errSecMissingEntitlement)")
        }
        XCTAssertEqual(created.rawBytes.count, DatabaseKey.lengthInBytes)

        // Second call returns the same key bytes (persisted, idempotent).
        let fetched = try store.getOrCreateKey()
        XCTAssertEqual(created.rawBytes, fetched.rawBytes, "getOrCreateKey must be idempotent")

        // Delete removes it; the next getOrCreateKey mints a fresh, different key.
        try store.deleteKey()
        let regenerated = try store.getOrCreateKey()
        XCTAssertNotEqual(created.rawBytes, regenerated.rawBytes, "a fresh key should differ after delete")

        // Clean up the throwaway item.
        try store.deleteKey()
    }
}
