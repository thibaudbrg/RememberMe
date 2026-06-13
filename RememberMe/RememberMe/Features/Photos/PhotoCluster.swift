import Core
import Foundation
import SwiftUI

/// A group of `GeoPhoto`s that should be rendered as a single icon on the map because
/// they sit close enough together that drawing each individually creates an unreadable
/// stack of overlapping thumbnails.
///
/// Clustering is recomputed every time the camera zooms; at deep zoom the threshold
/// shrinks and photos split back into individual icons.
struct PhotoCluster: Identifiable, Equatable, Hashable {
    /// Concatenation of contained photo ids, sorted — stable across re-clusters as long
    /// as the same set of photos winds up together, so SwiftUI can reuse annotation views.
    let id: String
    /// Centroid of the contained photos. Drawn as the icon location so the marker sits
    /// in the middle of the group, not on whichever photo happened to be the seed.
    let coordinate: Coordinate
    let photos: [GeoPhoto]

    /// Greedy spatial clustering. Threshold scales with `cameraDistance` so the same
    /// photos collapse at city-level zoom and split at street-level zoom.
    ///
    /// Coefficient picked empirically: at `distance ≈ 1 km` the threshold is ~25 m
    /// (tight enough that two photos at the same café still merge but two photos a
    /// block apart don't); at `distance ≈ 50 km` it's ~1.25 km (whole-neighbourhood
    /// merging).
    static func cluster(
        _ photos: [GeoPhoto],
        cameraDistance: Double?
    ) -> [PhotoCluster] {
        guard !photos.isEmpty else { return [] }

        let threshold: Double
        if let cameraDistance {
            threshold = max(15, cameraDistance * 0.025)
        } else {
            threshold = 30
        }

        // Sort by time so seeds are deterministic — re-clustering on the same input
        // yields the same groups (and the same ids), avoiding annotation churn.
        let sorted = photos.sorted { $0.creationDate < $1.creationDate }
        var assigned: Set<String> = []
        var clusters: [PhotoCluster] = []

        for seed in sorted {
            if assigned.contains(seed.id) { continue }
            var group: [GeoPhoto] = [seed]
            assigned.insert(seed.id)
            for other in sorted where !assigned.contains(other.id) {
                let distance = PolylineDirection.haversineMeters(
                    seed.coordinate,
                    other.coordinate
                )
                if distance <= threshold {
                    group.append(other)
                    assigned.insert(other.id)
                }
            }
            let centerLat = group.map(\.coordinate.latitude).reduce(0, +) / Double(group.count)
            let centerLon = group.map(\.coordinate.longitude).reduce(0, +) / Double(group.count)
            let id = group.map(\.id).sorted().joined(separator: "|")
            clusters.append(PhotoCluster(
                id: id,
                coordinate: Coordinate(latitude: centerLat, longitude: centerLon),
                photos: group
            ))
        }
        return clusters
    }
}

/// Map annotation icon for a `PhotoCluster`. Single-photo clusters render exactly like the
/// pre-clustering `PhotoThumbnail`; multi-photo clusters add a small count badge in the
/// corner so the user knows tapping will open a carousel.
///
/// The view is given a stable transition so SwiftUI animates merges and splits — when the
/// camera zooms and the cluster set changes, removed icons scale+fade out and inserted ones
/// scale+fade in. Pair this with a `withAnimation(.easeInOut)` around the camera state
/// update that drives re-clustering.
struct PhotoClusterThumbnail: View {
    let cluster: PhotoCluster
    let photoLibrary: PhotoLibraryService

    var body: some View {
        ZStack(alignment: .topTrailing) {
            PhotoThumbnail(photo: cluster.photos[0], photoLibrary: photoLibrary)

            if cluster.photos.count > 1 {
                Text("\(cluster.photos.count)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.red))
                    .overlay(Capsule().stroke(.white, lineWidth: 0.75))
                    .fixedSize()
                    .offset(x: 6, y: -6)
            }
        }
        .contentShape(Rectangle())
        .transition(.scale.combined(with: .opacity))
    }
}
