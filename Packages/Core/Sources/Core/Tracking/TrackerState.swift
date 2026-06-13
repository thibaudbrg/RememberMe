import Foundation

/// Discrete states the live background tracker can be in. Modelled after the
/// LocoKit / Arc-App template documented in `docs/research/background-location-tracking.md`:
///
/// - `.off` — not authorized or user-disabled. Every monitor torn down.
/// - `.deepSleep` — long stationary or fresh launch. Only SLC + visit monitoring armed
///   (these are the iOS APIs that wake a terminated app). Zero GPS, zero motion.
/// - `.waking` — a tripwire fired (SLC or visit-depart). Probe GPS + motion briefly to
///   decide whether the user is actually moving.
/// - `.tracking` — motion confirms movement. Full-accuracy GPS, motion classifier running,
///   trip buffer open.
/// - `.stationary` — motion settled while in `.tracking`. GPS off, motion still on,
///   waiting either for motion to resume (back to `.tracking`) or for the 15-min
///   deep-sleep cutover.
public enum TrackerState: String, Sendable, Equatable, CaseIterable {
    case off
    case deepSleep
    case waking
    case tracking
    case stationary
}

/// Coarse GPS accuracy band the state machine asks the runtime for. The Phase 5
/// adapter maps these to `kCLLocationAccuracy*` constants.
public enum TrackerAccuracy: String, Sendable, Equatable, CaseIterable {
    /// Full-accuracy navigation-grade fixes (~1 Hz). Used in `.tracking`.
    case best
    /// Coarse probe fix (~100 m). Used in `.waking` to decide if we should commit
    /// to `.tracking` without burning battery on a full GPS lock.
    case probe
}

/// Inputs the state machine reacts to. The runtime translates real-world events
/// (CLLocationManager delegate callbacks, CMMotion updates, user toggles, timers)
/// into one of these.
public enum TrackerInput: Sendable, Equatable {
    /// User flipped the "Live tracking" toggle in Settings.
    case userToggled(Bool)
    /// `CLLocationManager.authorizationStatus` changed. `true` iff the new value
    /// is `.authorizedAlways` — the only level that satisfies our hard requirement.
    case authorizationChanged(authorizedAlways: Bool)
    /// `startMonitoringSignificantLocationChanges` fired (≥ 500 m / ≥ 5 min movement).
    case significantLocationChange
    /// A `CLVisit` arrival was reported.
    case visitArrived
    /// A `CLVisit` departure was reported.
    case visitDeparted
    /// `CMMotionActivityManager` reported a moving activity (walking, automotive, etc.).
    case motionMoving
    /// `CMMotionActivityManager` reported the device is stationary.
    case motionStationary
    /// The 180-second stationary timer (started by the runtime when motion goes
    /// stationary in `.tracking`) fired without being cancelled.
    case sleepThresholdReached
    /// The 15-minute stationary timer (started on entry to `.stationary`) fired
    /// without being cancelled — time to go to `.deepSleep`.
    case deepSleepThresholdReached
    /// The ~60-second `.waking` probe timer fired without motion (or an SLC/visit)
    /// ever confirming movement — fall back to `.stationary` so we don't sit in
    /// `.waking` with probe GPS armed forever (e.g. when Motion & Fitness is denied).
    case wakingProbeTimedOut
}

/// Side-effects the state machine asks the runtime to apply when entering a new
/// state. The runtime is responsible for idempotency: re-asking for an already-armed
/// monitor must be a no-op, and disarming an already-disarmed monitor likewise.
public enum TrackerAction: Sendable, Equatable {
    case armSignificantChanges
    case disarmSignificantChanges
    case armVisits
    case disarmVisits
    case armMotion
    case disarmMotion
    case armFullGPS(TrackerAccuracy)
    case disarmFullGPS
    /// Start the 15-minute "you've been stationary long enough — go to deep sleep" timer.
    case startDeepSleepThresholdTimer
    case cancelDeepSleepThresholdTimer
    /// Cancel the 180-second "motion has been stationary long enough — close the trip"
    /// timer. The runtime starts this timer on its own when motion goes stationary in
    /// `.tracking`; the state machine only asks for cancellation on state changes.
    case cancelSleepThresholdTimer
    /// Begin a new trip: assign an event id, prime the buffer.
    case openTrip
    /// Finalise the open trip (if any): finalise end time, mode, write events.
    case closeTrip
}

/// External flags the state machine consults that are not direct inputs (they're
/// "ambient" — they persist across inputs and are updated lazily).
public struct TrackerEnvironment: Sendable, Equatable {
    public var enabled: Bool
    public var authorizedAlways: Bool

    public init(enabled: Bool, authorizedAlways: Bool) {
        self.enabled = enabled
        self.authorizedAlways = authorizedAlways
    }

    public static let initial = TrackerEnvironment(enabled: false, authorizedAlways: false)
}

/// Result of feeding one input into the state machine.
public struct TrackerTransition: Sendable, Equatable {
    public let newState: TrackerState
    public let environment: TrackerEnvironment
    public let actions: [TrackerAction]

    public init(newState: TrackerState, environment: TrackerEnvironment, actions: [TrackerAction]) {
        self.newState = newState
        self.environment = environment
        self.actions = actions
    }
}

/// Pure state-machine logic. The runtime owns the actual `CLLocationManager`,
/// `CMMotionActivityManager`, and timers; it feeds inputs to this type and applies
/// the actions returned. No iOS framework imports here on purpose — keeps the core
/// logic testable in isolation and on any platform.
public enum TrackerStateMachine {
    /// Feed one input. Returns the new state, the updated ambient environment, and
    /// the actions the runtime should apply (in order). If no state change happens,
    /// `actions` is empty — actions only fire on entry to a new state.
    public static func next(
        from state: TrackerState,
        environment env: TrackerEnvironment,
        input: TrackerInput
    ) -> TrackerTransition {
        let updatedEnv = applyEnvironmentUpdate(env, input)

        // Disabled or unauthorized always wins — collapse to .off.
        if !updatedEnv.enabled || !updatedEnv.authorizedAlways {
            return TrackerTransition(
                newState: .off,
                environment: updatedEnv,
                actions: state == .off ? [] : entryActions(.off)
            )
        }

        // From .off, the first input that arrives while enabled+authorized takes us
        // to .deepSleep. The state machine doesn't care WHICH input — any event that
        // arrives means we're alive again.
        if state == .off {
            return TrackerTransition(
                newState: .deepSleep,
                environment: updatedEnv,
                actions: entryActions(.deepSleep)
            )
        }

        let target = handleInput(state: state, input: input)
        return TrackerTransition(
            newState: target,
            environment: updatedEnv,
            actions: target == state ? [] : entryActions(target)
        )
    }

    /// The full goal action set the runtime should reconcile to on entry into
    /// `state`. The runtime is responsible for diff-ing against current hardware
    /// state and treating already-armed/already-disarmed as no-ops.
    public static func entryActions(_ state: TrackerState) -> [TrackerAction] {
        switch state {
        case .off:
            return [
                .disarmSignificantChanges,
                .disarmVisits,
                .disarmMotion,
                .disarmFullGPS,
                .cancelSleepThresholdTimer,
                .cancelDeepSleepThresholdTimer,
                .closeTrip,
            ]
        case .deepSleep:
            return [
                .armSignificantChanges,
                .armVisits,
                .disarmMotion,
                .disarmFullGPS,
                .cancelSleepThresholdTimer,
                .cancelDeepSleepThresholdTimer,
                .closeTrip,
            ]
        case .waking:
            return [
                .armSignificantChanges,
                .armVisits,
                .armMotion,
                .armFullGPS(.probe),
                .cancelSleepThresholdTimer,
                .cancelDeepSleepThresholdTimer,
            ]
        case .tracking:
            return [
                .armSignificantChanges,
                .armVisits,
                .armMotion,
                .armFullGPS(.best),
                .cancelSleepThresholdTimer,
                .cancelDeepSleepThresholdTimer,
                .openTrip,
            ]
        case .stationary:
            return [
                .armSignificantChanges,
                .armVisits,
                .armMotion,
                .disarmFullGPS,
                .cancelSleepThresholdTimer,
                .startDeepSleepThresholdTimer,
                .closeTrip,
            ]
        }
    }

    // MARK: - Private

    private static func applyEnvironmentUpdate(
        _ env: TrackerEnvironment,
        _ input: TrackerInput
    ) -> TrackerEnvironment {
        var env = env
        switch input {
        case .userToggled(let on): env.enabled = on
        case .authorizationChanged(let always): env.authorizedAlways = always
        default: break
        }
        return env
    }

    private static func handleInput(state: TrackerState, input: TrackerInput) -> TrackerState {
        switch (state, input) {
        // .deepSleep — tripwires wake us into .waking.
        case (.deepSleep, .significantLocationChange),
             (.deepSleep, .visitDeparted):
            return .waking
        case (.deepSleep, .visitArrived):
            // Already effectively stationary. The runtime still emits a visit
            // event from the delegate; the state machine itself stays put.
            return .deepSleep

        // .waking — motion decides.
        case (.waking, .motionMoving):
            return .tracking
        case (.waking, .motionStationary):
            return .stationary
        case (.waking, .visitArrived):
            return .stationary
        case (.waking, .wakingProbeTimedOut):
            // Probe window elapsed with no movement evidence (motion may be denied).
            // Settle back to .stationary, which disarms probe GPS.
            return .stationary

        // .tracking — the 180s sleep timer (managed by runtime) ultimately fires
        // sleepThresholdReached. Motion events do not change the state; they
        // only affect timer management on the runtime side.
        case (.tracking, .sleepThresholdReached),
             (.tracking, .visitArrived):
            return .stationary

        // .stationary — motion or tripwires resume tracking; deep-sleep timer
        // moves us all the way down.
        case (.stationary, .motionMoving):
            return .tracking
        case (.stationary, .visitDeparted),
             (.stationary, .significantLocationChange):
            return .waking
        case (.stationary, .deepSleepThresholdReached):
            return .deepSleep

        // Anything else — no state change.
        default:
            return state
        }
    }
}
