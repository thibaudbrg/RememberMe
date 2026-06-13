import Core
import CoreLocation
import Foundation
import Observation
import Photos
import PhotosUI
import UIKit

/// Lightweight description of a photo on the device library that has a geo-tag.
struct GeoPhoto: Identifiable, Hashable, Sendable {
    let id: String // PHAsset.localIdentifier
    let coordinate: Coordinate
    let creationDate: Date
}

/// Wraps PhotoKit access. Asks for read permission on demand and exposes a day-bounded
/// fetch of geo-tagged assets, plus thumbnail loading.
///
/// All photo data stays on-device — RememberMe never sends anything anywhere.
@MainActor
@Observable
final class PhotoLibraryService {
    enum Authorization: Equatable {
        case notDetermined
        case denied
        case restricted
        case authorized
        case limited
    }

    private(set) var authorization: Authorization = .notDetermined

    private let imageManager = PHCachingImageManager()
    /// Caches decoded thumbnails keyed by "<assetID>@<width>x<height>" so re-clustering and
    /// zoom don't refetch the same thumbnail cold every pass.
    private let thumbnailCache = NSCache<NSString, UIImage>()

    init() {
        authorization = Self.translate(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    /// Presents the system "Select More Photos" picker so a user in limited-access mode can
    /// extend the set RememberMe is allowed to see. No-op unless authorization is `.limited`.
    func presentLimitedLibraryPicker() {
        guard authorization == .limited else { return }
        guard let presenter = Self.topViewController() else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: presenter)
    }

    /// Walks the foreground-active window scene to the top-most presented controller — the
    /// correct presenter for a UIKit modal launched from SwiftUI.
    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }

    /// Asks for read access. Idempotent — returns the current status after the prompt.
    @discardableResult
    func ensureAuthorized() async -> Authorization {
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
    func photos(in dayRange: Range<Date>) async -> [GeoPhoto] {
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
    func photosNear(
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
    func thumbnail(for photoID: String, size: CGSize = CGSize(width: 80, height: 80)) async -> UIImage? {
        let cacheKey = "\(photoID)@\(Int(size.width))x\(Int(size.height))"
        if let cached = thumbnailCache.object(forKey: cacheKey as NSString) {
            return cached
        }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [photoID], options: nil).firstObject else {
            return nil
        }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false // strictly on-device
        options.isSynchronous = false

        let image = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
                var didResume = false
                let resume: (UIImage?) -> Void = { result in
                    guard !didResume else { return }
                    didResume = true
                    continuation.resume(returning: result)
                }
                let requestID = imageManager.requestImage(
                    for: asset,
                    targetSize: size,
                    contentMode: .aspectFill,
                    options: options
                ) { image, info in
                    // `requestImage` may call the handler multiple times (degraded + full).
                    // We want the final one. `PHImageResultIsDegradedKey == false` means final.
                    let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                    let isInCloud = (info?[PHImageResultIsInCloudKey] as? Bool) ?? false
                    let failed = info?[PHImageErrorKey] != nil
                    // A degraded result is normally followed by the final one — wait for it.
                    // But with network access disabled, an iCloud-offloaded asset delivers
                    // ONLY the degraded local thumbnail (no final callback can come), so resume
                    // with what we have instead of leaking the continuation forever.
                    if isDegraded && !isInCloud && !failed { return }
                    resume(image)
                }
                self.pendingRequestIDs[cacheKey] = requestID
            }
        } onCancel: {
            // View-task cancellation (annotation scrolled off / re-clustered) cancels the
            // outstanding PhotoKit request so it doesn't keep decoding.
            Task { @MainActor in self.cancelThumbnailRequest(for: cacheKey) }
        }

        pendingRequestIDs[cacheKey] = nil
        if let image {
            thumbnailCache.setObject(image, forKey: cacheKey as NSString)
        }
        return image
    }

    /// Outstanding PhotoKit request IDs, keyed the same way as the thumbnail cache, so a
    /// cancelled view task can cancel its in-flight request.
    private var pendingRequestIDs: [String: PHImageRequestID] = [:]

    private func cancelThumbnailRequest(for cacheKey: String) {
        if let requestID = pendingRequestIDs.removeValue(forKey: cacheKey) {
            imageManager.cancelImageRequest(requestID)
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
