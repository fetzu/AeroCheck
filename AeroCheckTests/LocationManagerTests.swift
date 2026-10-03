import XCTest
import CoreLocation
@testable import AeroCheck

/// Tests for LocationManager's GPS signal-status policy — the logic behind the cockpit GPS
/// indicator. Pins the 10 / 20 / 45 s boundaries so the constants can't drift from intent (PR-35).
final class LocationManagerTests: XCTestCase {

    private func status(_ t: TimeInterval, accuracy: CLLocationAccuracy,
                        current: GPSSignalStatus = .good) -> GPSSignalStatus {
        LocationManager.signalStatus(timeSinceLastUpdate: t, lastKnownAccuracy: accuracy, current: current)
    }

    func testFreshGoodFixStaysGood() {
        XCTAssertEqual(status(2, accuracy: 10), .good)
        XCTAssertEqual(status(19, accuracy: 10), .good) // <20 s with a good last fix
    }

    func testGoodSignalDegradesAtTwentySeconds() {
        XCTAssertEqual(status(20, accuracy: 10, current: .good), .degraded)
        XCTAssertEqual(status(30, accuracy: 10, current: .good), .degraded)
    }

    func testTrulyLostAtFortyFiveSeconds() {
        XCTAssertEqual(status(45, accuracy: 10), .lost)  // a good last accuracy doesn't save it
        XCTAssertEqual(status(60, accuracy: -1), .lost)
    }

    func testPoorAccuracyDegradesAtTenSeconds() {
        XCTAssertEqual(status(5, accuracy: 200, current: .good), .good)     // <10 s: unchanged
        XCTAssertEqual(status(10, accuracy: 200, current: .good), .degraded)
        XCTAssertEqual(status(12, accuracy: -1, current: .good), .degraded) // negative accuracy = unknown/poor
    }

    // MARK: Parked: every fix counts for the status, the pipeline takes them 5 m apart (6.1.0)

    /// A fix of a parked aircraft: from the satellites (with a speed accuracy) unless `satellite` is false,
    /// a Wi-Fi or cell position (none).
    private func groundFix(north metres: Double, accuracy: CLLocationAccuracy = 8, satellite: Bool = true,
                           at time: Date = Date()) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: 47 + metres / 111_195, longitude: 8),
                   altitude: 430, horizontalAccuracy: accuracy, verticalAccuracy: 10,
                   course: -1, courseAccuracy: -1, speed: satellite ? 0 : -1, speedAccuracy: satellite ? 0.4 : -1,
                   timestamp: time)
    }

    @MainActor
    func testTheHardwareDeliversEveryFixOnTheGround() {
        // As CoreLocation's distance filter, the 5 m held back every fix of a parked aircraft: the
        // status could only count the seconds, and good GPS went amber at 20 s and red at 45 s.
        let lm = LocationManager()
        XCTAssertEqual(lm.hardwareDistanceFilter, kCLDistanceFilterNone)
        lm.setGroundMode(false)
        XCTAssertEqual(lm.hardwareDistanceFilter, 50, "in flight, the battery filter stays")
        lm.setGroundMode(true)
        XCTAssertEqual(lm.hardwareDistanceFilter, kCLDistanceFilterNone)
    }

    func testTheGroundFilterPassesFixesFiveMetresApart() {
        let first = groundFix(north: 0)
        XCTAssertTrue(LocationManager.passesGroundFilter(first, lastPassed: nil, groundMode: true, filter: 5),
                      "the first fix always goes on")
        XCTAssertFalse(LocationManager.passesGroundFilter(groundFix(north: 3), lastPassed: first,
                                                          groundMode: true, filter: 5))
        XCTAssertTrue(LocationManager.passesGroundFilter(groundFix(north: 6), lastPassed: first,
                                                         groundMode: true, filter: 5))
        XCTAssertTrue(LocationManager.passesGroundFilter(groundFix(north: 1), lastPassed: first,
                                                         groundMode: false, filter: 5),
                      "in flight the hardware filters, every fix it delivers goes on")
    }

    @MainActor
    func testAParkedAircraftsFixesKeepTheStatusWhileThePipelineHoldsItsPosition() {
        let lm = LocationManager()
        lm.receiveDeviceFix(groundFix(north: 0, accuracy: 200))
        XCTAssertEqual(lm.gpsSignalStatus, .degraded, "a poor fix degrades")
        let pipeline = lm.currentLocation

        let held = groundFix(north: 1, accuracy: 8)
        lm.receiveDeviceFix(held)
        XCTAssertEqual(lm.gpsSignalStatus, .good, "the receiver's accuracy decides, not the distance moved")
        XCTAssertTrue(lm.ownFixIsLive)
        XCTAssertTrue(lm.latestFix === held, "the GPS sheet shows the newest fix")
        XCTAssertTrue(lm.currentLocation === pipeline, "the pipeline sees what the 5 m filter gave it before")

        let moved = groundFix(north: 7)
        lm.receiveDeviceFix(moved)
        XCTAssertTrue(lm.currentLocation === moved)
    }

    // MARK: A fix counts from when it was determined (6.1.0)

    @MainActor
    func testALateFixDoesNotMakeTheSignalGood() {
        // Core Location "sometimes returns cached events": a fix determined a minute ago, delivered now,
        // is not a fresh one. It used to set the status good and restart the seconds.
        let lm = LocationManager()
        lm.receiveDeviceFix(groundFix(north: 0, accuracy: 200))
        XCTAssertEqual(lm.gpsSignalStatus, .degraded)
        let late = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 47, longitude: 8), altitude: 430,
                              horizontalAccuracy: 8, verticalAccuracy: 10, course: -1, speed: 0,
                              timestamp: Date(timeIntervalSinceNow: -60))
        lm.receiveDeviceFix(late)
        XCTAssertEqual(lm.gpsSignalStatus, .degraded, "a minute-old fix doesn't turn it green")
        let fresh = groundFix(north: 0, accuracy: 8)
        lm.receiveDeviceFix(fresh)
        XCTAssertEqual(lm.gpsSignalStatus, .good)
        XCTAssertEqual(lm.lastLocationUpdateTime?.timeIntervalSince(fresh.timestamp) ?? 99, 0, accuracy: 0.001,
                       "the seconds count from when the fix was determined")
    }

    func testTheLogLineSaysWhatTheFixesCarried() {
        var digest = GPSFixDigest()
        let now = Date()
        func fix(_ north: Double, accuracy: Double, speedAccuracy: Double, age: TimeInterval = 0) -> CLLocation {
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: 47 + north / 111_195, longitude: 8), altitude: 430,
                       horizontalAccuracy: accuracy, verticalAccuracy: 10, course: -1, courseAccuracy: -1,
                       speed: 0, speedAccuracy: speedAccuracy, timestamp: now.addingTimeInterval(-age))
        }
        digest.add(fix(0, accuracy: 9, speedAccuracy: 0.5), borrowed: false, now: now)
        digest.add(fix(0, accuracy: 9, speedAccuracy: 0.5), borrowed: false, now: now)
        digest.add(fix(2, accuracy: 7, speedAccuracy: -1, age: 3), borrowed: false, now: now)
        digest.noteDiagnostics(unavailable: true, stationary: false)
        let line = digest.line(seconds: 10, status: .good)
        XCTAssertEqual(line, "GPS 10 s: 3 fixes, ± 7–9 m, satellite 2, course on 0, same as previous 1, "
                       + "moved 2.0 m, oldest 3 s, unavailable 1, stationary 0; status good")
        XCTAssertFalse(line.contains("47"), "never a position")
        digest.startNextStretch()
        digest.add(fix(2, accuracy: 7, speedAccuracy: -1), borrowed: false, now: now)
        XCTAssertEqual(digest.sameAsPrevious, 1, "the next stretch still compares with the last fix")
        XCTAssertEqual(digest.fixes, 1)
    }

    // MARK: Green needs the satellites (6.1.0)

    func testAFixWithoutASpeedAccuracyIsNotFromTheSatellites() {
        XCTAssertTrue(LocationManager.isSatelliteFix(groundFix(north: 0)))
        XCTAssertFalse(LocationManager.isSatelliteFix(groundFix(north: 0, satellite: false)),
                       "a Wi-Fi or cell position carries no speed accuracy")
    }

    func testPositionsWithoutASatelliteFixDegradeAfterTwentySeconds() {
        func status(sat: TimeInterval?, current: GPSSignalStatus = .good) -> GPSSignalStatus {
            LocationManager.signalStatus(timeSinceLastUpdate: 2, lastKnownAccuracy: 9, current: current,
                                         timeSinceSatelliteFix: sat)
        }
        XCTAssertEqual(status(sat: 5), .good)
        XCTAssertEqual(status(sat: 19.9), .good)
        XCTAssertEqual(status(sat: 20), .degraded, "Wi-Fi at ± 9 m every 2 s, no satellites for 20 s")
        XCTAssertEqual(status(sat: 200, current: .lost), .degraded, "positions are back, not from the satellites")
        XCTAssertEqual(LocationManager.signalStatus(timeSinceLastUpdate: 50, lastKnownAccuracy: 9, current: .good,
                                                    timeSinceSatelliteFix: 50), .lost, "nothing at all for 45 s")
    }

    @MainActor
    func testWiFiPositionsAloneTurnTheIndicatorAmber() {
        // The basement of 3 Oct 2026: the receiver on, no fix; Core Location sends Wi-Fi positions at ± 14–78 m.
        let lm = LocationManager()
        let start = Date()
        lm.receiveDeviceFix(groundFix(north: 0, at: start), now: start)
        XCTAssertEqual(lm.gpsSignalStatus, .good)
        lm.receiveDeviceFix(groundFix(north: 1, accuracy: 14, satellite: false, at: start + 10), now: start + 10)
        XCTAssertEqual(lm.gpsSignalStatus, .good, "10 s without the satellites: not yet")
        lm.receiveDeviceFix(groundFix(north: 2, accuracy: 14, satellite: false, at: start + 21), now: start + 21)
        XCTAssertEqual(lm.gpsSignalStatus, .degraded, "21 s of Wi-Fi alone")
        lm.receiveDeviceFix(groundFix(north: 2, at: start + 30), now: start + 30)
        XCTAssertEqual(lm.gpsSignalStatus, .good, "a satellite fix again")
        XCTAssertEqual(lm.lastSatelliteFixTime, start + 30)
    }

    func testEscalationsOnlyFireFromGood() {
        // A non-good status is preserved (not re-escalated) in the 10–45 s band.
        XCTAssertEqual(status(25, accuracy: 10, current: .degraded), .degraded)
        XCTAssertEqual(status(25, accuracy: 10, current: .lost), .lost)
    }

    func testThresholdBoundaries() {
        XCTAssertEqual(status(19.99, accuracy: 10, current: .good), .good)
        XCTAssertEqual(status(20.0, accuracy: 10, current: .good), .degraded)
        XCTAssertEqual(status(44.99, accuracy: 10, current: .good), .degraded)
        XCTAssertEqual(status(45.0, accuracy: 10, current: .good), .lost)
    }

    // MARK: - Companion shared GPS: borrowed-fix injection (v4.1)

    private func fix(lat: Double = 47, lon: Double = 8, accuracy: CLLocationAccuracy = 10,
                     ageSeconds: TimeInterval = 0) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                   altitude: 500, horizontalAccuracy: accuracy, verticalAccuracy: 10,
                   course: 90, speed: 30, timestamp: Date(timeIntervalSinceNow: -ageSeconds))
    }

    @MainActor
    func testBorrowedFixIsAdoptedWhenNoOwnFix() {
        let lm = LocationManager()
        XCTAssertFalse(lm.ownFixIsLive, "no own fix yet")
        lm.injectCompanionLocation(fix(lat: 46.5, lon: 6.6))
        XCTAssertEqual(lm.currentLocation?.coordinate.latitude ?? 0, 46.5, accuracy: 1e-6,
                       "a borrowed peer fix becomes the current location when the device has no own GPS")
    }

    @MainActor
    func testOwnFixWinsOverBorrowedFix() {
        let lm = LocationManager()
        lm.processLocation(fix(lat: 47.0, lon: 8.0), isOwnFix: true)
        XCTAssertTrue(lm.ownFixIsLive, "a real device fix marks own GPS live")
        lm.injectCompanionLocation(fix(lat: 46.5, lon: 6.6))
        XCTAssertEqual(lm.currentLocation?.coordinate.latitude ?? 0, 47.0, accuracy: 1e-6,
                       "a live own fix is preserved; the borrowed fix is ignored")
    }

    @MainActor
    func testBorrowingNeverMarksOwnGPSLive() {
        let lm = LocationManager()
        lm.injectCompanionLocation(fix())
        XCTAssertFalse(lm.ownFixIsLive,
                       "borrowing must not report own GPS as live — that would flap the master/viewer feed")
    }

    @MainActor
    func testCompanionInjectionIsInertDuringMarketingMode() {
        let lm = LocationManager()
        lm.overrideGPSStatus(.good)   // activates marketing mode
        lm.injectCompanionLocation(fix(lat: 45.0, lon: 7.0))
        XCTAssertNil(lm.currentLocation, "marketing mode is authoritative — companion injection is ignored")
    }

    // MARK: - Simulated position (developer option, S9-25)

    /// The option held the GPS status at GREEN while every real fix was dropped: a flight started
    /// later in the run flew a static position at Samedan under a healthy indicator.
    @MainActor
    func testASimulatedPositionIsNeverShownAsAHealthyGPS() {
        let lm = LocationManager()
        lm.startSimulatingPosition(at: fix(lat: 46.53, lon: 9.88))

        XCTAssertTrue(lm.isSimulatingPosition)
        XCTAssertEqual(lm.gpsSignalStatus, .degraded, "orange, with the instruments' failure flags up")
        XCTAssertEqual(lm.currentLocation?.coordinate.latitude, 46.53)
    }

    @MainActor
    func testTurningItOffLeavesNothingOfTheHeldFix() {
        let lm = LocationManager()
        lm.startSimulatingPosition(at: fix(lat: 46.53, lon: 9.88))

        lm.stopSimulatingPosition()

        XCTAssertFalse(lm.isSimulatingPosition)
        XCTAssertFalse(lm.isTracking, "no flight is running, so nothing records")
        XCTAssertNil(lm.currentLocation, "a flight started now must not begin at Samedan")
        XCTAssertFalse(lm.hasRecentUsableFix)
        XCTAssertEqual(lm.gpsSignalStatus, .good)
    }

    @MainActor
    func testEndingAFlightEndsTheSimulation() {
        let lm = LocationManager()
        lm.startSimulatingPosition(at: fix())

        lm.stopTracking()

        XCTAssertFalse(lm.isSimulatingPosition, "one test flight, never the next one")
    }

    /// The marketing scenes use the same injector with an override of their own, which turning
    /// the developer option off must not touch.
    @MainActor
    func testStoppingWithNoSimulationLeavesTheMarketingOverrideAlone() {
        let lm = LocationManager()
        lm.injectMarketingStaticFix(fix())

        lm.stopSimulatingPosition()

        XCTAssertTrue(lm.isTracking)
        XCTAssertNotNil(lm.currentLocation)
        lm.injectCompanionLocation(fix(lat: 45.0, lon: 7.0))
        XCTAssertEqual(lm.currentLocation?.coordinate.latitude, 47, "still ignoring every other fix")
    }

    // MARK: - Companion GPS provider (viewer background sourcing, v4.1)

    @MainActor
    func testSharedGPSProviderActivatesAndDeactivates() {
        let lm = LocationManager()
        lm.authorizationStatus = .authorizedAlways   // bypass the deferral path
        lm.startSharedGPSProvider()
        XCTAssertTrue(lm.isSharedGPSProviderActive, "provider should be active once permitted")
        lm.stopSharedGPSProvider()
        XCTAssertFalse(lm.isSharedGPSProviderActive, "provider should release on stop")
    }

    @MainActor
    func testSharedGPSProviderDefersWithoutAuthorization() {
        let lm = LocationManager()
        lm.authorizationStatus = .notDetermined
        lm.startSharedGPSProvider()
        XCTAssertFalse(lm.isSharedGPSProviderActive,
                       "without permission the provider stays inactive until authorization is granted")
    }

    @MainActor
    func testClosingNavMapKeepsProviderAlive() {
        let lm = LocationManager()
        lm.authorizationStatus = .authorizedAlways
        lm.startSharedGPSProvider()
        lm.stopLocationUpdates()   // simulate the nav map closing
        XCTAssertTrue(lm.isSharedGPSProviderActive,
                      "closing the nav-map session must not tear down the companion GPS provider")
    }

    // MARK: - Flight-start fix check (v4.1 — stationary-start regression fix)

    @MainActor
    func testHasRecentUsableFixNeedsActiveGPSAndValidFix() {
        let lm = LocationManager()
        XCTAssertFalse(lm.hasRecentUsableFix, "no GPS running, no fix")
        lm.authorizationStatus = .authorizedAlways
        lm.startSharedGPSProvider()   // GPS now active
        XCTAssertFalse(lm.hasRecentUsableFix, "GPS active but no fix yet")
        lm.processLocation(fix(), isOwnFix: true)
        XCTAssertTrue(lm.hasRecentUsableFix, "active GPS + valid fix is startable")
    }

    @MainActor
    func testHasRecentUsableFixIgnoresFixAge() {
        // The whole point: a stationary aircraft stops producing fresh fixes, but its last position is
        // still valid to start from — hasRecentUsableFix doesn't reject on the fix's timestamp age.
        let lm = LocationManager()
        lm.authorizationStatus = .authorizedAlways
        lm.startSharedGPSProvider()
        lm.processLocation(fix(ageSeconds: 300), isOwnFix: true)
        XCTAssertTrue(lm.hasRecentUsableFix, "an old (stationary) fix is still usable to start")
    }

    @MainActor
    func testHasRecentUsableFixRejectsInvalidAccuracy() {
        let lm = LocationManager()
        lm.authorizationStatus = .authorizedAlways
        lm.startSharedGPSProvider()
        lm.processLocation(fix(accuracy: -1), isOwnFix: true)   // invalid fix
        XCTAssertFalse(lm.hasRecentUsableFix, "a negative-accuracy fix is not a usable position")
    }
}

/// The revoked-mid-flight recovery decision, extracted so it can be tested at all. (CQ-05)
///
/// The surrounding `locationManagerDidChangeAuthorization` needs a live `CLLocationManager`, so this
/// path — recording silently stopping when a pilot revokes permission, and whether it comes back on
/// re-authorization — previously had no test seam and was only ever exercised by hand.
final class LocationRevocationTransitionTests: XCTestCase {

    private func transition(
        authorized: Bool, active: Bool, wasRevoked: Bool
    ) -> LocationManager.RevocationTransition {
        LocationManager.revocationTransition(
            isAuthorized: authorized, hasActiveSession: active, wasStoppedByRevocation: wasRevoked)
    }

    func testRevocationDuringAnActiveSessionStopsAndRemembers() {
        XCTAssertEqual(transition(authorized: false, active: true, wasRevoked: false), .stopAndRemember)
    }

    /// The recovery half (PR-39): without it the session stayed dead with `isTracking` still true —
    /// the app looked like it was recording when it was not.
    func testReauthorizationAfterRevocationResumes() {
        XCTAssertEqual(transition(authorized: true, active: true, wasRevoked: true), .resume)
    }

    /// Granting permission normally must NOT restart anything — only a session we ourselves stopped
    /// is resumed, otherwise an unrelated authorization callback could start GPS behind the pilot.
    func testAuthorizationWithoutAPriorRevocationDoesNothing() {
        XCTAssertEqual(transition(authorized: true, active: true, wasRevoked: false), .none)
    }

    /// With no session running there is nothing to stop or resume, whatever the flags say.
    func testNoActiveSessionIsAlwaysANoOp() {
        XCTAssertEqual(transition(authorized: false, active: false, wasRevoked: false), .none)
        XCTAssertEqual(transition(authorized: false, active: false, wasRevoked: true), .none)
        XCTAssertEqual(transition(authorized: true, active: false, wasRevoked: true), .none,
                       "a stale revocation flag must not start GPS when nothing is running")
    }

    /// Revoke → re-authorize → revoke again must return to stopAndRemember, not latch.
    func testRevocationIsRepeatable() {
        XCTAssertEqual(transition(authorized: false, active: true, wasRevoked: true), .stopAndRemember)
    }
}
