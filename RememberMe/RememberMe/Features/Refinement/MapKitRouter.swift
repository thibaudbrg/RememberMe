import Core
import Foundation
import MapKit

/// Errors surfaced by routing implementations. Used by both `MapKitRouter` and
/// `GoogleDirectionsRouter` so callers can treat them uniformly.
enum RoutingError: Error, LocalizedError {
    case tooClose
    case tooFar
    case noRoutes
    case transitUnsupportedByApple
    case missingAPIKey
    case network
    case throttled
    case cancelled
    case other(String)

    /// Sentinel substring that the history runner matches against `controller.state`'s
    /// failure message to detect rate-limiting and trigger back-off instead of skip.
    static let throttledSentinel = "rate-limit"

    var errorDescription: String? {
        switch self {
        case .tooClose: "Endpoints are too close together to route (under 100 m)."
        case .tooFar:   "Endpoints are too far apart for routing (over 1000 km)."
        case .noRoutes: "No route was found between these points."
        case .transitUnsupportedByApple:
            "Apple Maps doesn't return transit polylines via its public API. Switch to Google Maps in Alpha settings, or skip this trip."
        case .missingAPIKey:
            "Google Directions API key missing. Paste your key in Alpha settings."
        case .network:  "Couldn't reach the routing service. Check your internet connection."
        case .throttled:
            // Contains `throttledSentinel` so callers can string-match.
            "Apple Maps is rate-limiting us — waiting before retry."
        case .cancelled: "Routing cancelled."
        case let .other(message): message
        }
    }
}

/// Wraps `MKDirections` and returns plain `RouteCandidate` DTOs. Rounds the endpoint
/// coordinates before sending so we never leak full GPS precision to the routing endpoint.
@MainActor
final class MapKitRouter {
    private static let minDistanceMeters: Double = 100
    private static let maxDistanceMeters: Double = 1_000_000

    /// Round to 4 decimals (~11 m at the equator). Enough to identify a city block, not
    /// enough to identify a building.
    private static let endpointDecimals: Double = 10_000

    /// Fetches up to a handful of candidate routes from Apple Maps. The endpoint coordinates
    /// are rounded to 4 decimals before the request goes out.
    func fetchCandidates(
        start: Coordinate,
        end: Coordinate,
        mode: RefinementMode
    ) async throws -> [RouteCandidate] {
        let straightLine = PolylineDirection.haversineMeters(start, end)
        guard straightLine >= Self.minDistanceMeters else { throw RoutingError.tooClose }
        guard straightLine <= Self.maxDistanceMeters else { throw RoutingError.tooFar }

        let roundedStart = round(start)
        let roundedEnd = round(end)

        // Apple's MKDirections does NOT return transit polylines — confirmed by Apple DTS
        // (developer.apple.com/forums/thread/663624). `calculate()` with `.transit` always
        // fails. Surface that explicitly instead of silently routing transit trips as
        // driving (which is what the previous fallback did — misleading).
        if mode == .transit {
            throw RoutingError.transitUnsupportedByApple
        }

        return try await calculateOrThrow(
            from: roundedStart,
            to: roundedEnd,
            transport: transportType(for: mode),
            resolvedMode: mode,
            noResultError: .noRoutes
        )
    }

    /// Calls `calculate` and converts thrown / empty results into the supplied
    /// `noResultError`. Keeps the public `fetchCandidates` body free of error plumbing.
    private func calculateOrThrow(
        from start: Coordinate,
        to end: Coordinate,
        transport: MKDirectionsTransportType,
        resolvedMode: RefinementMode,
        noResultError: RoutingError
    ) async throws -> [RouteCandidate] {
        do {
            let candidates = try await calculate(
                from: start,
                to: end,
                transport: transport,
                resolvedMode: resolvedMode
            )
            if candidates.isEmpty { throw noResultError }
            return candidates
        } catch let error as RoutingError {
            throw error
        } catch let error as MKError {
            // "directionsNotFound" gets folded into the supplied no-result error so callers
            // (especially the transit fallback) can treat it uniformly with the empty case.
            if error.code == .directionsNotFound || error.code == .placemarkNotFound {
                throw noResultError
            }
            throw map(mkError: error)
        } catch is CancellationError {
            throw RoutingError.cancelled
        } catch {
            throw RoutingError.other(error.localizedDescription)
        }
    }

    // MARK: - Internals

    private func calculate(
        from start: Coordinate,
        to end: Coordinate,
        transport: MKDirectionsTransportType,
        resolvedMode: RefinementMode
    ) async throws -> [RouteCandidate] {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: clCoordinate(start)))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: clCoordinate(end)))
        request.transportType = transport
        request.requestsAlternateRoutes = true

        let directions = MKDirections(request: request)
        let response = try await directions.calculate()
        return response.routes.map { route in
            let coordinates = polyline(from: route.polyline)
            let notices = route.advisoryNotices
            // Apple's MKDirections is always single-mode for a given request — the whole
            // polyline is one segment with the requested transport type. Use the coarse
            // mode's rawValue as the displayMode (Apple doesn't expose finer vehicle data).
            let segment = RouteSegment(
                mode: resolvedMode,
                displayMode: resolvedMode.rawValue,
                coordinates: coordinates,
                travelTime: route.expectedTravelTime > 0 ? route.expectedTravelTime : nil,
                distanceMeters: route.distance > 0 ? route.distance : nil,
                label: nil
            )
            return RouteCandidate(
                coordinates: coordinates,
                expectedTravelTime: route.expectedTravelTime > 0 ? route.expectedTravelTime : nil,
                expectedDistanceMeters: route.distance > 0 ? route.distance : nil,
                name: route.name.isEmpty ? nil : route.name,
                advisoryNotices: notices,
                transportType: resolvedMode,
                segments: [segment]
            )
        }
    }

    private func polyline(from mkPolyline: MKPolyline) -> [Coordinate] {
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: mkPolyline.pointCount)
        mkPolyline.getCoordinates(&coords, range: NSRange(location: 0, length: mkPolyline.pointCount))
        return coords.map { Coordinate(latitude: $0.latitude, longitude: $0.longitude) }
    }

    private func round(_ coordinate: Coordinate) -> Coordinate {
        Coordinate(
            latitude: (coordinate.latitude * Self.endpointDecimals).rounded() / Self.endpointDecimals,
            longitude: (coordinate.longitude * Self.endpointDecimals).rounded() / Self.endpointDecimals
        )
    }

    private func clCoordinate(_ c: Coordinate) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude)
    }

    private func transportType(for mode: RefinementMode) -> MKDirectionsTransportType {
        switch mode {
        case .walking: .walking
        case .automobile: .automobile
        case .transit: .transit
        }
    }

    private func map(mkError: MKError) -> RoutingError {
        switch mkError.code {
        case .directionsNotFound: .noRoutes
        case .placemarkNotFound: .noRoutes
        case .loadingThrottled: .throttled
        case .serverFailure: .network
        default: .other(mkError.localizedDescription)
        }
    }
}
