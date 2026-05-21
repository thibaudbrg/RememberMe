import MapKit
import Persistence
import SwiftUI

/// Fullscreen Apple Maps view with one dot per unique visited place.
struct MapScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var cameraPosition: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $cameraPosition) {
            ForEach(environment.visitMarkers) { marker in
                Annotation(
                    "",
                    coordinate: CLLocationCoordinate2D(
                        latitude: marker.coordinate.latitude,
                        longitude: marker.coordinate.longitude
                    )
                ) {
                    VisitDot(visitCount: marker.visitCount)
                }
            }
        }
        .mapStyle(.standard(elevation: .realistic))
        .onChange(of: environment.visitMarkers) { _, newMarkers in
            recenter(on: newMarkers)
        }
        .task { recenter(on: environment.visitMarkers) }
    }

    private func recenter(on markers: [VisitMarker]) {
        guard !markers.isEmpty else { return }
        let lats = markers.map(\.coordinate.latitude)
        let lons = markers.map(\.coordinate.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else { return }

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.4, 0.05),
            longitudeDelta: max((maxLon - minLon) * 1.4, 0.05)
        )
        withAnimation(.easeInOut(duration: 0.6)) {
            cameraPosition = .region(MKCoordinateRegion(center: center, span: span))
        }
    }
}

private struct VisitDot: View {
    let visitCount: Int

    var body: some View {
        Circle()
            .fill(.tint)
            .stroke(.white, lineWidth: 1.5)
            .frame(width: dotSize, height: dotSize)
            .shadow(radius: 1.5, y: 0.5)
    }

    /// Scale dot size with visit frequency, with a floor for legibility on dense maps.
    private var dotSize: CGFloat {
        let base: CGFloat = 8
        let bonus: CGFloat = min(CGFloat(visitCount) * 0.6, 12)
        return base + bonus
    }
}

#Preview {
    MapScreen()
        .environment(AppEnvironment.preview())
        .ignoresSafeArea()
}
