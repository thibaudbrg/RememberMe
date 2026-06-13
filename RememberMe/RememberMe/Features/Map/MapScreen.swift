import Core
import MapKit
import Persistence
import SwiftUI

/// Fullscreen Apple Maps view, filtered to the day the user has selected in the drawer.
struct MapScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(Settings.self) private var settings
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var baseStyle: MapBaseStyle = .standard
    @State private var showLabels = true
    @State private var is3D = false
    @State private var showingSettings = false
    /// Most recent camera the user is looking at — captured from `onMapCameraChange`.
    /// Used by the 3D toggle (rebuilds the camera with a new pitch) and by the photo-cluster
    /// computation (its zoom threshold scales with `camera.distance`).
    @State private var currentCamera: MapCamera?
    @State private var selectedPhoto: GeoPhoto?
    @State private var selectedCluster: PhotoCluster?
    @State private var locationManager = LocateMeManager()
    /// True between a Locate Me tap with no cached fix and the fix arriving — so the first
    /// tap (when `lastKnown` is still nil) centers once the fresh fix lands.
    @State private var pendingLocate = false
    /// Photo clusters for the current day. Kept in @State and recomputed via onChange of its
    /// inputs (photos + camera distance) so the O(n²) clustering doesn't re-run on every body
    /// evaluation (e.g. every camera-gesture end).
    @State private var dayPhotoClusters: [PhotoCluster] = []

    var body: some View {
        @Bindable var env = environment

        GeometryReader { proxy in
            // ZStack so the right-edge buttons and the bottom Locate Me sit as siblings
            // of the Map. We tried scope-bound `MapCompass` placed in this stack so it
            // would land below the Settings button — Apple's docs claim it works, but in
            // practice (iOS 26) the compass never received heading updates from the Map.
            // Falling back to the system-placed compass via `.mapControls { MapCompass() }`,
            // which DOES rotate live and snap to north — at the cost of landing at the
            // top-right of the safe area (same column as the buttons, only appears when
            // the map is rotated).
            ZStack {
                Map(position: $cameraPosition) {
                    UserAnnotation()
                    tripPolylines
                    livePathPolyline
                    photoAnnotations
                    if settings.showDirectionArrows {
                        directionArrowAnnotations
                    }
                    visitMarkerAnnotations
                }
                .mapStyle(activeMapStyle)
                .mapControls {
                    MapCompass()
                }
                .ignoresSafeArea()
                .onChange(of: environment.selectedDay) { _, _ in recenter(in: proxy.size) }
                .onChange(of: environment.dayMarkers) { _, _ in reapplyCamera(in: proxy.size) }
                .onChange(of: environment.dayPhotos) { _, _ in reapplyCamera(in: proxy.size) }
                .onChange(of: environment.drawerSize) { _, _ in reapplyCamera(in: proxy.size) }
                .onChange(of: is3D) { _, _ in tiltCurrentView() }
                .onChange(of: locationManager.fixCount) { _, _ in
                    // First Locate Me tap had no cached fix; center now that one has arrived.
                    guard pendingLocate, let coordinate = locationManager.lastKnown else { return }
                    pendingLocate = false
                    centerOn(coordinate, in: proxy.size)
                }
                .onMapCameraChange(frequency: .onEnd) { context in
                    // Wrap in an animation so cluster recomputation (which depends on
                    // `currentCamera.distance`) fades clusters in/out smoothly when the
                    // zoom changes — without this they snap at the end of the pinch.
                    withAnimation(.easeInOut(duration: 0.4)) {
                        currentCamera = context.camera
                        recomputePhotoClusters()
                    }
                }
                .onChange(of: environment.dayPhotos) { _, _ in recomputePhotoClusters() }
                .onChange(of: environment.focusedItem) { _, item in
                    if let item { focus(on: item, in: proxy.size) } else { recenter(in: proxy.size) }
                }
                .task {
                    recenter(in: proxy.size)
                    recomputePhotoClusters()
                }
                .sheet(item: $env.selectedPlace, onDismiss: {
                    // When the user returns from a place detail, drop the map's focused item so the
                    // camera re-fits the whole day instead of staying zoomed in on the tapped marker.
                    environment.clearFocus()
                }) { marker in
                    PlaceDetailView(marker: marker)
                }
                .sheet(isPresented: $showingSettings) {
                    SettingsSheet()
                }
                .sheet(item: $selectedPhoto) { photo in
                    PhotoDetailView(photo: photo)
                }
                .sheet(item: $selectedCluster) { cluster in
                    PhotoCarouselView(photos: cluster.photos)
                }
                .task(id: environment.selectedDay) {
                    // Refresh photos whenever the day changes — no-op if the toggle is off.
                    await environment.loadDayPhotos(enabled: settings.showPhotosOnMap)
                }
                .task(id: environment.selectedRange) {
                    // Day / Week / Month switch widens `dayRange` without changing
                    // `selectedDay`, so the date-keyed task above wouldn't fire. Reload
                    // here so the grid + map cover the full visible window.
                    await environment.loadDayPhotos(enabled: settings.showPhotosOnMap)
                }
                .task(id: settings.showPhotosOnMap) {
                    await environment.loadDayPhotos(enabled: settings.showPhotosOnMap)
                }

                // Sibling 1 — top-right button stack. The system compass (from
                // `.mapControls { MapCompass() }` above) will appear at the top-right
                // of the safe area when the map is rotated, briefly visually adjacent
                // to these buttons.
                VStack(spacing: 10) {
                    MapLayersButton(
                        baseStyle: $baseStyle,
                        showLabels: $showLabels,
                        is3D: $is3D
                    )
                    SettingsButton { showingSettings = true }
                }
                .padding(.trailing, 12)
                .padding(.top, proxy.safeAreaInsets.top + 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

                // Sibling 2 — bottom-right "Locate me" floating button. Sits a generous
                // 24pt above the drawer so it stays fully visible at the .medium detent
                // (which is ~50% of screen height plus a few extra points in practice).
                LocateMeButton {
                    if let coordinate = locationManager.requestAndStartIfNeeded() {
                        centerOn(coordinate, in: proxy.size)
                    } else {
                        // No cached fix yet — wait for the one-shot request to deliver one.
                        pendingLocate = true
                    }
                }
                .padding(.trailing, 12)
                .padding(
                    .bottom,
                    environment.drawerSize.heightInPoints(screenHeight: proxy.size.height) + 72
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
    }

    // MARK: - Map style

    /// 3D buildings are ALWAYS on — we use `.realistic` elevation regardless of base style.
    /// The user-facing "3D" toggle controls camera *pitch* (tilt), handled separately when
    /// animating the camera.
    private var activeMapStyle: MapStyle {
        let elevation: MapStyle.Elevation = .realistic
        let poi: PointOfInterestCategories = showLabels ? .all : .excludingAll
        switch baseStyle {
        case .standard:
            return .standard(elevation: elevation, pointsOfInterest: poi)
        case .transit:
            // SwiftUI Map has no dedicated `.transit` style. The closest match is a muted
            // standard map with public-transport POIs surfaced — even when "labels off" we
            // keep the transit POIs visible because that's the whole point of the mode.
            return .standard(
                elevation: elevation,
                emphasis: .muted,
                pointsOfInterest: showLabels ? .all : .including([.publicTransport])
            )
        case .satellite:
            return showLabels
                ? .hybrid(elevation: elevation)
                : .imagery(elevation: elevation)
        }
    }

    // MARK: - Map content builders

    @MapContentBuilder
    private var tripPolylines: some MapContent {
        ForEach(environment.dayTripRenders) { render in
            MapPolyline(coordinates: render.coordinates.map(asCLLocationCoordinate))
                .stroke(settings.accent.color, style: strokeStyle(for: render.mode))
        }
    }

    /// In-progress trip breadcrumb from the live tracker — a dashed provisional
    /// line up to the latest GPS fix. Only shown when the visible range covers
    /// "now"; it disappears when the trip closes (the persisted path replaces it).
    @MapContentBuilder
    private var livePathPolyline: some MapContent {
        let live = environment.tracker.livePathCoordinates
        if live.count >= 2, environment.dayRange.contains(Date()) {
            MapPolyline(coordinates: live.map(asCLLocationCoordinate))
                .stroke(
                    settings.accent.color.opacity(0.7),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round, dash: [6, 6])
                )
        }
    }

    /// Recomputes `dayPhotoClusters` from the current photos + camera zoom. Called from
    /// onChange of those inputs so clustering stays out of `body`. The threshold (in metres)
    /// tracks pixel density on screen: at deep zoom every photo becomes its own cluster; at
    /// neighbourhood zoom photos taken at the same café merge into one badge-decorated icon.
    private func recomputePhotoClusters() {
        dayPhotoClusters = PhotoCluster.cluster(
            environment.dayPhotos,
            cameraDistance: currentCamera?.distance
        )
    }

    @MapContentBuilder
    private var photoAnnotations: some MapContent {
        ForEach(dayPhotoClusters) { cluster in
            Annotation(
                "",
                coordinate: CLLocationCoordinate2D(
                    latitude: cluster.coordinate.latitude,
                    longitude: cluster.coordinate.longitude
                )
            ) {
                PhotoClusterThumbnail(cluster: cluster, photoLibrary: environment.photoLibrary)
                    .onTapGesture {
                        if cluster.photos.count == 1 {
                            selectedPhoto = cluster.photos[0]
                        } else {
                            selectedCluster = cluster
                        }
                    }
            }
            .annotationTitles(.hidden)
        }
    }

    @MapContentBuilder
    private var directionArrowAnnotations: some MapContent {
        ForEach(environment.dayDirectionMarkers) { marker in
            Annotation(
                "",
                coordinate: CLLocationCoordinate2D(
                    latitude: marker.coordinate.latitude,
                    longitude: marker.coordinate.longitude
                )
            ) {
                DirectionChevron(bearingDegrees: marker.bearingDegrees)
            }
            .annotationTitles(.hidden)
        }
    }

    @MapContentBuilder
    private var visitMarkerAnnotations: some MapContent {
        // dedupedDayMarkers collapses repeated visits to the same named place within a short
        // window — the polylines and timeline still use the raw `dayMarkers`.
        ForEach(environment.dedupedDayMarkers) { marker in
            Annotation(
                "",
                coordinate: CLLocationCoordinate2D(
                    latitude: marker.coordinate.latitude,
                    longitude: marker.coordinate.longitude
                )
            ) {
                VisitDot(visitCount: marker.visitCount, color: settings.accent.color)
                    .onTapGesture { environment.selectedPlace = marker }
                    .accessibilityLabel(marker.resolvedLabel ?? "Unnamed place")
                    .accessibilityAddTraits(.isButton)
            }
        }
    }

    // MARK: - Polyline rendering

    private func strokeStyle(for mode: String) -> StrokeStyle {
        // Every trip is just a solid line now — the dashed walking variant has been retired.
        StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
    }

    private func asCLLocationCoordinate(_ coord: Coordinate) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: coord.latitude, longitude: coord.longitude)
    }

    // MARK: - Camera

    private func reapplyCamera(in screenSize: CGSize) {
        if let item = environment.focusedItem {
            focus(on: item, in: screenSize)
        } else {
            recenter(in: screenSize)
        }
    }

    private func recenter(in screenSize: CGSize) {
        let coordinates = collectDayCoordinates()
        guard let region = fittedRegion(
            for: coordinates,
            minimumSpan: 0.01,
            screenSize: screenSize
        ) else { return }
        animateCamera(to: region)
    }

    private func focus(on item: AppEnvironment.MapFocusItem, in screenSize: CGSize) {
        switch item {
        case let .visit(_, coordinate):
            // Tapping a visit dot or row opens `PlaceDetailView`, which presents at
            // `.medium` regardless of what the bottom drawer was on. Compute the camera
            // shift against that detent so the dot ends up centered in the visible map area
            // above the new sheet — not the small detent's much larger map area.
            let mediumHeight = AppEnvironment.DrawerSize.medium.heightInPoints(
                screenHeight: screenSize.height
            )
            let region = drawerAdjusted(
                center: CLLocationCoordinate2D(
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude
                ),
                rawSpan: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01),
                screenSize: screenSize,
                drawerHeightOverride: mediumHeight
            )
            animateCamera(to: region)

        case let .trip(id):
            guard let trip = environment.dayTrips.first(where: { $0.id == id }) else { return }
            // Slice the covering path's points down to this activity's time window so a short
            // walk inside a 2-hour path zooms to the walk, not to the whole path.
            let coordinates = TripRenderPlan.focusCoordinates(
                for: trip,
                paths: environment.dayPathTraces,
                refinedByActivity: environment.dayRefinedPolylines
            )
            let points = coordinates.map(asCLLocationCoordinate)
            if let region = fittedRegion(for: points, minimumSpan: 0.005, screenSize: screenSize) {
                animateCamera(to: region)
            }

        case let .path(id):
            guard let trace = environment.dayPathTraces.first(where: { $0.id == id }) else { return }
            let points = trace.points.map(asCLLocationCoordinate)
            if let region = fittedRegion(for: points, minimumSpan: 0.005, screenSize: screenSize) {
                animateCamera(to: region)
            }

        case let .photo(_, coordinate):
            let region = drawerAdjusted(
                center: CLLocationCoordinate2D(
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude
                ),
                rawSpan: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008),
                screenSize: screenSize
            )
            animateCamera(to: region)
        }
    }

    private func collectDayCoordinates() -> [CLLocationCoordinate2D] {
        var result: [CLLocationCoordinate2D] = []
        result.append(contentsOf: environment.dayMarkers.map { asCLLocationCoordinate($0.coordinate) })
        result.append(contentsOf: environment.dayTrips.flatMap {
            [asCLLocationCoordinate($0.startCoordinate), asCLLocationCoordinate($0.endCoordinate)]
        })
        result.append(contentsOf: environment.dayPathTraces.flatMap { $0.points.map(asCLLocationCoordinate) })
        result.append(contentsOf: environment.dayPhotos.map { asCLLocationCoordinate($0.coordinate) })
        return result
    }

    private func fittedRegion(
        for coordinates: [CLLocationCoordinate2D],
        minimumSpan: Double,
        screenSize: CGSize
    ) -> MKCoordinateRegion? {
        guard !coordinates.isEmpty else { return nil }
        let lats = coordinates.map(\.latitude)
        let lons = coordinates.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else { return nil }
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let rawSpan = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.4, minimumSpan),
            longitudeDelta: max((maxLon - minLon) * 1.4, minimumSpan)
        )
        return drawerAdjusted(center: center, rawSpan: rawSpan, screenSize: screenSize)
    }

    private func drawerAdjusted(
        center: CLLocationCoordinate2D,
        rawSpan: MKCoordinateSpan,
        screenSize: CGSize,
        drawerHeightOverride: CGFloat? = nil
    ) -> MKCoordinateRegion {
        let screenH = max(screenSize.height, 1)
        let drawerH = drawerHeightOverride
            ?? environment.drawerSize.heightInPoints(screenHeight: screenH)
        let visibleH = max(screenH - drawerH, screenH * 0.25)

        let scale = screenH / visibleH
        let adjustedLatSpan = rawSpan.latitudeDelta * scale
        let shift = adjustedLatSpan * (drawerH / 2) / screenH
        let adjustedCenter = CLLocationCoordinate2D(
            latitude: center.latitude - shift,
            longitude: center.longitude
        )
        return MKCoordinateRegion(
            center: adjustedCenter,
            span: MKCoordinateSpan(
                latitudeDelta: adjustedLatSpan,
                longitudeDelta: rawSpan.longitudeDelta
            )
        )
    }

    private func animateCamera(to region: MKCoordinateRegion) {
        withAnimation(.easeInOut(duration: 0.55)) {
            cameraPosition = is3D
                ? .camera(tiltedCamera(for: region))
                : .region(region)
        }
    }

    /// Tilts or untilts the current view in place — keeps the SAME center / distance /
    /// heading, only changes pitch. Doesn't re-fit any bbox.
    ///
    /// We rebuild from `currentCamera` (not the projected region) because a tilted camera's
    /// projected region is much larger than the visible content — using it to untilt would
    /// zoom out instead of just flattening.
    private func tiltCurrentView() {
        guard let camera = currentCamera else { return }
        let rebuilt = MapCamera(
            centerCoordinate: camera.centerCoordinate,
            distance: camera.distance,
            heading: camera.heading,
            pitch: is3D ? 60 : 0
        )
        withAnimation(.easeInOut(duration: 0.4)) {
            cameraPosition = .camera(rebuilt)
        }
    }

    /// Builds a tilted `MapCamera` that frames roughly the same area as `region`. Distance is
    /// derived from the lat span — at this latitude, 1° ≈ 111 km. A pitch of 60° gives the
    /// Apple-Maps-style perspective view without flattening the buildings.
    private func tiltedCamera(for region: MKCoordinateRegion) -> MapCamera {
        let latMeters = region.span.latitudeDelta * 111_000
        // Camera "distance" is the diagonal-ish distance from camera to the focal point. With
        // a tilt of 60° we need ~1.5× the region height to fit comfortably.
        let distance = max(latMeters * 1.5, 300)
        return MapCamera(
            centerCoordinate: region.center,
            distance: distance,
            heading: 0,
            pitch: 60
        )
    }

    /// Centers the map tightly on a single coordinate, respecting the drawer.
    private func centerOn(_ coordinate: CLLocationCoordinate2D, in size: CGSize) {
        let region = drawerAdjusted(
            center: coordinate,
            rawSpan: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01),
            screenSize: size
        )
        animateCamera(to: region)
    }
}

// MARK: - Direction chevron

/// A small, gentle arrowhead placed at intervals along a trip polyline to hint at the
/// direction the user was moving. White with a soft shadow so it sits *on* the line
/// regardless of the line's accent color.
private struct DirectionChevron: View {
    /// Compass bearing in degrees from north, clockwise.
    let bearingDegrees: Double

    var body: some View {
        // 3× smaller than the original 9pt — barely there, just a hint.
        Image(systemName: "arrowtriangle.up.fill")
            .font(.system(size: 3, weight: .black))
            .foregroundStyle(.white.opacity(0.9))
            .shadow(color: .black.opacity(0.25), radius: 0.5, y: 0.25)
            .rotationEffect(.degrees(bearingDegrees))
            .allowsHitTesting(false)
    }
}

// MARK: - Visit dot

private struct VisitDot: View {
    let visitCount: Int
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .stroke(.white, lineWidth: 1.5)
            .frame(width: dotSize, height: dotSize)
            .shadow(radius: 1.5, y: 0.5)
            .contentShape(Circle())
    }

    private var dotSize: CGFloat {
        // Half the previous size — visit dots were dominating the map.
        let base: CGFloat = 7
        let bonus: CGFloat = min(CGFloat(visitCount) * 0.3, 5)
        return base + bonus
    }
}

// MARK: - Floating buttons

enum MapBaseStyle: String, CaseIterable, Identifiable {
    case standard, transit, satellite
    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: "Standard"
        case .transit: "Transit"
        case .satellite: "Satellite"
        }
    }

    var symbol: String {
        switch self {
        case .standard: "map"
        case .transit: "tram.fill"
        case .satellite: "globe.americas.fill"
        }
    }
}

private struct MapLayersButton: View {
    @Binding var baseStyle: MapBaseStyle
    @Binding var showLabels: Bool
    @Binding var is3D: Bool

    var body: some View {
        Menu {
            Picker("Style", selection: $baseStyle) {
                ForEach(MapBaseStyle.allCases) { style in
                    Label(style.label, systemImage: style.symbol).tag(style)
                }
            }
            Divider()
            Toggle(isOn: $showLabels) {
                Label("Show labels", systemImage: "textformat")
            }
            Toggle(isOn: $is3D) {
                Label("3D view", systemImage: "view.3d")
            }
        } label: {
            FloatingMapButton(symbol: "square.3.layers.3d")
        }
        .accessibilityLabel("Map style")
    }
}

private struct SettingsButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            FloatingMapButton(symbol: "gearshape")
        }
        .accessibilityLabel("Settings")
    }
}

private struct FloatingMapButton: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(10)
            .background(.thinMaterial, in: Circle())
            .shadow(radius: 2, y: 1)
    }
}

#Preview {
    MapScreen()
        .environment(AppEnvironment.preview())
        .environment(Settings())
        .ignoresSafeArea()
}
