import SwiftUI
import UIKit

/// Map annotation thumbnail for a `GeoPhoto`. Loads the underlying `UIImage` asynchronously
/// from the device library; until loaded shows a small placeholder.
///
/// Receives the `PhotoLibraryService` as a value because SwiftUI's `@Environment` doesn't
/// reliably traverse into Map annotation content closures on iOS 17 — reading the env value
/// inside a Map annotation crashes the view tree.
struct PhotoThumbnail: View {
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
                            .font(.caption2)
                    }
            }
        }
        .frame(width: 24, height: 24)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white, lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
        .contentShape(Rectangle())
        .task(id: photo.id) {
            image = await photoLibrary.thumbnail(for: photo.id)
        }
    }
}
