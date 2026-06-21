import Foundation
import CoreLocation
import Combine

/// GPS signal quality status
enum GPSSignalStatus {
    case good       // Green: GPS functioning, accurate position available
    case degraded   // Orange: GPS working but accuracy poor or updates infrequent
    case lost       // Red: GPS truly lost — no position data available
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
    @Published var isTracking: Bool = false
    @Published var isLocationUpdatesActive: Bool = false // True when GPS is active (even without flight tracking)
    @Published var locationError: String?
    @Published var gpsSignalStatus: GPSSignalStatus = .good
    /// True when GPS is active but only WhenInUse authorization is granted, so the track may
    /// stop if the app is backgrounded. Drives an in-flight warning banner. (PERF-04)
    @Published var backgroundTrackingLimited: Bool = false

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

    /// Rolling (time, altitude-ft) samples over the last ~12 s, for the smoothed vertical speed.
    private var altitudeSamples: [(time: Date, altFt: Double)] = []
    private let verticalSpeedWindow: TimeInterval = 12.0

    /// Event detection runs on its OWN cadence, independent of (and never slower than) the GPS
    /// *recording* interval. At a slow recording interval (e.g. 30 s) the detector would otherwise
    /// see one fix per 30 s — far too coarse to resolve a touchdown/go-around — so detection is
    /// capped to at most this many seconds between fixes it processes. (PR-23)
    private static let detectionIntervalCapSeconds: TimeInterval = 5.0
    private var lastDetectionTime: Date?
    private weak var appState: AppState?
    private weak var airportDataService: AirportDataService?
    private weak var flightEventDetector: FlightEventDetector?
    /// The resolved checklist for the active flight, used to configure the event detector with
    /// the right aircraft's speeds. Captured at `startTracking` so it never reads global state.
    private var activeChecklist: ActiveChecklist?
    private var hasNotifiedTakeoffTime: Bool = false
    private var hasConfiguredDetector: Bool = false

    // GPS accuracy tracking
    private var lastGoodSignalTime: Date?
    private var lastLocationUpdateTime: Date?
    private var lastKnownAccuracy: CLLocationAccuracy = -1  // Last received horizontal accuracy (-1 = unknown)
    private let signalDegradedThreshold: TimeInterval = 10.0  // 10 seconds without update = degraded
    private let signalLostThreshold: TimeInterval = 20.0  // 20 seconds without update = long-degraded
    private let signalTrulyLostThreshold: TimeInterval = 45.0  // 45 seconds = truly lost (red)
    private let horizontalAccuracyThreshold: CLLocationAccuracy = 100.0  // 100 meters
    private var signalCheckTimer: Timer?
    /// PR-21: when we last had a good fix but are stationary and have gone stale, we fire a one-shot
    /// requestLocation() probe and hold at degraded until either a fresh fix lands or this window
    /// elapses (then it's a genuine loss → red). Stamped when the probe is fired.
    private var stationaryProbeFiredAt: Date?
    private static let stationaryProbeWindow: TimeInterval = 8.0
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

    // Dynamic distance filter: ground mode uses no filter for precise low-speed tracking,
    // flight mode uses 50m filter for battery efficiency
    private var isGroundMode: Bool = true
    private var flightModeDistanceFilter: CLLocationDistance = 50
    /// Ground-mode distance filter: a modest value (not `kCLDistanceFilterNone`) so taxi/block-on
    /// detail is still captured while sub-metre GPS jitter no longer fires a callback on every
    /// fix during long sub-40-kt phases, saving battery. (PERF-24)
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
        // Start in ground mode (modest 5 m filter). applyGPSPriority adjusts accuracy per the user's
        // GPSPriority; setGroundMode switches to the flight-mode filter (50/100 m) when airborne.
        locationManager.distanceFilter = groundModeDistanceFilter
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
    
    func startTracking(appState: AppState, interval: TimeInterval = 5.0, airportDataService: AirportDataService? = nil, flightEventDetector: FlightEventDetector? = nil, activeChecklist: ActiveChecklist? = nil) {
        self.appState = appState
        self.airportDataService = airportDataService
        self.flightEventDetector = flightEventDetector
        self.activeChecklist = activeChecklist
        self.recordingInterval = interval
        self.lastRecordedTime = nil
        self.lastDetectionTime = nil
        self.lastGoodSignalTime = Date()
        self.lastLocationUpdateTime = Date()
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
        appState = nil
        airportDataService = nil
        flightEventDetector?.reset()
        flightEventDetector = nil
        hasNotifiedTakeoffTime = false
        hasConfiguredDetector = false
        lastDetectionTime = nil
        // Reset to ground mode for next flight
        isGroundMode = true
        locationManager.distanceFilter = groundModeDistanceFilter
        // Reset smoothed/cached values for next flight
        smoothedSpeedMPS = 0
        lastValidSpeedMPS = 0
        lastValidSpeedTime = nil
        lastValidCourse = nil
        lastValidCourseTime = nil
        displaySmoothedSpeedMPS = 0
        lastDisplayedSpeedKnots = 0
    }

    /// Switch between ground mode (modest 5 m distance filter, precise low-speed tracking)
    /// and flight mode (50/100 m distance filter, battery-efficient for cruise).
    /// Ground mode should be active during taxi and after landing.
    /// Flight mode should be active during airborne phases.
    func setGroundMode(_ onGround: Bool) {
        guard onGround != isGroundMode else { return }
        isGroundMode = onGround
        locationManager.distanceFilter = onGround ? groundModeDistanceFilter : flightModeDistanceFilter
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
        lastLocationUpdateTime = Date()
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
        lastLocationUpdateTime = Date()
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
    }

    private func stopSignalCheckTimer() {
        signalCheckTimer?.invalidate()
        signalCheckTimer = nil
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
        accuracyThreshold: CLLocationAccuracy = 100
    ) -> GPSSignalStatus {
        let lastAccuracyWasGood = lastKnownAccuracy >= 0 && lastKnownAccuracy <= accuracyThreshold
        if timeSinceLastUpdate >= trulyLostThreshold {
            return .lost                                    // ≥45 s: truly lost (red), regardless of accuracy
        } else if timeSinceLastUpdate >= lostThreshold {
            return current == .good ? .degraded : current   // ≥20 s: degrade a good signal
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

        // If GPS status is overridden (marketing mode), don't check real signal
        if let override = gpsStatusOverride {
            gpsSignalStatus = override
            return
        }

        guard let lastUpdate = lastLocationUpdateTime else {
            // Never received a location update — GPS truly lost
            gpsSignalStatus = .lost
            return
        }

        let now = Date()
        let timeSinceLastUpdate = now.timeIntervalSince(lastUpdate)
        let computed = Self.signalStatus(
            timeSinceLastUpdate: timeSinceLastUpdate,
            lastKnownAccuracy: lastKnownAccuracy,
            current: gpsSignalStatus,
            degradedThreshold: signalDegradedThreshold,
            lostThreshold: signalLostThreshold,
            trulyLostThreshold: signalTrulyLostThreshold,
            accuracyThreshold: horizontalAccuracyThreshold)

        // PR-21: a parked aircraft (ground mode, 5 m distance filter) receives no callbacks, so
        // staleness alone would drive the indicator orange→red even with good GPS — training the
        // pilot to ignore the one indicator that matters. When we last had a good fix and are
        // plausibly stationary, fire a one-shot requestLocation() probe (which bypasses the distance
        // filter) and hold at degraded; only go red if no fresh fix arrives within the probe window.
        // A fresh fix updates lastLocationUpdateTime, so `computed` recovers on the next tick.
        let lastAccuracyWasGood = lastKnownAccuracy >= 0 && lastKnownAccuracy <= horizontalAccuracyThreshold
        let stationary = smoothedSpeedMPS < 0.5  // < ~1 kt
        if computed == .lost && lastAccuracyWasGood && stationary && gpsSignalStatus != .lost {
            if let firedAt = stationaryProbeFiredAt {
                if now.timeIntervalSince(firedAt) < Self.stationaryProbeWindow {
                    gpsSignalStatus = .degraded             // probe in flight — hold short of red
                    return
                }
                stationaryProbeFiredAt = nil                // window elapsed, no fresh fix → genuine loss
                gpsSignalStatus = .lost
                return
            }
            stationaryProbeFiredAt = now
            locationManager.requestLocation()
            gpsSignalStatus = .degraded
            return
        }

        stationaryProbeFiredAt = nil
        gpsSignalStatus = computed
    }

    /// Update smoothed speed (EMA) and cached heading from a new location update.
    /// Invalid values (speed/course = -1) are skipped, preserving the last valid reading.
    private func updateSmoothedValues(from location: CLLocation) {
        let now = Date()

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

            // Update display integer with 1-knot hysteresis to prevent flickering
            let currentDisplayKnots = Int(displaySmoothedSpeedMPS * 1.94384)
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

    private func updateSignalQuality(from location: CLLocation) {
        // If GPS status is overridden (marketing mode), don't update from real signal
        if gpsStatusOverride != nil {
            return
        }

        let now = Date()
        let accuracy = location.horizontalAccuracy

        // Always update the last location update time and accuracy when we receive any location
        lastLocationUpdateTime = now
        lastKnownAccuracy = accuracy

        // Negative accuracy means invalid - mark as degraded
        if accuracy < 0 {
            if gpsSignalStatus == .good {
                gpsSignalStatus = .degraded
            }
            return
        }

        // Good accuracy - signal is good
        if accuracy <= horizontalAccuracyThreshold {
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
           Date().timeIntervalSince(lastTime) < cachedValueStalenessLimit {
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
           Date().timeIntervalSince(lastTime) < cachedValueStalenessLimit {
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
        let now = Date()
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

        currentLocation = location

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

    // MARK: - Companion Shared GPS (v4.1)

    /// True when this device produced a usable OWN GPS fix within the last few seconds. Independent of
    /// `currentLocation`, which may hold a *borrowed* companion fix. Drives the `ownGPSAvailable` flag
    /// the master broadcasts (so borrowing never flips it back) and gates borrowing. (shared-GPS)
    var ownFixIsLive: Bool {
        guard let t = lastOwnFixTime else { return false }
        return Date().timeIntervalSince(t) <= ownFixStaleAfter
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

    /// The single GPS-processing pipeline, shared by real device fixes (`isOwnFix == true`) and
    /// borrowed companion fixes (`isOwnFix == false`). Updates the displayed location, smoothed
    /// instruments, signal quality, the recorded track and event detection, so a borrowed fix is
    /// indistinguishable downstream from a real one. (shared-GPS, v4.1)
    func processLocation(_ location: CLLocation, isOwnFix: Bool) {
        // When marketing mode is active, ignore real GPS updates
        // (marketing location is injected directly via currentLocation property)
        guard !marketingModeActive else { return }

        let now = Date()

        // Track own-fix liveness from real device fixes only, so companion borrowing can't flip it.
        if isOwnFix && location.horizontalAccuracy >= 0 {
            lastOwnFixTime = now
        }

        // Update current location
        currentLocation = location

        // Update smoothed speed and cached heading
        updateSmoothedValues(from: location)

        // Update smoothed vertical speed from the GPS altitude trend
        updateVerticalSpeed(altitudeFt: location.altitude * 3.28084)

        // Update signal quality based on accuracy
        updateSignalQuality(from: location)

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
        let fixAge = isOwnFix ? abs(location.timestamp.timeIntervalSinceNow) : 0
        let fixIsUsable = fixAge <= 10 && location.horizontalAccuracy >= 0
        if shouldRecord, fixIsUsable, let appState = appState {
            let point = GPSPoint(from: location)
            appState.addGPSPoint(point, airportDataService: airportDataService)
            lastRecordedTime = now
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

            // Get nearby airports for event detection
            let nearbyAirports = airportService.findNearestAirports(
                to: location.coordinate,
                limit: 3,
                maxDistanceNm: 5.0
            )
            detector.processLocation(location, nearbyAirports: nearbyAirports)
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationManager: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            self.processLocation(location, isOwnFix: true)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.locationError = error.localizedDescription
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.authorizationStatus = manager.authorizationStatus

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
                if self.wasStoppedByRevocation && (self.isTracking || self.isLocationUpdatesActive || self.isSharedGPSProviderActive) {
                    self.wasStoppedByRevocation = false
                    self.locationManager.startUpdatingLocation()
                    self.lastLocationUpdateTime = Date()
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
                if self.isTracking || self.isLocationUpdatesActive || self.isSharedGPSProviderActive {
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
