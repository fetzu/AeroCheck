import Foundation
import CoreLocation
import Combine

/// GPS signal quality status
enum GPSSignalStatus {
    case good       // Green: GPS functioning, accurate position available
    case degraded   // Orange: GPS working but accuracy poor or updates infrequent
    case lost       // Red: GPS truly lost — no position data available
}

/// What the GPS delivered over a stretch, for the device's log (`LocationManager.logFixDigest`): counts
/// and ranges only, never a position. Pure, so it is tested without Core Location. (6.1.0)
struct GPSFixDigest {
    private(set) var fixes = 0
    private(set) var borrowed = 0
    private(set) var minAccuracy: Double?
    private(set) var maxAccuracy: Double?
    /// Fixes from the satellites (`LocationManager.isSatelliteFix`), an external receiver's included.
    private(set) var withSpeedAccuracy = 0
    /// Of those, fixes an external receiver produced (`CLLocationSourceInformation`). (6.1.1)
    private(set) var fromAccessory = 0
    /// Fixes with a course.
    private(set) var withCourse = 0
    /// Fixes identical to the one before (position, altitude, accuracy): the same estimate again.
    private(set) var sameAsPrevious = 0
    private(set) var movedMetres = 0.0
    /// The oldest fix on arrival, in seconds after it was determined.
    private(set) var oldestAge: TimeInterval = 0
    /// Core Location's diagnostics (iOS 18+): updates saying the location is unavailable, or stationary.
    private(set) var unavailable = 0
    private(set) var stationary = 0
    private var previous: CLLocation?

    mutating func add(_ fix: CLLocation, borrowed isBorrowed: Bool, now: Date) {
        fixes += 1
        if isBorrowed { borrowed += 1 }
        let accuracy = fix.horizontalAccuracy
        if accuracy >= 0 {
            minAccuracy = min(minAccuracy ?? accuracy, accuracy)
            maxAccuracy = max(maxAccuracy ?? accuracy, accuracy)
        }
        if LocationManager.isSatelliteFix(fix) { withSpeedAccuracy += 1 }
        if fix.sourceInformation?.isProducedByAccessory == true { fromAccessory += 1 }
        if fix.course >= 0 { withCourse += 1 }
        if !isBorrowed { oldestAge = max(oldestAge, now.timeIntervalSince(fix.timestamp)) }
        if let previous {
            if previous.coordinate.latitude == fix.coordinate.latitude,
               previous.coordinate.longitude == fix.coordinate.longitude,
               previous.altitude == fix.altitude, previous.horizontalAccuracy == accuracy {
                sameAsPrevious += 1
            }
            movedMetres += fix.distance(from: previous)
        }
        previous = fix
    }

    mutating func noteDiagnostics(unavailable isUnavailable: Bool, stationary isStationary: Bool) {
        if isUnavailable { unavailable += 1 }
        if isStationary { stationary += 1 }
    }

    /// The next stretch counts from nothing, but still compares its first fix with the last one.
    mutating func startNextStretch() {
        let last = previous
        self = GPSFixDigest()
        previous = last
    }

    /// One line: "GPS 10 s: 10 fixes, ± 7–9 m, satellite 10, course on 0, same as previous 0,
    /// moved 1.2 m, oldest 1 s, unavailable 0, stationary 0; status good".
    func line(seconds: Int, status: GPSSignalStatus) -> String {
        let range: String
        if let minAccuracy, let maxAccuracy {
            range = "± \(Int(minAccuracy.rounded()))–\(Int(maxAccuracy.rounded())) m"
        } else {
            range = "no accuracy"
        }
        return "GPS \(seconds) s: \(fixes) fixes" + (borrowed > 0 ? " (\(borrowed) from the companion)" : "")
            + ", \(range), satellite \(withSpeedAccuracy)"
            + (fromAccessory > 0 ? " (\(fromAccessory) from an accessory)" : "") + ", course on \(withCourse)"
            + ", same as previous \(sameAsPrevious), moved \(String(format: "%.1f", movedMetres)) m"
            + ", oldest \(Int(oldestAge.rounded())) s, unavailable \(unavailable), stationary \(stationary)"
            + "; status \(status.description)"
    }
}

/// Manages GPS location tracking during flights
@MainActor
class LocationManager: NSObject, ObservableObject {
    // MARK: - Published Properties

    @Published var currentLocation: CLLocation?
    /// Smoothed vertical speed in feet per minute (climb +, descent −), derived from GPS altitude over
    /// a short window. nil until enough samples exist. (v4 UI/UX Revamp — instrument strip VSI)
    @Published private(set) var verticalSpeedFpm: Double?
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    /// Whether the pilot granted full or reduced ("Precise Location" off) accuracy. (RES-09)
    ///
    /// With reduced accuracy CoreLocation delivers deliberately coarsened fixes — hundreds of metres
    /// to kilometres — which permanently fail the 100 m `horizontalAccuracyThreshold`. The app then
    /// shows a perpetually degraded/lost signal that looks exactly like bad reception, with nothing
    /// pointing at the actual cause or its one-tap fix in Settings.
    @Published private(set) var accuracyAuthorization: CLAccuracyAuthorization = .fullAccuracy
    @Published var isTracking: Bool = false
    @Published var isLocationUpdatesActive: Bool = false // True when GPS is active (even without flight tracking)
    @Published var locationError: String?
    @Published var gpsSignalStatus: GPSSignalStatus = .good {
        didSet {
            // Kept in the device's log, for a field report read back with `log collect`. (6.1.0)
            if gpsSignalStatus != oldValue {
                AppLog.location.publicNotice("GPS status: \(oldValue.description) → \(gpsSignalStatus.description)")
            }
        }
    }
    /// True when GPS is active but only WhenInUse authorization is granted, so the track may
    /// stop if the app is backgrounded. Drives an in-flight warning banner. (PERF-04)
    @Published var backgroundTrackingLimited: Bool = false
    /// Where the "Simulate position" developer option holds the aircraft, while it is on. Kept here
    /// rather than in the Settings page's own state, so the switch still shows it on after the page
    /// is left, and the flight screens can say so. (S9-25)
    @Published private(set) var simulatedPosition: CLLocation?

    // MARK: - Private Properties

    private let locationManager = CLLocationManager()
    private var recordingInterval: TimeInterval = 5.0
    private var lastRecordedTime: Date?

    /// Wall-clock time of the last usable *own* (real device) GPS fix. Companion shared-GPS reads this
    /// to know whether this device still has its own GPS — borrowing a peer fix never updates it, so
    /// the `ownGPSAvailable` flag the master broadcasts can't flap. (shared-GPS, v4.1)
    private var lastOwnFixTime: Date?
    /// A bit over the GPSSourceElection 5 s freshness window, so own-fix liveness keeps a touch of
    /// hysteresis before the master starts borrowing the peer's GPS. (shared-GPS, v4.1)
    private let ownFixStaleAfter: TimeInterval = 6.0
    /// Max horizontal accuracy (m) for an own fix to count as "live" for borrowing — mirrors
    /// GPSSourceElection.maxAccuracy, so a coarse own fix (e.g. 500 m) doesn't masquerade as live and
    /// starve a better borrowed peer fix. (shared-GPS, v4.1)
    private let ownFixMaxAccuracy: Double = 100

    /// Whether an own fix keeps this device's GPS "live" for Companion: within `ownFixMaxAccuracy`, and
    /// from the satellites (`isSatelliteFix`). A Wi-Fi iPad near a hotspot gets Wi-Fi positions at a few
    /// tens of metres; counted as live, they kept the iPhone's GPS out of the flight and told the iPhone
    /// to stop sending it. (6.1.1, Wi-Fi iPads)
    private func countsAsLiveOwnFix(_ location: CLLocation) -> Bool {
        location.horizontalAccuracy >= 0 && location.horizontalAccuracy <= ownFixMaxAccuracy
            && Self.isSatelliteFix(location)
    }

    /// Rolling (time, altitude-ft) samples over the last ~12 s, for the smoothed vertical speed.
    private var altitudeSamples: [(time: Date, altFt: Double)] = []
    private let verticalSpeedWindow: TimeInterval = 12.0

    /// Event detection runs on its OWN cadence, independent of (and never slower than) the GPS
    /// *recording* interval. At a slow recording interval (e.g. 30 s) the detector would otherwise
    /// see one fix per 30 s — far too coarse to resolve a touchdown/go-around — so detection is
    /// capped to at most this many seconds between fixes it processes. (PR-23)
    private static let detectionIntervalCapSeconds: TimeInterval = 5.0
    private var lastDetectionTime: Date?
    /// How often the active plan is caught up with the waypoints passed. A waypoint is passed every
    /// few minutes, and each run replays the whole track so far, so 15 s is plenty. (v6.0.1)
    static let waypointPassageIntervalSeconds: TimeInterval = 15.0
    private var lastWaypointPassageTime: Date?
    private weak var appState: AppState?
    private weak var airportDataService: AirportDataService?
    private weak var flightEventDetector: FlightEventDetector?
    /// The plan whose waypoints the flight marks as it passes them (ATO + next waypoint). Here and
    /// not in a view: the Cockpit shows the checklist for most of a flight, and a pilot may fly with
    /// the app in the background, so a trigger living in the nav map missed most passages. (v6.0.1)
    private weak var flightPlanManager: FlightPlanManager?
    /// Relative barometric altitude, started/stopped with GPS tracking. Recorded on every
    /// GPSPoint and fed to the flight-event detector as its preferred vertical reference.
    /// Inert on devices without a barometer (and on the simulator).
    private let barometer = BarometricAltitudeService()
    /// The resolved checklist for the active flight, used to configure the event detector with
    /// the right aircraft's speeds. Captured at `startTracking` so it never reads global state.
    private var activeChecklist: ActiveChecklist?
    private var hasNotifiedTakeoffTime: Bool = false
    private var hasConfiguredDetector: Bool = false

    // GPS accuracy tracking
    private var lastGoodSignalTime: Date?
    /// When the latest fix that counted for the status was determined: its own time for this device's
    /// fixes, the receiving time for a companion's. (`updateSignalQuality`)
    private(set) var lastLocationUpdateTime: Date?
    /// When the latest fix from the satellites, within 100 m, was determined (`isSatelliteFix`). Green
    /// needs one in the last 20 s: a Wi-Fi or cell position alone is no GPS. (6.1.0)
    private(set) var lastSatelliteFixTime: Date?
    private var lastKnownAccuracy: CLLocationAccuracy = -1  // Last received horizontal accuracy (-1 = unknown)
    private let signalDegradedThreshold: TimeInterval = 10.0  // 10 seconds without update = degraded
    private let signalLostThreshold: TimeInterval = 20.0  // 20 seconds without update = long-degraded
    private let signalTrulyLostThreshold: TimeInterval = 45.0  // 45 seconds = truly lost (red)
    private let horizontalAccuracyThreshold: CLLocationAccuracy = 100.0  // 100 meters
    private var signalCheckTimer: Timer?
    /// The latest fix that counted for the GPS status, from this device or a companion: what the GPS
    /// status sheet shows. On the ground it is newer than `currentLocation` while the aircraft stands
    /// still, since the flight's pipeline takes a fix only 5 m on from the last (`passesGroundFilter`).
    @Published private(set) var latestFix: CLLocation?
    /// The last of this device's fixes that the ground filter let through to the pipeline.
    private var lastFilteredFix: CLLocation?
    /// Deferred-start intents: set when start is requested before authorization is decided, so
    /// the start completes automatically once permission is granted. (PERF-03)
    private var pendingTrackingStart = false
    private var pendingLocationUpdatesStart = false
    private var pendingSharedGPSProviderStart = false

    /// True while this device is acting as a companion GPS provider — delivering background-capable
    /// fixes to a paired GPS-less master WITHOUT recording its own flight. Tracked separately from
    /// `isTracking` (no flight) and `isLocationUpdatesActive` (the nav-map session) so the three
    /// independent reasons to keep GPS on don't tear each other down. (shared-GPS, v4.1)
    @Published private(set) var isSharedGPSProviderActive: Bool = false
    /// Set when an ACTIVE tracking/map session's updates were stopped because location permission
    /// was revoked mid-session. On re-authorization the session resumes itself instead of staying
    /// dead with isTracking still true. (PR-39)
    private var wasStoppedByRevocation = false

    // GPS status override (for marketing mode)
    private var gpsStatusOverride: GPSSignalStatus?

    // Marketing mode flag - when true, ignores real GPS updates
    private var marketingModeActive: Bool = false

    #if DEBUG
    /// DEV-ONLY: a ground replay feeds the fixes (`feedReplayFix`); the device's own are ignored.
    private var isReplaying = false
    #endif

    // Dynamic distance filter: on the ground the hardware takes every fix and the flight's pipeline
    // takes them 5 m apart (`groundModeDistanceFilter`); in flight a 50 m filter, for battery.
    private var isGroundMode: Bool = true
    private var flightModeDistanceFilter: CLLocationDistance = 50
    /// Ground-mode distance filter: a modest value (not every fix) so taxi/block-on detail is still
    /// captured while sub-metre GPS jitter doesn't feed the pipeline on every fix during long
    /// sub-40-kt phases. (PERF-24)
    ///
    /// Applied to the fixes, not to the hardware, since 6.1.0: as CoreLocation's `distanceFilter` it held
    /// back every fix of a parked aircraft, so the GPS status could only count the seconds since the
    /// last one, not what the receiver reported: good GPS turned the indicator amber at 20 s and red at
    /// 45 s on every stop. Every fix now reaches the status; the pipeline sees what the hardware
    /// filter gave it before (`receiveDeviceFix`).
    private let groundModeDistanceFilter: CLLocationDistance = 5

    // Speed and heading caching/smoothing
    // Prevents false stall warnings from GPS -1 (invalid) speed values by holding the last
    // valid smoothed speed. Uses EMA (exponential moving average) to smooth GPS noise (~1-2 kt).
    private var lastValidSpeedMPS: Double = 0
    private var lastValidSpeedTime: Date?
    private var smoothedSpeedMPS: Double = 0
    private var lastValidCourse: Double?
    private var lastValidCourseTime: Date?
    private let speedSmoothingAlpha: Double = 0.3       // EMA factor: responsive to real changes, smooths noise
    private let cachedValueStalenessLimit: TimeInterval = 10.0  // Matches signalDegradedThreshold

    // Display-specific smoothing: slower EMA (α=0.15) + 1-knot minimum change threshold
    // to prevent visual flickering of speed/IAS indicators between adjacent values.
    private let displaySmoothingAlpha: Double = 0.15
    private var displaySmoothedSpeedMPS: Double = 0
    private var lastDisplayedSpeedKnots: Int = 0

    // MARK: - Initialization
    
    override init() {
        super.init()
        setupLocationManager()
    }
    
    private func setupLocationManager() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        // Start in ground mode (every fix; the 5 m filter is applied to them). applyGPSPriority adjusts
        // accuracy per the user's GPSPriority; setGroundMode switches to the flight-mode filter
        // (50/100 m) when airborne.
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.activityType = .airborne

        // Background location configuration:
        // - allowsBackgroundLocationUpdates: enabled ONLY while actively tracking a flight (PR-38),
        //   in beginTrackingNow/stopTracking. A map-only session (NavigationView opened with no active
        //   flight) must not keep full-accuracy GPS running in the background — with this false, iOS
        //   suspends updates when the app backgrounds, so opening the map then leaving can't drain the
        //   battery (no blue indicator, nothing recorded) before a flight.
        // - pausesLocationUpdatesAutomatically: Disabled to prevent iOS from pausing updates
        // - showsBackgroundLocationIndicator: Shows blue bar when tracking in background
        locationManager.allowsBackgroundLocationUpdates = false
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.showsBackgroundLocationIndicator = true

        // Check current authorization
        authorizationStatus = locationManager.authorizationStatus
        accuracyAuthorization = locationManager.accuracyAuthorization
    }
    
    /// Apply GPS priority setting — adjusts accuracy and distance filter
    func applyGPSPriority(_ priority: GPSPriority) {
        switch priority {
        case .precision:
            locationManager.desiredAccuracy = kCLLocationAccuracyBest
            flightModeDistanceFilter = 50
        case .batterySaver:
            locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            flightModeDistanceFilter = 100
        }
        // Update active distance filter if in flight mode
        if !isGroundMode {
            locationManager.distanceFilter = flightModeDistanceFilter
        }
    }

    // MARK: - Public Methods

    func requestAuthorization() {
        locationManager.requestWhenInUseAuthorization()
    }
    
    func startTracking(appState: AppState, interval: TimeInterval = 5.0, airportDataService: AirportDataService? = nil, flightEventDetector: FlightEventDetector? = nil, flightPlanManager: FlightPlanManager? = nil, activeChecklist: ActiveChecklist? = nil) {
        self.appState = appState
        self.airportDataService = airportDataService
        self.flightEventDetector = flightEventDetector
        // The cues from the flight time the check slot: each one straight to the Cockpit. (6.1)
        flightEventDetector?.onCue = { [weak appState] event in appState?.noteFlightCue(event) }
        self.flightPlanManager = flightPlanManager
        self.activeChecklist = activeChecklist
        self.recordingInterval = interval
        self.lastRecordedTime = nil
        self.lastDetectionTime = nil
        self.lastWaypointPassageTime = nil
        self.lastGoodSignalTime = FlightClock.now
        self.lastLocationUpdateTime = FlightClock.now
        self.lastSatelliteFixTime = FlightClock.now   // a session starts counting the 20 s too
        self.gpsSignalStatus = .good

        guard authorizationStatus == .authorizedWhenInUse ||
              authorizationStatus == .authorizedAlways else {
            // Permission not yet decided — remember the intent and start once it's granted,
            // so a flight begun before the prompt is answered still records GPS. (PERF-03)
            pendingTrackingStart = true
            requestAuthorization()
            return
        }

        pendingTrackingStart = false
        beginTrackingNow()
    }

    /// Performs the actual tracking start once authorization is in hand.
    private func beginTrackingNow() {
        guard let appState = appState else { return }
        isTracking = true
        // PR-38: a real flight keeps recording in the background; enable it only now (not at init).
        locationManager.allowsBackgroundLocationUpdates = true
        applyGPSPriority(appState.settings.gpsPriority)
        locationManager.startUpdatingLocation()
        // Barometric altitude rides along with GPS tracking: recorded on every GPSPoint and
        // consumed by the flight-event detector as its vertical reference. Inert on devices
        // without a barometer (and on the simulator). CoreMotion keeps delivering in the
        // background while the location background session above is active.
        barometer.start()
        startSignalCheckTimer()
        requestAlwaysUpgradeIfNeeded()
        updateBackgroundTrackingLimited()
    }

    /// Upgrade WhenInUse -> Always so the GPS track survives backgrounding on long flights. (PERF-04)
    private func requestAlwaysUpgradeIfNeeded() {
        if authorizationStatus == .authorizedWhenInUse {
            locationManager.requestAlwaysAuthorization()
        }
    }

    /// Reflects whether background tracking is currently limited (GPS active under WhenInUse only).
    private func updateBackgroundTrackingLimited() {
        backgroundTrackingLimited = (isTracking || isLocationUpdatesActive || isSharedGPSProviderActive)
            && authorizationStatus == .authorizedWhenInUse
    }

    func stopTracking() {
        isTracking = false
        altitudeSamples.removeAll()
        verticalSpeedFpm = nil
        // PR-39: clear the display-session flag too — stopLocationUpdates is a no-op while tracking,
        // so without this a view gated on (isTracking || isLocationUpdatesActive) would keep showing
        // "GPS active" after the flight ends with GPS off.
        isLocationUpdatesActive = false
        wasStoppedByRevocation = false
        // PR-38: don't keep background GPS armed once the flight ends (a lingering map session must
        // not inherit flight-grade background tracking).
        locationManager.allowsBackgroundLocationUpdates = false
        locationManager.stopUpdatingLocation()
        stopSignalCheckTimer()
        barometer.stop()
        // End-of-flight flush: a landing in progress when recording stops is still a landing.
        // Six of the 53 corpus flights stop recording seconds after vacating the runway — the
        // stillness dwell never completes and the flight's only landing would be lost. Must run
        // BEFORE reset() and before appState is dropped (stopTracking precedes endFlight()).
        if let flushed = flightEventDetector?.flushEndOfFlight() {
            appState?.applyEndOfFlightLanding(flushed)
        }
        appState = nil
        airportDataService = nil
        flightEventDetector?.reset()
        flightEventDetector = nil
        flightPlanManager = nil
        hasNotifiedTakeoffTime = false
        hasConfiguredDetector = false
        lastDetectionTime = nil
        lastWaypointPassageTime = nil
        // Reset to ground mode for next flight
        isGroundMode = true
        locationManager.distanceFilter = kCLDistanceFilterNone
        lastFilteredFix = nil
        // Reset smoothed/cached values for next flight
        smoothedSpeedMPS = 0
        lastValidSpeedMPS = 0
        lastValidSpeedTime = nil
        lastValidCourse = nil
        lastValidCourseTime = nil
        displaySmoothedSpeedMPS = 0
        lastDisplayedSpeedKnots = 0
        // A simulated position serves one test flight, never the next one. (S9-25)
        stopSimulatingPosition()
    }

    /// Switch between ground mode (every fix from the hardware, 5 m apart for the pipeline: precise
    /// low-speed tracking) and flight mode (50/100 m distance filter, battery-efficient for cruise).
    /// Ground mode should be active during taxi and after landing.
    /// Flight mode should be active during airborne phases.
    func setGroundMode(_ onGround: Bool) {
        guard onGround != isGroundMode else { return }
        isGroundMode = onGround
        locationManager.distanceFilter = onGround ? kCLDistanceFilterNone : flightModeDistanceFilter
        AppLog.location.debugLine("Distance filter: \(onGround ? "ground mode (\(Int(groundModeDistanceFilter))m)" : "flight mode (\(Int(flightModeDistanceFilter))m)")")
    }

    /// Start location updates without recording (for navigation view)
    /// This enables GPS for real-time position display without storing track points
    func startLocationUpdates() {
        guard authorizationStatus == .authorizedWhenInUse ||
              authorizationStatus == .authorizedAlways else {
            // Defer until permission is granted (PERF-03)
            pendingLocationUpdatesStart = true
            requestAuthorization()
            return
        }

        pendingLocationUpdatesStart = false

        // If already tracking a flight, GPS is already active.
        // Just mark location updates as active without resetting signal state,
        // so the GPS status indicator remains consistent across views.
        if isTracking {
            isLocationUpdatesActive = true
            updateBackgroundTrackingLimited()
            return
        }

        locationManager.startUpdatingLocation()
        lastLocationUpdateTime = FlightClock.now
        lastSatelliteFixTime = FlightClock.now   // a session starts counting the 20 s too
        gpsSignalStatus = .good
        isLocationUpdatesActive = true
        startSignalCheckTimer()
        updateBackgroundTrackingLimited()
    }

    /// Stop location updates when navigation view is closed
    /// Only stops if not currently tracking a flight or feeding a companion master
    func stopLocationUpdates() {
        // Keep GPS running if a flight is tracking OR we're still sourcing GPS for a companion master.
        if !isTracking && !isSharedGPSProviderActive {
            locationManager.stopUpdatingLocation()
            stopSignalCheckTimer()
            isLocationUpdatesActive = false
        } else {
            // The nav map no longer needs GPS, but a flight/provider still does — just drop the
            // map-session flag and leave the hardware running for them.
            isLocationUpdatesActive = false
        }
    }

    // MARK: - Companion GPS Provider (shared-GPS, v4.1)

    /// Start delivering GPS fixes so this device can act as a companion GPS provider for a paired master
    /// that has no GPS of its own — WITHOUT recording a flight. Arms Always + background updates so the
    /// feed survives the viewer being backgrounded (best-effort: the Wi-Fi Aware link itself may suspend
    /// in the background). Idempotent; defers until permission is granted, like a flight start. (shared-GPS)
    func startSharedGPSProvider() {
        guard !isSharedGPSProviderActive else { return }
        guard authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways else {
            // Remember the intent and start once permission is granted. (mirrors PERF-03)
            pendingSharedGPSProviderStart = true
            requestAuthorization()
            return
        }
        pendingSharedGPSProviderStart = false
        isSharedGPSProviderActive = true
        // Arm background updates so the feed keeps going when the viewer is backgrounded (needs Always).
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.startUpdatingLocation()
        lastLocationUpdateTime = FlightClock.now
        lastSatelliteFixTime = FlightClock.now   // a session starts counting the 20 s too
        gpsSignalStatus = .good
        startSignalCheckTimer()
        // Upgrade WhenInUse → Always so the feed isn't suspended the moment the viewer backgrounds.
        requestAlwaysUpgradeIfNeeded()
        updateBackgroundTrackingLimited()
    }

    /// Stop acting as a companion GPS provider. Leaves a running flight or nav-map GPS session untouched.
    func stopSharedGPSProvider() {
        guard isSharedGPSProviderActive else { return }
        isSharedGPSProviderActive = false
        pendingSharedGPSProviderStart = false
        // Disarm background updates unless a flight still needs them (a flight re-arms via beginTrackingNow).
        if !isTracking {
            locationManager.allowsBackgroundLocationUpdates = false
        }
        // Only stop the GPS hardware if nothing else still needs it (no flight, no nav-map session).
        if !isTracking && !isLocationUpdatesActive {
            locationManager.stopUpdatingLocation()
            stopSignalCheckTimer()
            // GPS is now off — `checkSignalStatus` early-returns with no active session, so reset the
            // published status to `.lost` instead of leaving a stale `.good`. (v4.1.0 pre-tag fix)
            gpsSignalStatus = .lost
        }
        updateBackgroundTrackingLimited()
    }

    // MARK: - Signal Quality Monitoring

    private func startSignalCheckTimer() {
        // Invalidate existing timer to prevent duplicates (e.g. if startTracking and
        // startLocationUpdates are both called)
        signalCheckTimer?.invalidate()
        // PR-21: schedule in .common run-loop mode so the signal check keeps firing during scroll
        // gestures (scheduledTimer uses .default, which stalls while a UIScrollView tracks).
        let timer = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkSignalStatus()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        signalCheckTimer = timer
        fixDigest = GPSFixDigest()
        signalChecks = 0
        startLiveDiagnostics()
    }

    private func stopSignalCheckTimer() {
        signalCheckTimer?.invalidate()
        signalCheckTimer = nil
        liveDiagnostics?.cancel()
        liveDiagnostics = nil
    }

    // MARK: - What the GPS delivers, in the log (6.1.0)
    //
    // A parked iPad stayed green for minutes in a closed microwave oven (6.1.0 device check, gps-2), with
    // a fix every second at ± 7–9 m. Whether Core Location was still tracking satellites through the
    // door or holding a position it estimated, the app can't see: `horizontalAccuracy` is "the radius of
    // uncertainty for the location", not a signal strength, and nothing in the API names the source (GNSS,
    // Wi-Fi, cell, sensors). What it can do is keep a record: every 10 s, one line of what the fixes
    // carried, and, from iOS 18, whether Core Location itself said the location was unavailable
    // (`CLLocationUpdate.locationUnavailable`, "unable to determine their location at all"). Counts and
    // ranges only, never a position, so the lines are public and survive in a `log collect` archive.

    private var fixDigest = GPSFixDigest()
    private var signalChecks = 0
    private var liveDiagnostics: Task<Void, Never>?
    private var liveSaysUnavailable = false

    /// Core Location's own diagnostics, alongside the location manager's fixes: recorded, not acted on.
    private func startLiveDiagnostics() {
        guard liveDiagnostics == nil else { return }
        guard #available(iOS 18.0, *) else { return }
        liveDiagnostics = Task { @MainActor [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates(.airborne) {
                    guard let self, !Task.isCancelled else { return }
                    self.noteLiveDiagnostics(unavailable: update.locationUnavailable, stationary: update.stationary)
                }
            } catch {
                AppLog.location.publicNotice("GPS: Core Location's diagnostics ended on an error")
            }
        }
    }

    private func noteLiveDiagnostics(unavailable: Bool, stationary: Bool) {
        fixDigest.noteDiagnostics(unavailable: unavailable, stationary: stationary)
        if unavailable != liveSaysUnavailable {
            liveSaysUnavailable = unavailable
            AppLog.location.publicNotice(unavailable ? "GPS: Core Location says the location is unavailable"
                                                     : "GPS: Core Location has a location again")
        }
    }

    /// Every other signal check (10 s): the line, then a fresh count.
    private func logFixDigest() {
        signalChecks += 1
        guard signalChecks % 2 == 0 else { return }
        AppLog.location.publicNotice(fixDigest.line(seconds: 10, status: gpsSignalStatus))
        fixDigest.startNextStretch()
    }

    /// Pure, unit-testable GPS signal-status decision (PR-35). Extracted from `checkSignalStatus`
    /// so the 10 / 20 / 45 s boundaries are pinned by tests and stop drifting from their comments
    /// (the old inline comments claimed 15 / 45 / 90 s while the constants were 10 / 20 / 45 s).
    /// `current` is the present status because some escalations only fire from `.good`.
    nonisolated static func signalStatus(
        timeSinceLastUpdate: TimeInterval,
        lastKnownAccuracy: CLLocationAccuracy,
        current: GPSSignalStatus,
        degradedThreshold: TimeInterval = 10,
        lostThreshold: TimeInterval = 20,
        trulyLostThreshold: TimeInterval = 45,
        accuracyThreshold: CLLocationAccuracy = 100,
        timeSinceSatelliteFix: TimeInterval? = nil
    ) -> GPSSignalStatus {
        let lastAccuracyWasGood = lastKnownAccuracy >= 0 && lastKnownAccuracy <= accuracyThreshold
        if timeSinceLastUpdate >= trulyLostThreshold {
            return .lost                                    // ≥45 s: truly lost (red), regardless of accuracy
        } else if timeSinceLastUpdate >= lostThreshold {
            return current == .good ? .degraded : current   // ≥20 s: degrade a good signal
        } else if let timeSinceSatelliteFix, timeSinceSatelliteFix >= lostThreshold {
            return .degraded                                 // positions, but none from the satellites for 20 s (6.1.0)
        } else if lastAccuracyWasGood {
            return .good                                     // <20 s and last fix was good: stay good
        } else if timeSinceLastUpdate >= degradedThreshold {
            return current == .good ? .degraded : current   // ≥10 s with a poor last fix: degrade
        } else {
            return current                                   // <10 s, poor last fix: unchanged
        }
    }

    private func checkSignalStatus() {
        guard isTracking || isLocationUpdatesActive || isSharedGPSProviderActive else { return }
        defer { logFixDigest() }

        // If GPS status is overridden (marketing mode), don't check real signal
        if let override = gpsStatusOverride {
            gpsSignalStatus = override
            return
        }

        // Location access revoked mid-session: lost until it comes back. The last fix being recent, the
        // seconds rules below turned the indicator green again on the next tick. (UX-01; 6.1.0)
        if wasStoppedByRevocation {
            gpsSignalStatus = .lost
            return
        }

        guard let lastUpdate = lastLocationUpdateTime else {
            // Never received a location update — GPS truly lost
            gpsSignalStatus = .lost
            return
        }

        let now = FlightClock.now
        let timeSinceLastUpdate = now.timeIntervalSince(lastUpdate)
        let computed = Self.signalStatus(
            timeSinceLastUpdate: timeSinceLastUpdate,
            lastKnownAccuracy: lastKnownAccuracy,
            current: gpsSignalStatus,
            degradedThreshold: signalDegradedThreshold,
            lostThreshold: signalLostThreshold,
            trulyLostThreshold: signalTrulyLostThreshold,
            accuracyThreshold: horizontalAccuracyThreshold,
            timeSinceSatelliteFix: lastSatelliteFixTime.map { now.timeIntervalSince($0) })

        // A parked aircraft keeps its fixes coming since 6.1.0 (`groundModeDistanceFilter`), so the
        // seconds without one mean what they say. The one-shot probe that stood in for them while
        // parked (PR-21) is gone: `requestLocation()` can't be used beside `startUpdatingLocation()`,
        // and on the device it brought nothing back.
        gpsSignalStatus = computed
    }

    /// Update smoothed speed (EMA) and cached heading from a new location update.
    /// Invalid values (speed/course = -1) are skipped, preserving the last valid reading.
    private func updateSmoothedValues(from location: CLLocation) {
        let now = FlightClock.now

        // Speed: apply exponential moving average, skip invalid (-1) readings
        if location.speed >= 0 {
            if lastValidSpeedTime != nil {
                // Primary EMA (α=0.3): responsive, used for event detection
                smoothedSpeedMPS = speedSmoothingAlpha * location.speed + (1.0 - speedSmoothingAlpha) * smoothedSpeedMPS
                // Display EMA (α=0.15): slower, used for visual stability
                displaySmoothedSpeedMPS = displaySmoothingAlpha * location.speed + (1.0 - displaySmoothingAlpha) * displaySmoothedSpeedMPS
            } else {
                // First valid reading — initialize without smoothing
                smoothedSpeedMPS = location.speed
                displaySmoothedSpeedMPS = location.speed
            }
            lastValidSpeedMPS = location.speed
            lastValidSpeedTime = now

            // Update display integer with 1-knot hysteresis to prevent flickering.
            // SEC-C15: `Int(Double)` traps on a non-finite or out-of-range value. The peer-GPS
            // envelope check upstream should make that impossible, but this is the line that
            // actually kills the process, so it does not rely on a caller getting it right.
            let currentDisplayKnots = (displaySmoothedSpeedMPS * 1.94384).safeInt(or: lastDisplayedSpeedKnots)
            if abs(currentDisplayKnots - lastDisplayedSpeedKnots) >= 1 {
                lastDisplayedSpeedKnots = currentDisplayKnots
            }
        }

        // Course: cache last valid value (no smoothing needed for heading)
        if location.course >= 0 {
            lastValidCourse = location.course
            lastValidCourseTime = now
        }
    }

    private func updateSignalQuality(from location: CLLocation, isOwnFix: Bool = true, now: Date = FlightClock.now) {
        // If GPS status is overridden (marketing mode), don't update from real signal
        if gpsStatusOverride != nil {
            return
        }

        let accuracy = location.horizontalAccuracy
        fixDigest.add(location, borrowed: !isOwnFix, now: now)

        // A fix counts from when it was determined, not from when it arrived: Core Location "sometimes
        // returns cached events" (Apple: check the timestamp of any location event). A late one never
        // turns the signal good, nor moves its time back. A companion's fix carries the peer's clock, so
        // it counts from now, as the pipeline treats it. (6.1.0)
        let fixTime = isOwnFix ? min(now, location.timestamp) : now
        if let last = lastLocationUpdateTime, fixTime < last { return }
        lastLocationUpdateTime = fixTime
        lastKnownAccuracy = accuracy
        latestFix = location
        guard now.timeIntervalSince(fixTime) < signalDegradedThreshold else { return }

        // Negative accuracy means invalid - mark as degraded
        if accuracy < 0 {
            if gpsSignalStatus == .good {
                gpsSignalStatus = .degraded
            }
            return
        }

        // Good accuracy - signal is good, from the satellites. A Wi-Fi or cell position as good degrades
        // the signal once the last satellite fix is 20 s old (`isSatelliteFix`). A companion's fix comes
        // from the peer's own GPS pipeline and counts as it always has. (6.1.0)
        if accuracy <= horizontalAccuracyThreshold {
            guard !isOwnFix || Self.isSatelliteFix(location) else {
                if let last = lastSatelliteFixTime, now.timeIntervalSince(last) >= signalLostThreshold {
                    gpsSignalStatus = .degraded
                }
                return
            }
            lastSatelliteFixTime = fixTime
            lastGoodSignalTime = now
            gpsSignalStatus = .good
        } else {
            // Poor accuracy (inaccurate) - mark as degraded
            if gpsSignalStatus != .lost {
                gpsSignalStatus = .degraded
            }
        }
    }
    
    func getCurrentCoordinate() -> CLLocationCoordinate2D? {
        currentLocation?.coordinate
    }
    
    /// Current speed in knots (smoothed, with caching for GPS -1 values)
    /// Responsive EMA (α=0.3) — use for event detection, GPS recording, internal logic.
    var currentSpeedKnots: Double {
        currentSpeedMPS * 1.94384 // m/s to knots
    }

    /// Current speed in m/s (smoothed, with caching for GPS -1 values)
    /// Returns the EMA-smoothed speed if a valid reading was received within the staleness limit.
    /// Falls back to raw CLLocation speed, then 0.
    var currentSpeedMPS: Double {
        if let lastTime = lastValidSpeedTime,
           FlightClock.now.timeIntervalSince(lastTime) < cachedValueStalenessLimit {
            return smoothedSpeedMPS
        }
        // Stale or no valid reading yet: try raw current location
        if let speed = currentLocation?.speed, speed >= 0 { return speed }
        return 0
    }

    /// Display speed in knots with 1-knot hysteresis (extra-smoothed for visual stability)
    /// Only changes when the speed moves by ≥1 knot, preventing flickering between adjacent values.
    var displaySpeedKnots: Double {
        Double(lastDisplayedSpeedKnots)
    }

    /// Current course/heading in degrees (cached for GPS -1 values)
    /// Returns the last valid course if received within the staleness limit.
    /// Returns nil if no valid course is available (consumer can fall back to 0 or "---").
    var currentCourseDegrees: Double? {
        if let course = lastValidCourse, let lastTime = lastValidCourseTime,
           FlightClock.now.timeIntervalSince(lastTime) < cachedValueStalenessLimit {
            return course
        }
        if let course = currentLocation?.course, course >= 0 { return course }
        return nil
    }

    /// Current altitude in meters (raw GPS value)
    var currentAltitudeMeters: Double {
        currentLocation?.altitude ?? 0
    }

    /// Current altitude in feet (converted from meters)
    var currentAltitudeFeet: Double {
        currentAltitudeMeters * 3.28084 // meters to feet
    }

    /// Derive a smoothed vertical speed (fpm) from the GPS altitude trend over the last ~12 s. GPS
    /// altitude is noisy, so the value is averaged across the window and EMA-smoothed; nil until there
    /// are at least two samples spanning ≥2 s. (v4 UI/UX Revamp — instrument strip VSI)
    private func updateVerticalSpeed(altitudeFt: Double) {
        let now = FlightClock.now
        altitudeSamples.append((now, altitudeFt))
        let cutoff = now.addingTimeInterval(-verticalSpeedWindow)
        altitudeSamples.removeAll { $0.time < cutoff }

        guard let oldest = altitudeSamples.first, altitudeSamples.count >= 2 else {
            verticalSpeedFpm = nil
            return
        }
        let dt = now.timeIntervalSince(oldest.time)
        guard dt >= 2 else { return }

        let fpm = ((altitudeFt - oldest.altFt) / dt) * 60.0
        // Light EMA so the readout doesn't jitter with GPS altitude noise.
        verticalSpeedFpm = verticalSpeedFpm.map { $0 * 0.5 + fpm * 0.5 } ?? fpm
    }

    // MARK: - GPS Status Override (for Marketing Mode)

    /// Override the GPS signal status (used by marketing mode to show stable GPS)
    /// Also activates marketing mode which ignores real GPS updates
    func overrideGPSStatus(_ status: GPSSignalStatus) {
        gpsStatusOverride = status
        gpsSignalStatus = status
        marketingModeActive = true
    }

    /// Clear the GPS status override and return to normal signal checking
    func clearGPSStatusOverride() {
        gpsStatusOverride = nil
        marketingModeActive = false
    }

    // MARK: - Marketing Static Fix Injection (DEV-ONLY)

    /// Inject a held static GPS fix for marketing screenshots and PRIME the smoothed/cached values
    /// that drive the instrument strip. (DEV-ONLY — Marketing Mode scene injector)
    ///
    /// Setting `currentLocation` alone only lights ALT (which reads `currentLocation` directly). SPD
    /// uses `displaySpeedKnots` (driven by `lastDisplayedSpeedKnots`) and HDG uses
    /// `currentCourseDegrees` (driven by `lastValidCourse`), both of which are normally only updated
    /// inside `didUpdateLocations` — which is skipped while `marketingModeActive`. So this method
    /// pre-loads those caches directly so SPD / ALT / HDG all read the injected values immediately.
    /// Activates the marketing override (real GPS ignored, status forced good).
    func injectMarketingStaticFix(_ location: CLLocation) {
        // Force the override on, so real fixes are ignored and the GPS indicator stays green.
        overrideGPSStatus(.good)
        // And say it records, as a real flight's GPS does: since 6.0 an active flight whose GPS isn't
        // recording turns the indicator red, which put an alarm on every in-flight screenshot.
        isTracking = true

        currentLocation = location
        latestFix = nil

        let now = Date()
        let speedMPS = max(location.speed, 0)
        smoothedSpeedMPS = speedMPS
        displaySmoothedSpeedMPS = speedMPS
        lastValidSpeedMPS = speedMPS
        lastValidSpeedTime = now
        lastDisplayedSpeedKnots = Int(speedMPS * 1.94384)

        if location.course >= 0 {
            lastValidCourse = location.course
            lastValidCourseTime = now
        }

        // Seed a flat vertical-speed reading so the VSI shows a value rather than "---".
        verticalSpeedFpm = 0
    }

    // MARK: - Simulated Position (developer option)

    /// Whether real GPS is being ignored for a position held by the developer option.
    var isSimulatingPosition: Bool { simulatedPosition != nil }

    /// Holds a static fix at `location` and ignores real GPS, so the departure briefing can be
    /// tried away from an airfield.
    ///
    /// S9-25: the developer option used to call the marketing injector as is, which also holds the
    /// GPS status at GREEN, and only its switch turned it off again, a switch whose state the About
    /// page forgot once left. A flight started later in the same run showed a static position at
    /// Samedan under a healthy green GPS, and recorded no track. The status is now held at degraded
    /// (orange, the instruments' failure flags up), the GPS panel and the cockpit's GPS label say it
    /// is simulated, and ending a flight or leaving developer mode turns it off.
    func startSimulatingPosition(at location: CLLocation) {
        injectMarketingStaticFix(location)
        gpsStatusOverride = .degraded
        gpsSignalStatus = .degraded
        simulatedPosition = location
    }

    /// Back to real GPS. A no-op when no position is simulated, so it never touches the marketing
    /// scenes' own override.
    func stopSimulatingPosition() {
        guard simulatedPosition != nil else { return }
        simulatedPosition = nil
        clearGPSStatusOverride()
        // The injector sets `isTracking`, as a recording flight would. With no flight, nothing is.
        if appState == nil {
            isTracking = false
            gpsSignalStatus = .good
        }
        // Nothing may take the held position for a fix: a flight started now would begin there.
        currentLocation = nil
        latestFix = nil
    }

    // MARK: - Companion Shared GPS (v4.1)

    /// True when this device produced a usable OWN GPS fix within the last few seconds. Independent of
    /// `currentLocation`, which may hold a *borrowed* companion fix. Drives the `ownGPSAvailable` flag
    /// the master broadcasts (so borrowing never flips it back) and gates borrowing. (shared-GPS)
    var ownFixIsLive: Bool {
        guard let t = lastOwnFixTime else { return false }
        return FlightClock.now.timeIntervalSince(t) <= ownFixStaleAfter
    }

    /// Whether there's a usable fix to START a flight from: GPS is actively running and we hold a valid
    /// position. Deliberately NOT gated on fix AGE (unlike `ownFixIsLive`'s tight window) — a stationary
    /// aircraft on the ramp legitimately stops producing new fixes (the ground-mode distance filter
    /// suppresses updates when not moving), but its last known position is still valid to begin recording
    /// from. Gating the start on a seconds-fresh fix wrongly blocked a stationary start with
    /// "Acquiring GPS…" even with a green GPS indicator. (v4.1 flight-start fix)
    var hasRecentUsableFix: Bool {
        guard isLocationUpdatesActive || isTracking || isSharedGPSProviderActive else { return false }
        guard let loc = currentLocation else { return false }
        return loc.horizontalAccuracy >= 0
    }

    /// Feed a borrowed companion (peer) GPS fix through the SAME pipeline as a real fix, so nav, the
    /// HUD instrument strip, the recorded track and event detection all consume it transparently.
    /// Applied only when this device has no live own fix — a real own fix always wins. (shared-GPS)
    func injectCompanionLocation(_ location: CLLocation) {
        guard !marketingModeActive else { return }
        guard !ownFixIsLive else { return }
        processLocation(location, isOwnFix: false)
    }

    /// A fix from this device's own GPS. Every one counts for the GPS status, its time and accuracy; the
    /// flight's pipeline (`processLocation`) takes them as the ground filter lets them through, which is
    /// what CoreLocation's distance filter gave it before 6.1.0. (`groundModeDistanceFilter`)
    ///
    /// `now` for the tests; the delegate passes the clock.
    func receiveDeviceFix(_ location: CLLocation, now: Date = FlightClock.now) {
        guard !marketingModeActive else { return }
        if Self.passesGroundFilter(location, lastPassed: lastFilteredFix, groundMode: isGroundMode,
                                   filter: groundModeDistanceFilter) {
            lastFilteredFix = location
            processLocation(location, isOwnFix: true, now: now)
            return
        }
        // Held back from the pipeline: still a fix, for the own-GPS liveness and the status.
        if countsAsLiveOwnFix(location) {
            lastOwnFixTime = now
        }
        updateSignalQuality(from: location, now: now)
    }

    /// The filter CoreLocation applies now: none on the ground, 50/100 m in flight. (tests)
    var hardwareDistanceFilter: CLLocationDistance { locationManager.distanceFilter }

    /// Whether a fix came from the satellites. Core Location doesn't name a fix's source, but a satellite
    /// fix carries a speed measured from the signals, with its accuracy; a Wi-Fi or cell position has none
    /// (`speedAccuracy` −1). On 3 Oct 2026 the author's iPad sat 3 minutes in a basement with the GNSS
    /// receiver on and reporting no fix, while Core Location handed the app Wi-Fi positions at ± 14–78 m,
    /// each with no speed accuracy: the GPS indicator stayed green. (6.1.0)
    ///
    /// A fix from an external receiver (an MFi GPS such as those many pilots pair with a Wi-Fi iPad)
    /// counts too: Core Location marks it `isProducedByAccessory`, and whether it carries a speed
    /// accuracy is up to the accessory. (6.1.1, Wi-Fi iPads)
    ///
    /// The simulator has no satellites: its simulated positions stand for them, except under the tests.
    nonisolated static func isSatelliteFix(_ location: CLLocation) -> Bool {
        if everyFixIsSatellite { return true }
        if location.sourceInformation?.isProducedByAccessory == true { return true }
        return location.speedAccuracy >= 0
    }

    nonisolated static let everyFixIsSatellite: Bool = {
        #if targetEnvironment(simulator)
        return NSClassFromString("XCTestCase") == nil
        #else
        return false
        #endif
    }()

    /// Pure, unit-testable: whether a fix of this device goes on to the pipeline. In flight, every one
    /// the hardware's 50/100 m filter delivers; on the ground, one `filter` metres or more from the last
    /// that went on, the first one always.
    nonisolated static func passesGroundFilter(_ location: CLLocation, lastPassed: CLLocation?,
                                               groundMode: Bool, filter: CLLocationDistance) -> Bool {
        guard groundMode, let lastPassed else { return true }
        return location.distance(from: lastPassed) >= filter
    }

    #if DEBUG
    /// DEV-ONLY (ground replays, `GroundReplay`): one fix of a recorded flight, through the device's own
    /// path at the replay's clock, with its barometric altitude when the flight had one. From the first,
    /// the device's own fixes are ignored. Nothing else is bypassed: no GPS status override, no
    /// marketing mode.
    func feedReplayFix(_ location: CLLocation, baroRelativeAltitudeM: Double? = nil) {
        isReplaying = true
        let now = FlightClock.now
        if let baroRelativeAltitudeM { barometer.ingest(relativeAltitudeM: baroRelativeAltitudeM, at: now) }
        processLocation(location, isOwnFix: true, now: now)
    }
    #endif

    /// The single GPS-processing pipeline, shared by real device fixes (`isOwnFix == true`) and
    /// borrowed companion fixes (`isOwnFix == false`). Updates the displayed location, smoothed
    /// instruments, signal quality, the recorded track and event detection, so a borrowed fix is
    /// indistinguishable downstream from a real one. (shared-GPS, v4.1)
    ///
    /// `now` is the receiving clock: the cadences and a fix's age are measured on it. Only a test
    /// replaying a recorded flight passes one.
    func processLocation(_ location: CLLocation, isOwnFix: Bool, now: Date = FlightClock.now) {
        // When marketing mode is active, ignore real GPS updates
        // (marketing location is injected directly via currentLocation property)
        guard !marketingModeActive else { return }

        // Track own-fix liveness from real device fixes only, so companion borrowing can't flip it.
        // Require usable accuracy (not just a valid sign) so a coarse own fix doesn't suppress a better
        // borrowed peer fix — matches the election's accuracy bar (shared-GPS) — and a satellite fix, so
        // a Wi-Fi position doesn't either (`countsAsLiveOwnFix`, 6.1.1).
        if isOwnFix && countsAsLiveOwnFix(location) {
            lastOwnFixTime = now
        }

        // Update current location
        currentLocation = location

        // Update smoothed speed and cached heading
        updateSmoothedValues(from: location)

        // Update smoothed vertical speed from the GPS altitude trend
        updateVerticalSpeed(altitudeFt: location.altitude * 3.28084)

        // Update signal quality based on accuracy
        updateSignalQuality(from: location, isOwnFix: isOwnFix, now: now)

        // Check if we should record this point
        let shouldRecord: Bool
        if let lastTime = lastRecordedTime {
            shouldRecord = now.timeIntervalSince(lastTime) >= recordingInterval
        } else {
            shouldRecord = true
        }

        // Auto-switch ground/flight mode based on speed for battery optimization
        // Ground mode: no distance filter (precise low-speed tracking for block on detection)
        // Flight mode: 50m filter (battery-efficient during airborne phases)
        if isTracking && location.speed >= 0 {
            let speedKts = location.speed * 1.94384
            if isGroundMode && speedKts > 40 {
                setGroundMode(false)
            } else if !isGroundMode && speedKts < 20 {
                setGroundMode(true)
            }
        }

        // PR-37: skip recording AND event detection for a stale or invalid fix. CoreLocation routinely
        // delivers a cached (possibly minutes-old) fix right after startUpdatingLocation, and a negative
        // horizontalAccuracy is invalid — either would otherwise become a track point (e.g. a hangar fix
        // as the first point of every flight) and feed the detector. currentLocation is still updated
        // above for display.
        //
        // A *borrowed* companion fix carries the peer device's clock, so its embedded timestamp can't be
        // compared to our clock — its freshness was already validated on the sender and re-checked by the
        // election before injection, so we treat it as fresh (age 0) to avoid spurious clock-skew rejection.
        let fixAge = isOwnFix ? abs(location.timestamp.timeIntervalSince(now)) : 0
        let fixIsUsable = fixAge <= 10 && location.horizontalAccuracy >= 0
        if shouldRecord, fixIsUsable, let appState = appState {
            // A borrowed companion fix carries the peer device's clock; re-stamp it with our own clock
            // (`now`) so the recorded track and the flight events stay in one clock domain. (v4.1.0)
            let point = GPSPoint(from: location,
                                 timestampOverride: isOwnFix ? nil : now,
                                 baroAltitude: barometer.rawRelativeAltitudeM)
            appState.addGPSPoint(point, airportDataService: airportDataService)
            lastRecordedTime = now
        }

        // Waypoints passed: the ATO and the next waypoint, whichever screen is showing and with the
        // app in the background. The track above is the evidence, so a stale or invalid fix, which
        // it never records, doesn't trigger a run either. (v6.0.1)
        let passageDue = lastWaypointPassageTime.map {
            now.timeIntervalSince($0) >= Self.waypointPassageIntervalSeconds
        } ?? true
        if passageDue, fixIsUsable, let appState, appState.isFlightActive,
           let flightPlanManager, let track = appState.currentFlight?.gpsTrack {
            lastWaypointPassageTime = now
            // Once the track shows the take-off, LINE UP tapped or not, the ETOs count from it and it is
            // the departure's time over. (6.1)
            flightPlanManager.followTakeoff(track: track, engineStart: appState.engineStartTime,
                                            flightPlanId: appState.currentFlight?.flightPlanId)
            flightPlanManager.catchUpWaypointPassages(track: track, takeoff: appState.lineUpTime,
                                                      flightPlanId: appState.currentFlight?.flightPlanId)
        }

        // Event detection runs independently of recording so it isn't starved at slow recording
        // intervals — feed the detector every fix, capped at `detectionIntervalCapSeconds`. (PR-23)
        let detectionInterval = min(recordingInterval, Self.detectionIntervalCapSeconds)
        let shouldDetect = lastDetectionTime.map { now.timeIntervalSince($0) >= detectionInterval } ?? true
        if shouldDetect, fixIsUsable, let appState = appState,
           let detector = flightEventDetector,
           let airportService = airportDataService,
           (appState.engineStartTime != nil || currentSpeedKnots > 30) {
            lastDetectionTime = now

            // Auto-configure the detector with aircraft speeds + the DETECTION cadence (so its
            // reading-count thresholds scale to how often it's actually fed, not the recording
            // interval). Re-configure if the effective detection interval changed. (PR-23)
            if !hasConfiguredDetector {
                let checklist = activeChecklist ?? .bundledDefault
                detector.configure(speeds: checklist.speeds, stallSpeed: checklist.stallSpeed, recordingInterval: detectionInterval)
                hasConfiguredDetector = true
            }

            // Notify detector of takeoff time once for initial suppression
            if !hasNotifiedTakeoffTime, let lineUpTime = appState.lineUpTime {
                detector.setTakeoffTime(lineUpTime)
                hasNotifiedTakeoffTime = true
            }

            // Get nearby airports for event detection. Fixed-wing only: the v2 detector's
            // altitude anchor must never land on a heliport or closed strip (its "AGL"
            // flapped ±440 ft at LSZQ when it did — failure mechanism M4).
            let nearbyAirports = airportService.findNearestAirports(
                to: location.coordinate,
                limit: 3,
                maxDistanceNm: 5.0,
                types: AirportType.fixedWing
            )
            // The approach check is due 5 NM from where the flight is going: its own route's end, or the
            // aerodrome it diverted to. Only the flight's own plan, as for the ATOs. (6.1, cues)
            let plan = flightPlanManager?.activeFlightPlan
            detector.cueDestination = plan?.id == appState.currentFlight?.flightPlanId ? plan?.cueDestination : nil
            detector.processLocation(location, nearbyAirports: nearbyAirports, baroSample: barometer.currentSample)
            // A field to anchor the take-off to: the cues will time the checks from the first roll on, so
            // the climb check waits for 500 ft rather than show due on the runway. (6.1.0)
            if !nearbyAirports.isEmpty { appState.noteCueSourceReady() }
            // A full stop on a flight that isn't circuits is the landed card's, whatever screen is up:
            // the Companion shows it from the iPad's snapshot. (6.1, M4)
            if appState.takeFullStopForLandedCard(detector.pendingFullStop) { detector.dismissFullStop() }
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationManager: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            #if DEBUG
            if self.isReplaying { return }
            #endif
            self.receiveDeviceFix(location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.locationError = error.localizedDescription
        }
    }

    /// What an authorization change means for a session that is already running. (CQ-05)
    ///
    /// Extracted as a pure value because the surrounding delegate needs a live `CLLocationManager`,
    /// so the revoked-mid-flight path — recording silently stopping, and whether it comes back on
    /// re-authorization — had no test seam at all and was never exercised except by hand.
    enum RevocationTransition: Equatable {
        /// Authorization was lost while a session was running: stop the now-useless updates,
        /// surface GPS-lost, and remember to resume.
        case stopAndRemember
        /// Re-authorized after a revocation stopped an active session: restart updates. (PR-39)
        case resume
        /// Nothing to do — no active session, or no revocation to recover from.
        case none
    }

    /// - Parameters:
    ///   - isAuthorized: whether the new status is `authorizedWhenInUse` or `authorizedAlways`.
    ///   - hasActiveSession: tracking, plain location updates, or the shared-GPS provider is running.
    ///   - wasStoppedByRevocation: a previous revocation stopped an active session.
    nonisolated static func revocationTransition(
        isAuthorized: Bool,
        hasActiveSession: Bool,
        wasStoppedByRevocation: Bool
    ) -> RevocationTransition {
        guard hasActiveSession else { return .none }
        if isAuthorized {
            return wasStoppedByRevocation ? .resume : .none
        }
        return .stopAndRemember
    }

    /// True when any location session is running — the precondition for a revocation to matter.
    private var hasActiveLocationSession: Bool {
        isTracking || isLocationUpdatesActive || isSharedGPSProviderActive
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.authorizationStatus = manager.authorizationStatus
            // Reduced accuracy can be toggled independently of the authorization state, and the
            // delegate fires for it too, so read it on every change rather than only at start. (RES-09)
            self.accuracyAuthorization = manager.accuracyAuthorization

            switch self.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                self.locationError = nil
                // Complete any deferred start now that permission is granted (PERF-03)
                if self.pendingTrackingStart {
                    self.pendingTrackingStart = false
                    self.beginTrackingNow()
                }
                if self.pendingLocationUpdatesStart {
                    self.startLocationUpdates()
                }
                if self.pendingSharedGPSProviderStart {
                    self.startSharedGPSProvider()
                }
                // PR-39: resume a session whose updates we stopped on a prior revocation. The
                // deferred-start flags above only cover sessions that never started; one already
                // active (isTracking/isLocationUpdatesActive/provider still true) was previously left dead.
                if Self.revocationTransition(
                    isAuthorized: true,
                    hasActiveSession: self.hasActiveLocationSession,
                    wasStoppedByRevocation: self.wasStoppedByRevocation
                ) == .resume {
                    self.wasStoppedByRevocation = false
                    self.locationManager.startUpdatingLocation()
                    self.lastLocationUpdateTime = FlightClock.now
                    self.lastSatelliteFixTime = FlightClock.now   // a session starts counting the 20 s too
                    self.gpsSignalStatus = .good
                    self.startSignalCheckTimer()
                }
                self.updateBackgroundTrackingLimited()
            case .denied, .restricted:
                self.locationError = self.authorizationStatus == .denied
                    ? "Location access denied. Please enable in Settings."
                    : "Location access restricted."
                self.pendingTrackingStart = false
                self.pendingLocationUpdatesStart = false
                self.pendingSharedGPSProviderStart = false
                self.backgroundTrackingLimited = false
                // Permission revoked while active — stop the now-useless updates and surface a
                // GPS-lost state so the indicator never looks green on a revoked permission. (UX-01)
                if Self.revocationTransition(
                    isAuthorized: false,
                    hasActiveSession: self.hasActiveLocationSession,
                    wasStoppedByRevocation: self.wasStoppedByRevocation
                ) == .stopAndRemember {
                    self.gpsSignalStatus = .lost
                    self.locationManager.stopUpdatingLocation()
                    self.wasStoppedByRevocation = true // PR-39: remember to resume on re-authorization
                }
            case .notDetermined:
                self.locationError = nil
            @unknown default:
                self.locationError = "Unknown authorization status."
            }
        }
    }
}
