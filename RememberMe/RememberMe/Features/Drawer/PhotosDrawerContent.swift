import Persistence
import SwiftUI

/// Third drawer tab: photos taken on the selected day, shown as a grid of thumbnails.
/// Tap a photo to open it full-screen via `PhotoDetailView` (presented by MapScreen).
///
/// Pinch on the grid to step through column counts the way the iOS Photos app does
/// (fewer columns = larger photos; more columns = denser overview).
struct PhotosDrawerContent: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(Settings.self) private var settings
    @State private var selectedPhoto: GeoPhoto?
    @State private var columnCount: Int = 3
    @State private var pinchBaseColumnCount: Int = 3

    private static let availableColumnCounts: [Int] = [2, 3, 5, 7]
    private static let gridSpacing: CGFloat = 2

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: Self.gridSpacing),
            count: columnCount
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                DayPickerView()
                    .padding(.horizontal, 20)

                if !settings.showPhotosOnMap {
                    disabledState
                } else if environment.dayPhotos.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, spacing: Self.gridSpacing) {
                        ForEach(environment.dayPhotos) { photo in
                            PhotoGridItem(photo: photo, photoLibrary: environment.photoLibrary)
                                .onTapGesture {
                                    selectedPhoto = photo
                                    environment.focus(.photo(
                                        id: photo.id,
                                        coordinate: photo.coordinate
                                    ))
                                }
                        }
                    }
                    .gesture(pinchGesture)
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 32)
        }
        .sheet(item: $selectedPhoto) { photo in
            PhotoDetailView(photo: photo)
        }
    }

    /// Pinch to step between column counts. We snap discretely rather than scale
    /// continuously — Photos.app's grid only has a handful of zoom levels and
    /// each one re-lays out the lazy grid, so smooth scaling would be jittery.
    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let baseIndex = Self.availableColumnCounts.firstIndex(of: pinchBaseColumnCount) ?? 1
                let delta: Int
                if value.magnification > 1.4 {
                    delta = -1 // zoom in → fewer columns → larger photos
                } else if value.magnification < 0.7 {
                    delta = 1 // zoom out → more columns → smaller photos
                } else {
                    delta = 0
                }
                let newIndex = max(0, min(Self.availableColumnCounts.count - 1, baseIndex + delta))
                let newCount = Self.availableColumnCounts[newIndex]
                if newCount != columnCount {
                    withAnimation(.easeOut(duration: 0.18)) {
                        columnCount = newCount
                    }
                }
            }
            .onEnded { _ in
                pinchBaseColumnCount = columnCount
            }
    }

    private var disabledState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Photos are off")
                .font(.headline)
            Text("Turn on \"Photos on map\" in Settings to see photos taken on this day.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No photos this day")
                .font(.headline)
            Text("Pick another day to see photos you took then.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

/// Square thumbnail rendered in the day's photo grid. Receives the photo library as a value
/// to avoid `@Environment` access issues in cells with their own observation lifetimes.
///
/// We use `Color.clear.aspectRatio(.fit)` to drive the cell to a square that exactly fills
/// its column, then overlay the image with `.scaledToFill` + `.clipped`. The previous
/// approach used `.aspectRatio(1, contentMode: .fill)` on the cell itself, which let cells
/// exceed their column width and overlap each other (the visible "superposed" bug).
private struct PhotoGridItem: View {
    let photo: GeoPhoto
    let photoLibrary: PhotoLibraryService

    @State private var image: UIImage?

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle()
                        .fill(.thinMaterial)
                        .overlay {
                            Image(systemName: "photo")
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .task(id: photo.id) {
                image = await photoLibrary.thumbnail(
                    for: photo.id,
                    size: CGSize(width: 240, height: 240)
                )
            }
    }
}
