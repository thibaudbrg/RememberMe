import SwiftUI
import UIKit

/// Paged carousel for a cluster of photos taken at the same place. Presented when the
/// user taps a multi-photo cluster icon on the map. Each page loads a high-res version
/// of its photo on demand.
struct PhotoCarouselView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let photos: [GeoPhoto]

    @State private var currentIndex: Int = 0

    var body: some View {
        let library = environment.photoLibrary

        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                TabView(selection: $currentIndex) {
                    ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                        PhotoCarouselPage(photo: photo, photoLibrary: library)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: photos.count > 1 ? .always : .never))
                .indexViewStyle(.page(backgroundDisplayMode: .always))
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.white)
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text(photos[currentIndex].creationDate.formatted(date: .abbreviated, time: .shortened))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white)
                        if photos.count > 1 {
                            Text("\(currentIndex + 1) of \(photos.count)")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }
            }
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }
}

/// One page in the carousel — loads a high-res thumbnail and scales it to fit. Same
/// loading characteristics as `PhotoDetailView` (the single-photo sheet); split out so
/// each TabView page can hold its own `@State` for the image.
private struct PhotoCarouselPage: View {
    let photo: GeoPhoto
    let photoLibrary: PhotoLibraryService

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: photo.id) {
            image = await photoLibrary.thumbnail(
                for: photo.id,
                size: CGSize(width: 1600, height: 1600)
            )
        }
    }
}
