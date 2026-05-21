import Persistence
import SwiftUI

/// Third drawer tab: photos taken on the selected day, shown as a grid of thumbnails.
/// Tap a photo to open it full-screen via `PhotoDetailView` (presented by MapScreen).
struct PhotosDrawerContent: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(Settings.self) private var settings
    @State private var selectedPhoto: GeoPhoto?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 3)

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
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(environment.dayPhotos) { photo in
                            PhotoGridItem(photo: photo, photoLibrary: environment.photoLibrary)
                                .aspectRatio(1, contentMode: .fill)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedPhoto = photo
                                    environment.focus(.photo(
                                        id: photo.id,
                                        coordinate: photo.coordinate
                                    ))
                                }
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 32)
        }
        .sheet(item: $selectedPhoto) { photo in
            PhotoDetailView(photo: photo)
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
private struct PhotoGridItem: View {
    let photo: GeoPhoto
    let photoLibrary: PhotoLibraryService

    @State private var image: UIImage?

    var body: some View {
        Group {
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
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: photo.id) {
            image = await photoLibrary.thumbnail(
                for: photo.id,
                size: CGSize(width: 240, height: 240)
            )
        }
    }
}
