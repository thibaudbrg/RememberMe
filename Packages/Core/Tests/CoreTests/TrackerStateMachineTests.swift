import XCTest
@testable import Core

/// Pure state-machine tests. No iOS framework, no async — just feed inputs and
/// assert state + actions. The runtime adapter (Phase 5) wraps `CLLocationManager`
/// and `CMMotionActivityManager` callbacks into `TrackerInput` values and applies
/// the returned `TrackerAction` list to the hardware.
final class TrackerStateMachineTests: XCTestCase {
    // MARK: - Off

    func testOffStaysOffWhenDisabled() {
        let env = TrackerEnvironment(enabled: false, authorizedAlways: true)
        let result = TrackerStateMachine.next(from: .off, environment: env, input: .significantLocationChange)
        XCTAssertEqual(result.newState, .off)
        XCTAssertTrue(result.actions.isEmpty) // already off, no actions
    }

    func testOffStaysOffWhenUnauthorized() {
        let env = TrackerEnvironment(enabled: true, authorizedAlways: false)
        let result = TrackerStateMachine.next(from: .off, environment: env, input: .significantLocationChange)
        XCTAssertEqual(result.newState, .off)
    }

    func testOffMovesToDeepSleepOnceEnabledAndAuthorized() {
        let env = TrackerEnvironment(enabled: false, authorizedAlways: false)
        // First enable, still unauthorized → off
        let step1 = TrackerStateMachine.next(from: .off, environment: env, input: .userToggled(true))
        XCTAssertEqual(step1.newState, .off)
        XCTAssertTrue(step1.environment.enabled)
        // Then grant authorization → deepSleep
        let step2 = TrackerStateMachine.next(
            from: step1.newState,
            environment: step1.environment,
            input: .authorizationChanged(authorizedAlways: true)
        )
        XCTAssertEqual(step2.newState, .deepSleep)
        XCTAssertEqual(step2.actions, TrackerStateMachine.entryActions(.deepSleep))
    }

    // MARK: - Disable / revoke from any state collapses to off

    func testDisablingFromTrackingCollapsesToOff() {
        let env = TrackerEnvironment(enabled: true, authorizedAlways: true)
        let result = TrackerStateMachine.next(from: .tracking, environment: env, input: .userToggled(false))
        XCTAssertEqual(result.newState, .off)
        XCTAssertEqual(result.actions, TrackerStateMachine.entryActions(.off))
        XCTAssertFalse(result.environment.enabled)
    }

    func testRevokingAuthFromTrackingCollapsesToOff() {
        let env = TrackerEnvironment(enabled: true, authorizedAlways: true)
        let result = TrackerStateMachine.next(
            from: .tracking,
            environment: env,
            input: .authorizationChanged(authorizedAlways: false)
        )
        XCTAssertEqual(result.newState, .off)
        XCTAssertFalse(result.environment.authorizedAlways)
    }

    func testRevokingAuthFromDeepSleepCollapsesToOff() {
        let env = TrackerEnvironment(enabled: true, authorizedAlways: true)
        let result = TrackerStateMachine.next(
            from: .deepSleep,
            environment: env,
            input: .authorizationChanged(authorizedAlways: false)
        )
        XCTAssertEqual(result.newState, .off)
    }

    // MARK: - DeepSleep

    func testDeepSleepWakesOnSignificantLocationChange() {
        let env = TrackerEnvironment(enabled: true, authorizedAlways: true)
        let result = TrackerStateMachine.next(from: .deepSleep, environment: env, input: .significantLocationChange)
        XCTAssertEqual(result.newState, .waking)
        XCTAssertEqual(result.actions, TrackerStateMachine.entryActions(.waking))
    }

    func testDeepSleepWakesOnVisitDeparted() {
        let env = TrackerEnvironment(enabled: true, authorizedAlways: true)
        let result = TrackerStateMachine.next(from: .deepSleep, environment: env, input: .visitDeparted)
        XCTAssertEqual(result.newState, .waking)
    }

    func testDeepSleepIgnoresVisitArrived() {
        let env = TrackerEnvironment(enabled: true, authorizedAlways: true)
        let result = TrackerStateMachine.next(from: .deepSleep, environment: env, input: .visitArrived)
        XCTAssertEqual(result.newState, .deepSleep)
        XCTAssertTrue(result.actions.isEmpty)
    }

    func testDeepSleepIgnoresMotionUpdates() {
        // Motion isn't armed in deepSleep, but if something stale fires anyway,
        // we ignore it rather than spuriously waking.
        let env = TrackerEnvironment(enabled: true, authorizedAlways: true)
        let result = TrackerStateMachine.next(from: .deepSleep, environment: env, input: .motionMoving)
        XCTAssertEqual(result.newState, .deepSleep)
    }

    // MARK: - Waking

    func testWakingCommitsToTrackingOnMotionMoving() {
        let env = TrackerEnvironment(enabled: true, authorizedAlways: true)
        let result = TrackerStateMachine.next(from: .waking, environment: env, input: .motionMoving)
        XCTAssertEqual(result.newState, .tracking)
        XCTAssertEqual(result.actions, TrackerStateMachine.entryActions(.tracking))
    }

    func testWakingFallsToStationaryOnMotionStationary() {
        let env = TrackerEnvironment(enabled: true, authorizedAlways: true)
        let result = TrackerStateMachine.next(from: .waking, environment: env, input: .motionStationary)
        XCTAssertEqual(result.newState, .stationary)
    }

    func testWakingCollapsesToStationaryOnVisitArrived() {
        let env = TrackerEnvironment(enabled: true, authorizedAlways: true)
        let result = TrackerStateMachine.next(from: .waking, environment: env, input: .visitArrived)
        XCTAssertEqual(result.newState, .stationary)
    }

    func testWakingFallsToStationaryOnProbeTimeout() {
        // The probe window can elapse with no movement evidence (e.g. Motion &
        // Fitness denied). The timeout falls back to .stationary, which disarms
        // probe GPS — never leaving the tracker stuck in .waking.
        let env = TrackerEnvironment(enabled: true, authorizedAlways: true)
        let result = TrackerStateMachine.next(from: .waking, environment: env, input: .wakingProbeTimedOut)
        XCTAssertEqual(result.newState, .stationary)
        XCTAssertEqual(result.actions, TrackerStateMachine.entryActions(.stationary))
    }

    func testWakingProbeTimeoutIgnoredOutsideWaking() {
        // The timeout only matters in .waking. In any other state it's stale.
        let env = TrackerEnvironment(enabled: true, authorizedAlways: true)
        for state in [TrackerState.deepSleep, .tracking, .stationary] {
            let result = TrackerStateMachine.next(from: state, environment: env, input: .wakingProbeTimedOut)
            XCTAssertEqual(result.newState, state)
            XCTAssertTrue(result.actions.isEmpty)
        }
    }

    // MARK: - Tracking

    func testTrackingStaysOnMotionEvents() {
        let env = TrackerEnvironment(enabled: true, authorizedAlways: true)
        let moving = TrackerStateMachine.next(from: .tracking, environment: env, input: .motionMoving)
        XCTAssertEqual(moving.newState, .tracking)
        XCTAssertTrue(moving.actions.isEmpty)

        let stationary = TrackerStateMachine.next(from: .tracking, environment: env, input: .motionStationary)
        XCTAssertEqual(stationary.newState, .tracking)
        XCTAssertTrue(stationary.actions.isEmpty)
    }

    func testTrackingMovesToStationaryOnSleepThresholdReached() {
        let env = TrackerEnvironment(enabled: true, authorizedAlways: true)
        let result = TrackerStateMachine.next(from: .tracking, environment: env, input: .sleepThresholdReached)
        XCTAssertEqual(result.newState, .stationary)
        XCTAssertEqual(result.actions, TrackerStateMachine.entryActions(.stationary))
    }

    func testTrackingMovesToStationaryOnVisitArrived() {
        let env = TrackerEnvironment(enabled: true, authorizedAlways: true)
        let result = TrackerStateMachine.next(from: .tracking, environment: env, input: .visitArrived)
        XCTAssertEqual(result.newState, .stationary)
    }

    // MARK: - Stationary

    func testStationaryResumesTrackingOnMotionMoving() {
        let env = TrackerEnvironment(enabled: true, authorizedAlways: true)
        let result = TrackerStateMachine.next(from: .stationary, environment: env, input: .motionMoving)
        XCTAssertEqual(result.newState, .tracking)
    }

    func testStationaryWakesOnVisitDeparted() {
        let env = TrackerEnvironment(enabled: true, authorizedAlways: true)
        let result = TrackerStateMachine.next(from: .stationary, environment: env, input: .visitDeparted)
        XCTAssertEqual(result.newState, .waking)
    }

    func testStationaryWakesOnSignificantLocationChange() {
        let env = TrackerEnvironment(enabled: true, authorizedAlways: true)
        let result = TrackerStateMachine.next(from: .stationary, environment: env, input: .significantLocationChange)
        XCTAssertEqual(result.newState, .waking)
    }

    func testStationaryFallsToDeepSleepOnTimeout() {
        let env = TrackerEnvironment(enabled: true, authorizedAlways: true)
        let result = TrackerStateMachine.next(
            from: .stationary,
            environment: env,
            input: .deepSleepThresholdReached
        )
        XCTAssertEqual(result.newState, .deepSleep)
        XCTAssertEqual(result.actions, TrackerStateMachine.entryActions(.deepSleep))
    }

    // MARK: - Entry-action invariants

    func testOffEntryActionsTearDownEverything() {
        let actions = TrackerStateMachine.entryActions(.off)
        XCTAssertTrue(actions.contains(.disarmSignificantChanges))
        XCTAssertTrue(actions.contains(.disarmVisits))
        XCTAssertTrue(actions.contains(.disarmMotion))
        XCTAssertTrue(actions.contains(.disarmFullGPS))
        XCTAssertTrue(actions.contains(.closeTrip))
    }

    func testDeepSleepEntryActionsKeepOnlyTripwires() {
        let actions = TrackerStateMachine.entryActions(.deepSleep)
        XCTAssertTrue(actions.contains(.armSignificantChanges))
        XCTAssertTrue(actions.contains(.armVisits))
        XCTAssertTrue(actions.contains(.disarmFullGPS))
        XCTAssertTrue(actions.contains(.disarmMotion))
    }

    func testTrackingEntryRequestsBestAccuracyGPSAndOpensTrip() {
        let actions = TrackerStateMachine.entryActions(.tracking)
        XCTAssertTrue(actions.contains(.armFullGPS(.best)))
        XCTAssertTrue(actions.contains(.armMotion))
        XCTAssertTrue(actions.contains(.openTrip))
    }

    func testStationaryEntryDisarmsGPSAndStartsDeepSleepTimer() {
        let actions = TrackerStateMachine.entryActions(.stationary)
        XCTAssertTrue(actions.contains(.disarmFullGPS))
        XCTAssertTrue(actions.contains(.armMotion))
        XCTAssertTrue(actions.contains(.startDeepSleepThresholdTimer))
        XCTAssertTrue(actions.contains(.closeTrip))
    }

    func testWakingEntryArmsProbeAccuracyGPS() {
        let actions = TrackerStateMachine.entryActions(.waking)
        XCTAssertTrue(actions.contains(.armFullGPS(.probe)))
        XCTAssertTrue(actions.contains(.armMotion))
    }

    // MARK: - Full happy-path scenario

    func testFullDriveScenario() {
        // Cold start, user enables, grants Always, drives somewhere, arrives, sits.
        var env = TrackerEnvironment.initial
        var state: TrackerState = .off

        // 1. Enable
        var step = TrackerStateMachine.next(from: state, environment: env, input: .userToggled(true))
        env = step.environment; state = step.newState
        XCTAssertEqual(state, .off) // still off — not authorized yet

        // 2. Grant Always
        step = TrackerStateMachine.next(from: state, environment: env, input: .authorizationChanged(authorizedAlways: true))
        env = step.environment; state = step.newState
        XCTAssertEqual(state, .deepSleep)

        // 3. SLC fires (user starts driving)
        step = TrackerStateMachine.next(from: state, environment: env, input: .significantLocationChange)
        env = step.environment; state = step.newState
        XCTAssertEqual(state, .waking)

        // 4. Motion confirms moving
        step = TrackerStateMachine.next(from: state, environment: env, input: .motionMoving)
        env = step.environment; state = step.newState
        XCTAssertEqual(state, .tracking)

        // 5. Drive continues — motion fluctuates but tracking sticks
        step = TrackerStateMachine.next(from: state, environment: env, input: .motionStationary)
        env = step.environment; state = step.newState
        XCTAssertEqual(state, .tracking) // brief stop, not enough to flip
        step = TrackerStateMachine.next(from: state, environment: env, input: .motionMoving)
        env = step.environment; state = step.newState
        XCTAssertEqual(state, .tracking)

        // 6. Eventually arrive — sleep threshold fires
        step = TrackerStateMachine.next(from: state, environment: env, input: .sleepThresholdReached)
        env = step.environment; state = step.newState
        XCTAssertEqual(state, .stationary)

        // 7. Sit there long enough — deep sleep
        step = TrackerStateMachine.next(from: state, environment: env, input: .deepSleepThresholdReached)
        env = step.environment; state = step.newState
        XCTAssertEqual(state, .deepSleep)

        // 8. Tear down on user-disable
        step = TrackerStateMachine.next(from: state, environment: env, input: .userToggled(false))
        env = step.environment; state = step.newState
        XCTAssertEqual(state, .off)
    }
}
