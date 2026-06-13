import Foundation

/// Errors surfaced by the routing layer (`RouteProxyRouter`). Callers treat them uniformly:
/// `isNoRoute` outcomes persist a skip row, `isTransient` outcomes back off and retry.
enum RoutingError: Error, LocalizedError {
    case tooClose
    case tooFar
    case noRoutes
    case attestationUnavailable
    case network
    case throttledGoogle
    case cancelled
    case other(String)

    /// True for genuine "this trip can't be routed" outcomes. The history runner persists a
    /// skip row for these (and excludes the trip from future runs). Transient failures
    /// (`.network`, throttling) and configuration failures (`.attestationUnavailable`) are NOT here.
    var isNoRoute: Bool {
        switch self {
        case .tooClose, .tooFar, .noRoutes: true
        default: false
        }
    }

    /// True for transient failures the history runner should back off and retry rather than
    /// skip: lost connectivity and routing-service rate limiting.
    var isTransient: Bool {
        switch self {
        case .network, .throttledGoogle: true
        default: false
        }
    }

    var errorDescription: String? {
        switch self {
        case .tooClose: "Endpoints are too close together to route (under 100 m)."
        case .tooFar:   "Endpoints are too far apart for routing (over 1000 km)."
        case .noRoutes: "No route was found between these points."
        case .attestationUnavailable:
            "This build can't reach the routing service. Update to a release build from the App Store, then try again."
        case .network:  "Couldn't reach the routing service. Check your internet connection."
        case .throttledGoogle:
            "The routing service is rate-limiting us — waiting before retry."
        case .cancelled: "Routing cancelled."
        case let .other(message): message
        }
    }
}
