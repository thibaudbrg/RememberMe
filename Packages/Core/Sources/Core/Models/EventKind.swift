import Foundation

/// What a given event *is*. Discriminator + payload.
public enum EventKind: Hashable, Sendable {
    case activity(ActivityDetails)
    case visit(VisitDetails)
    case path([PathPoint])
}

public extension EventKind {
    /// Stable string used by the persistence layer's `kind` column and CHECK constraint.
    var discriminator: String {
        switch self {
        case .activity: "activity"
        case .visit: "visit"
        case .path: "path"
        }
    }
}
