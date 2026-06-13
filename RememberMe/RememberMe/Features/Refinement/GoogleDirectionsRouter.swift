import Core
import Foundation

/// HTTP client for RememberMe's route proxy (a Cloudflare Worker that forwards to the
/// Google Directions API with a developer-held key, so no credential ever lives on
/// devices). The response body is Google's Directions JSON — trimmed by the proxy to the
/// fields parsed below — so the wire types in this file decode it unchanged.
///
/// Requests are authenticated with App Attest assertions (`AppAttestService`): the proxy
/// serves only genuine builds of this app. It never receives any identity — see PRIVACY.md.
@MainActor
final class RouteProxyRouter {
    /// The proxy host. Neutral name, hardcoded — end users never see or configure it.
    private static let workerBase = URL(string: "https://rm-route-proxy.thibaud-bourgeois25.workers.dev")!
    private static var routeURL: URL { workerBase.appending(path: "v1/route") }
    private static let minDistanceMeters: Double = 100
    private static let maxDistanceMeters: Double = 1_000_000
    private static let endpointDecimals: Double = 10_000

    private let urlSession: URLSession
    private let attest: AppAttestService

    init(urlSession: URLSession = .shared, attest: AppAttestService? = nil) {
        self.urlSession = urlSession
        self.attest = attest ?? AppAttestService(workerBase: Self.workerBase, urlSession: urlSession)
    }

    /// Asks the route proxy for one or more routes between the rounded endpoints.
    func fetchCandidates(
        start: Coordinate,
        end: Coordinate,
        mode: RefinementMode
    ) async throws -> [RouteCandidate] {
        let straightLine = PolylineDirection.haversineMeters(start, end)
        guard straightLine >= Self.minDistanceMeters else { throw RoutingError.tooClose }
        guard straightLine <= Self.maxDistanceMeters else { throw RoutingError.tooFar }

        do {
            return try await performFetch(start: start, end: end, mode: mode)
        } catch RoutingError.attestationUnavailable {
            // The server may have evicted our attested key (storage reset, rotation).
            // Re-attest once with a fresh key before giving up.
            attest.invalidate()
            return try await performFetch(start: start, end: end, mode: mode)
        }
    }

    private func performFetch(
        start: Coordinate,
        end: Coordinate,
        mode: RefinementMode
    ) async throws -> [RouteCandidate] {
        // Fixed 4-decimal formatting (~11 m precision): privacy rounding, and the proxy
        // validates coordinates against a ≤6-decimal pattern.
        let body: [String: Any] = [
            "origin": String(format: "%.4f,%.4f", round(start).latitude, round(start).longitude),
            "destination": String(format: "%.4f,%.4f", round(end).latitude, round(end).longitude),
            "mode": googleMode(for: mode),
            "alternatives": true,
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        var request = URLRequest(
            url: Self.routeURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 20
        )
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (header, value) in try await attest.authHeaders(for: bodyData) {
            request.setValue(value, forHTTPHeaderField: header)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch is CancellationError {
            throw RoutingError.cancelled
        } catch {
            throw RoutingError.network
        }

        guard let http = response as? HTTPURLResponse else { throw RoutingError.network }
        switch http.statusCode {
        case 200 ..< 300:
            break
        case 401, 403:
            throw RoutingError.attestationUnavailable
        case 429:
            throw RoutingError.throttledGoogle
        case 500 ..< 600:
            throw RoutingError.network
        default:
            throw RoutingError.other("Route proxy HTTP \(http.statusCode)")
        }

        let decoded: GoogleDirectionsResponse
        do {
            decoded = try JSONDecoder().decode(GoogleDirectionsResponse.self, from: data)
        } catch {
            throw RoutingError.other("Couldn't parse Google response.")
        }

        switch decoded.status {
        case "OK":
            break
        case "ZERO_RESULTS":
            throw RoutingError.noRoutes
        case "REQUEST_DENIED", "INVALID_REQUEST":
            throw RoutingError.other(decoded.errorMessage ?? "Google rejected the request (\(decoded.status)).")
        case "OVER_QUERY_LIMIT", "OVER_DAILY_LIMIT":
            throw RoutingError.throttledGoogle
        default:
            throw RoutingError.other(decoded.errorMessage ?? "Google: \(decoded.status)")
        }

        return decoded.routes.map { route in
            let coordinates = GooglePolyline.decode(route.overviewPolyline.points)
            let totalTime = route.legs.reduce(0) { $0 + ($1.duration?.value ?? 0) }
            let totalDistance = route.legs.reduce(0) { $0 + ($1.distance?.value ?? 0) }
            let advisories = route.warnings ?? []
            let segments = extractSegments(from: route, requestedMode: mode)
            let primaryMode = primaryMode(of: segments) ?? mode
            return RouteCandidate(
                coordinates: coordinates,
                expectedTravelTime: totalTime > 0 ? TimeInterval(totalTime) : nil,
                expectedDistanceMeters: totalDistance > 0 ? Double(totalDistance) : nil,
                name: route.summary,
                advisoryNotices: advisories,
                transportType: primaryMode,
                segments: segments
            )
        }
    }

    /// Flatten every leg's steps into per-segment `RouteSegment`s. Coalesces consecutive
    /// steps that share the same coarse mode so a 3-step walk doesn't become 3 segments.
    private func extractSegments(
        from route: GoogleDirectionsResponse.Route,
        requestedMode: RefinementMode
    ) -> [RouteSegment] {
        var raw: [RouteSegment] = []
        for leg in route.legs {
            guard let steps = leg.steps else { continue }
            for step in steps {
                let segmentMode = mapStepMode(step.travelMode) ?? requestedMode
                let coords = GooglePolyline.decode(step.polyline.points)
                guard coords.count >= 2 else { continue }
                let label = transitLabel(for: step)
                raw.append(RouteSegment(
                    mode: segmentMode,
                    displayMode: stepDisplayMode(step),
                    coordinates: coords,
                    travelTime: step.duration.map { TimeInterval($0.value) },
                    distanceMeters: step.distance.map { Double($0.value) },
                    label: label
                ))
            }
        }
        // If we somehow got no steps, fall back to a single segment from the overview.
        if raw.isEmpty {
            let coords = GooglePolyline.decode(route.overviewPolyline.points)
            return [RouteSegment(
                mode: requestedMode,
                displayMode: requestedMode.rawValue,
                coordinates: coords,
                travelTime: nil,
                distanceMeters: nil,
                label: nil
            )]
        }
        // Coalesce consecutive same-mode segments. A walk often comes back as 4–8 steps
        // ("turn left", "turn right"…); we only care about mode boundaries here.
        var merged: [RouteSegment] = []
        for segment in raw {
            if var prev = merged.last,
               prev.mode == segment.mode,
               prev.displayMode == segment.displayMode,
               prev.label == nil, segment.label == nil
            {
                let coords = prev.coordinates + segment.coordinates.dropFirst() // avoid dup join point
                let time = (prev.travelTime ?? 0) + (segment.travelTime ?? 0)
                let dist = (prev.distanceMeters ?? 0) + (segment.distanceMeters ?? 0)
                prev = RouteSegment(
                    mode: prev.mode,
                    displayMode: prev.displayMode,
                    coordinates: Array(coords),
                    travelTime: time > 0 ? time : nil,
                    distanceMeters: dist > 0 ? dist : nil,
                    label: nil
                )
                merged[merged.count - 1] = prev
            } else {
                merged.append(segment)
            }
        }
        return merged
    }

    /// Maps a Google Directions step to the granular mode string stored in
    /// `activities.mode`. Handles TRANSIT step's `vehicle.type` enum so a Paris RER
    /// becomes "train" instead of the verbose "Commuter train".
    private func stepDisplayMode(_ step: GoogleDirectionsResponse.Step) -> String {
        switch step.travelMode?.uppercased() {
        case "WALKING":   return "walking"
        case "DRIVING":   return "driving"
        case "BICYCLING": return "cycling"
        case "TRANSIT":
            switch step.transitDetails?.line?.vehicle?.type?.uppercased() {
            case "BUS", "INTERCITY_BUS", "TROLLEYBUS", "SHARE_TAXI":
                return "bus"
            case "SUBWAY", "METRO_RAIL":
                return "subway"
            case "TRAM", "MONORAIL":
                return "tram"
            case "FERRY":
                return "ferry"
            case "FUNICULAR", "GONDOLA_LIFT", "CABLE_CAR":
                return "cable car"
            case "COMMUTER_TRAIN", "HEAVY_RAIL", "HIGH_SPEED_TRAIN",
                 "LONG_DISTANCE_TRAIN", "RAIL":
                return "train"
            default:
                return "transit"
            }
        default: return "transit"
        }
    }

    private func mapStepMode(_ raw: String?) -> RefinementMode? {
        switch raw?.uppercased() {
        case "WALKING": .walking
        case "DRIVING": .automobile
        case "BICYCLING": .walking // we don't have a bike bucket; group with walking
        case "TRANSIT": .transit
        default: nil
        }
    }

    /// "Bus 38", "Subway Line 4", etc. — pulled from Google's transit details when
    /// available. Returns nil for non-transit steps (the mode label is enough).
    private func transitLabel(for step: GoogleDirectionsResponse.Step) -> String? {
        guard let transit = step.transitDetails else { return nil }
        let vehicle = transit.line?.vehicle?.name ?? transit.line?.vehicle?.type?.capitalized
        let lineName = transit.line?.shortName ?? transit.line?.name
        switch (vehicle, lineName) {
        case let (.some(v), .some(l)): return "\(v) \(l)"
        case let (.some(v), nil):      return v
        case let (nil, .some(l)):      return l
        default:                       return nil
        }
    }

    /// Returns the mode that contributes the most travel time across all segments. Used
    /// as the route's "primary" mode for the timeline icon when we don't want to show
    /// every leg.
    private func primaryMode(of segments: [RouteSegment]) -> RefinementMode? {
        var totals: [RefinementMode: TimeInterval] = [:]
        for segment in segments {
            totals[segment.mode, default: 0] += segment.travelTime ?? 0
        }
        return totals.max(by: { $0.value < $1.value })?.key
    }

    // MARK: - Internals

    private func round(_ coordinate: Coordinate) -> Coordinate {
        Coordinate(
            latitude: (coordinate.latitude * Self.endpointDecimals).rounded() / Self.endpointDecimals,
            longitude: (coordinate.longitude * Self.endpointDecimals).rounded() / Self.endpointDecimals
        )
    }

    private func googleMode(for mode: RefinementMode) -> String {
        switch mode {
        case .walking: "walking"
        case .automobile: "driving"
        case .transit: "transit"
        }
    }
}

// MARK: - JSON wire types

struct GoogleDirectionsResponse: Decodable {
    let status: String
    let errorMessage: String?
    let routes: [Route]

    enum CodingKeys: String, CodingKey {
        case status
        case errorMessage = "error_message"
        case routes
    }

    struct Route: Decodable {
        let summary: String?
        let warnings: [String]?
        let overviewPolyline: Polyline
        let legs: [Leg]

        enum CodingKeys: String, CodingKey {
            case summary
            case warnings
            case overviewPolyline = "overview_polyline"
            case legs
        }
    }

    struct Polyline: Decodable {
        let points: String
    }

    struct Leg: Decodable {
        let duration: Quantity?
        let distance: Quantity?
        let steps: [Step]?
    }

    struct Step: Decodable {
        let travelMode: String?
        let polyline: Polyline
        let duration: Quantity?
        let distance: Quantity?
        let transitDetails: TransitDetails?

        enum CodingKeys: String, CodingKey {
            case travelMode = "travel_mode"
            case polyline
            case duration
            case distance
            case transitDetails = "transit_details"
        }
    }

    struct TransitDetails: Decodable {
        let line: Line?
    }

    struct Line: Decodable {
        let name: String?
        let shortName: String?
        let vehicle: Vehicle?

        enum CodingKeys: String, CodingKey {
            case name
            case shortName = "short_name"
            case vehicle
        }
    }

    struct Vehicle: Decodable {
        let name: String?
        let type: String?
    }

    struct Quantity: Decodable {
        let value: Int
    }
}
