import Core
import CoreLocation
import Foundation
import Observation
import Photos
import UIKit

/// Lightweight description of a photo on the device library that has a geo-tag.
public struct GeoPhoto: Identifiable, Hashable, Sendable {
    public let id: String // PHAsset.localIdentifier
    public let coordinate: Coordinate
    public let creationDate: Date
}

/// Wraps PhotoKit access. Asks for read permission on demand and exposes a day-bounded
/// fetch of geo-tagged assets, plus thumbnail loading.
///
/// All photo data stays on-device — RememberMe never sends anything anywhere.
@MainActor
@Observable
public final class PhotoLibraryService {
    public enum Authorization: Equatable {
        case notDetermined
        case denied
        case restricted
        case authorized
        case limited
    }

    public private(set) var authorization: Authorization = .notDetermined

    private let imageManager = PHCachingImageManager()

    public init() {
        authorization = Self.translate(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    /// Asks for read access. Idempotent — returns the current status after the prompt.
    @discardableResult
    public func ensureAuthorized() async -> Authorization {
        if case .authorized = authorization { return authorization }
        if case .limited = authorization { return authorization }

        let granted = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        authorization = Self.translate(granted)
        return authorization
    }

    /// Returns geo-tagged photos created within `dayRange`. Empty if access isn't granted yet.
    ///
    /// We fetch all image assets, then filter by creation date + location in Swift instead of
    /// using an NSPredicate. The simulator's Photos library has had subtle predicate-matching
    /// quirks; Swift-side filtering is more predictable.
    public func photos(in dayRange: Range<Date>) async -> [GeoPhoto] {
        guard authorization == .authorized || authorization == .limited else { return [] }

        return await Task.detached(priority: .userInitiated) {
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
            options.predicate = NSPredicate(
                format: "mediaType == %d",
                PHAssetMediaType.image.rawValue
            )
            let assets = PHAsset.fetchAssets(with: options)

            var photos: [GeoPhoto] = []
            assets.enumerateObjects { asset, _, _ in
                guard let creationDate = asset.creationDate,
                      let location = asset.location
                else { return }
                guard creationDate >= dayRange.lowerBound,
                      creationDate < dayRange.upperBound
                else { return }
                photos.append(GeoPhoto(
                    id: asset.localIdentifier,
                    coordinate: Coordinate(
                        latitude: location.coordinate.latitude,
                        longitude: location.coordinate.longitude
                    ),
                    creationDate: creationDate
                ))
            }
            return photos
        }.value
    }

    /// Returns geo-tagged photos within `radiusMeters` of `coordinate`, regardless of date.
    /// Used by `PlaceDetailView` to show every photo taken at a place across all visits,
    /// not just the currently-loaded day.
    public func photosNear(
        _ coordinate: Coordinate,
        radiusMeters: Double = 200
    ) async -> [GeoPhoto] {
        guard authorization == .authorized || authorization == .limited else { return [] }
        return await Task.detached(priority: .userInitiated) {
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            options.predicate = NSPredicate(
                format: "mediaType == %d",
                PHAssetMediaType.image.rawValue
            )
            let assets = PHAsset.fetchAssets(with: options)

            var photos: [GeoPhoto] = []
            assets.enumerateObjects { asset, _, _ in
                guard let creationDate = asset.creationDate,
                      let location = asset.location else { return }
                let assetCoordinate = Coordinate(
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude
                )
                let distance = PolylineDirection.haversineMeters(coordinate, assetCoordinate)
                guard distance <= radiusMeters else { return }
                photos.append(GeoPhoto(
                    id: asset.localIdentifier,
                    coordinate: assetCoordinate,
                    creationDate: creationDate
                ))
            }
            return photos
        }.value
    }

    /// Asynchronously loads a small square thumbnail for a photo. Returns nil if the asset
    /// is gone (e.g., user deleted it after we cached the id).
    public func thumbnail(for photoID: String, size: CGSize = CGSize(width: 80, height: 80)) async -> UIImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [photoID], options: nil).firstObject else {
            return nil
        }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false // strictly on-device
        options.isSynchronous = false

        return await withCheckedContinuation { continuation in
            var didResume = false
            imageManager.requestImage(
                for: asset,
                targetSize: size,
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                // `requestImage` may call the handler multiple times (degraded + full).
                // We want the final one. `PHImageResultIsDegradedKey == false` means final.
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if isDegraded { return }
                guard !didResume else { return }
                didResume = true
                continuation.resume(returning: image)
            }
        }
    }

    private static func translate(_ status: PHAuthorizationStatus) -> Authorization {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .authorized
        case .limited: return .limited
        @unknown default: return .denied
        }
    }
}
