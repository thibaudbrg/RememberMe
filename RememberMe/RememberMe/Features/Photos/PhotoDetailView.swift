import SwiftUI
import UIKit

/// Full-screen sheet for a tapped photo. Loads a higher-resolution version than the
/// map thumbnail.
struct PhotoDetailView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let photo: GeoPhoto

    @State private var image: UIImage?

    var body: some View {
        // Cache the photo library reference up-front so the .task closure doesn't have to
        // read it from Environment again.
        let library = environment.photoLibrary

        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    ProgressView().tint(.white)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.white)
                }
                ToolbarItem(placement: .principal) {
                    Text(photo.creationDate.formatted(date: .abbreviated, time: .shortened))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                }
            }
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .task {
            image = await library.thumbnail(
                for: photo.id,
                size: CGSize(width: 1600, height: 1600)
            )
        }
    }
}
