import Foundation
import CoreLocation
import Combine

/// GPS signal quality status
enum GPSSignalStatus {
    case good       // Green: GPS functioning, accurate position available
    case degraded   // Orange: GPS working but accuracy poor or updates infrequent
    case lost       // Red: GPS truly lost — no position data available

    var color: String {
        switch self {
        case .good: return "aviationGreen"
        case .degraded: return "orange"
        case .lost: return "aviationRed"
        }
    }
}

/// Manages GPS location tracking during flights
@MainActor
class LocationManager: NSObject, ObservableObject {
    // MARK: - Published Properties

    @Published var currentLocation: CLLocation?
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var isTracking: Bool = false
    @Published var isLocationUpdatesActive: Bool = false // True when GPS is active (even without flight tracking)
    @Published var locationError: String?
    @Published var gpsSignalStatus: GPSSignalStatus = .good

    // MARK: - Private Properties

    private let locationManager = CLLocationManager()
    private var recordingInterval: TimeInterval = 5.0
    private var lastRecordedTime: Date?
    private weak var appState: AppState?
    private weak var airportDataService: AirportDataService?
    private weak var flightEventDetector: FlightEventDetector?

    // GPS accuracy tracking
    private var lastGoodSignalTime: Date?
    private var lastLocationUpdateTime: Date?
    private var lastKnownAccuracy: CLLocationAccuracy = -1  // Last received horizontal accuracy (-1 = unknown)
    private let signalDegradedThreshold: TimeInterval = 15.0  // 15 seconds without update = degraded
    private let signalLostThreshold: TimeInterval = 45.0  // 45 seconds without update = degraded (even with good last accuracy)
    private let signalTrulyLostThreshold: TimeInterval = 90.0  // 90 seconds = truly lost (red)
    private let horizontalAccuracyThreshold: CLLocationAccuracy = 100.0  // 100 meters
    private var signalCheckTimer: Timer?

    // GPS status override (for marketing mode)
    private var gpsStatusOverride: GPSSignalStatus?

    // Marketing mode flag - when true, ignores real GPS updates
    private var marketingModeActive: Bool = false

    // Dynamic distance filter: ground mode uses no filter for precise low-speed tracking,
    // flight mode uses 50m filter for battery efficiency
    private var isGroundMode: Bool = true
    private let flightModeDistanceFilter: CLLocationDistance = 50

    // Speed and heading caching/smoothing
    // Prevents false stall warnings from GPS -1 (invalid) speed values by holding the last
    // valid smoothed speed. Uses EMA (exponential moving average) to smooth GPS noise (~1-2 kt).
    private var lastValidSpeedMPS: Double = 0
    private var lastValidSpeedTime: Date?
    private var smoothedSpeedMPS: Double = 0
    private var lastValidCourse: Double?
    private var lastValidCourseTime: Date?
    private let speedSmoothingAlpha: Double = 0.3       // EMA factor: responsive to real changes, smooths noise
    private let cachedValueStalenessLimit: TimeInterval = 15.0  // Matches signalDegradedThreshold

    // MARK: - Initialization
    
    override init() {
        super.init()
        setupLocationManager()
    }
    
    private func setupLocationManager() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        locationManager.distanceFilter = kCLDistanceFilterNone // Start in ground mode; switches to 50m in flight mode
        locationManager.activityType = .airborne

        // Background location configuration:
        // - allowsBackgroundLocationUpdates: Required for continuous GPS tracking during flight
        // - pausesLocationUpdatesAutomatically: Disabled to prevent iOS from pausing updates
        // - showsBackgroundLocationIndicator: Shows blue bar when tracking in background
        // Note: If the app is terminated by the system during background tracking,
        // iOS will not automatically restart it. The user must manually restart the app.
        // This is acceptable for aviation use where the app should remain in foreground.
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.showsBackgroundLocationIndicator = true

        // Check current authorization
        authorizationStatus = locationManager.authorizationStatus
    }
    
    // MARK: - Public Methods
    
    func requestAuthorization() {
        locationManager.requestWhenInUseAuthorization()
    }
    
    func startTracking(appState: AppState, interval: TimeInterval = 5.0, airportDataService: AirportDataService? = nil, flightEventDetector: FlightEventDetector? = nil) {
        self.appState = appState
        self.airportDataService = airportDataService
        self.flightEventDetector = flightEventDetector
        self.recordingInterval = interval
        self.lastRecordedTime = nil
        self.lastGoodSignalTime = Date()
        self.lastLocationUpdateTime = Date()
        self.gpsSignalStatus = .good

        guard authorizationStatus == .authorizedWhenInUse ||
              authorizationStatus == .authorizedAlways else {
            requestAuthorization()
            return
        }

        isTracking = true
        locationManager.startUpdatingLocation()
        startSignalCheckTimer()
    }

    func stopTracking() {
        isTracking = false
        locationManager.stopUpdatingLocation()
        stopSignalCheckTimer()
        appState = nil
        airportDataService = nil
        flightEventDetector?.reset()
        flightEventDetector = nil
        // Reset to ground mode for next flight
        isGroundMode = true
        locationManager.distanceFilter = kCLDistanceFilterNone
        // Reset smoothed/cached values for next flight
        smoothedSpeedMPS = 0
        lastValidSpeedMPS = 0
        lastValidSpeedTime = nil
        lastValidCourse = nil
        lastValidCourseTime = nil
    }

    /// Switch between ground mode (no distance filter, precise low-speed tracking)
    /// and flight mode (50m distance filter, battery-efficient for cruise).
    /// Ground mode should be active during taxi and after landing.
    /// Flight mode should be active during airborne phases.
    func setGroundMode(_ onGround: Bool) {
        guard onGround != isGroundMode else { return }
        isGroundMode = onGround
        locationManager.distanceFilter = onGround ? kCLDistanceFilterNone : flightModeDistanceFilter
        print("[LocationManager] Distance filter: \(onGround ? "ground mode (none)" : "flight mode (\(Int(flightModeDistanceFilter))m)")")
    }

    /// Start location updates without recording (for navigation view)
    /// This enables GPS for real-time position display without storing track points
    func startLocationUpdates() {
        guard authorizationStatus == .authorizedWhenInUse ||
              authorizationStatus == .authorizedAlways else {
            requestAuthorization()
            return
        }

        locationManager.startUpdatingLocation()
        lastLocationUpdateTime = Date()
        gpsSignalStatus = .good
        isLocationUpdatesActive = true
        startSignalCheckTimer()
    }

    /// Stop location updates when navigation view is closed
    /// Only stops if not currently tracking a flight
    func stopLocationUpdates() {
        if !isTracking {
            locationManager.stopUpdatingLocation()
            stopSignalCheckTimer()
            isLocationUpdatesActive = false
        }
    }

    // MARK: - Signal Quality Monitoring

    private func startSignalCheckTimer() {
        // Invalidate existing timer to prevent duplicates (e.g. if startTracking and
        // startLocationUpdates are both called)
        signalCheckTimer?.invalidate()
        signalCheckTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkSignalStatus()
            }
        }
    }

    private func stopSignalCheckTimer() {
        signalCheckTimer?.invalidate()
        signalCheckTimer = nil
    }

    private func checkSignalStatus() {
        guard isTracking || isLocationUpdatesActive else { return }

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
        let lastAccuracyWasGood = lastKnownAccuracy >= 0 && lastKnownAccuracy <= horizontalAccuracyThreshold

        // Truly lost: no update for 90+ seconds regardless of last accuracy
        if timeSinceLastUpdate >= signalTrulyLostThreshold {
            gpsSignalStatus = .lost
        }
        // Degraded: no update for 45+ seconds (even if last accuracy was good,
        // something is wrong after this long)
        else if timeSinceLastUpdate >= signalLostThreshold {
            if gpsSignalStatus == .good {
                gpsSignalStatus = .degraded
            }
        }
        // If last accuracy was good, stay good — the distance filter (50m) may simply
        // not have triggered yet because the device hasn't moved enough
        else if lastAccuracyWasGood {
            gpsSignalStatus = .good
        }
        // Last accuracy was poor and no fresh update for 15+ seconds
        else if timeSinceLastUpdate >= signalDegradedThreshold {
            if gpsSignalStatus == .good {
                gpsSignalStatus = .degraded
            }
        }
    }

    /// Update smoothed speed (EMA) and cached heading from a new location update.
    /// Invalid values (speed/course = -1) are skipped, preserving the last valid reading.
    private func updateSmoothedValues(from location: CLLocation) {
        let now = Date()

        // Speed: apply exponential moving average, skip invalid (-1) readings
        if location.speed >= 0 {
            if lastValidSpeedTime != nil {
                // EMA: new_value = α * raw + (1-α) * previous
                smoothedSpeedMPS = speedSmoothingAlpha * location.speed + (1.0 - speedSmoothingAlpha) * smoothedSpeedMPS
            } else {
                // First valid reading — initialize without smoothing
                smoothedSpeedMPS = location.speed
            }
            lastValidSpeedMPS = location.speed
            lastValidSpeedTime = now
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
}

// MARK: - CLLocationManagerDelegate

extension LocationManager: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }

        Task { @MainActor in
            // When marketing mode is active, ignore real GPS updates
            // (marketing location is injected directly via currentLocation property)
            guard !self.marketingModeActive else { return }

            // Update current location
            self.currentLocation = location

            // Update smoothed speed and cached heading
            self.updateSmoothedValues(from: location)

            // Update signal quality based on accuracy
            self.updateSignalQuality(from: location)

            // Check if we should record this point
            let now = Date()
            let shouldRecord: Bool

            if let lastTime = self.lastRecordedTime {
                shouldRecord = now.timeIntervalSince(lastTime) >= self.recordingInterval
            } else {
                shouldRecord = true
            }

            // Auto-switch ground/flight mode based on speed for battery optimization
            // Ground mode: no distance filter (precise low-speed tracking for block on detection)
            // Flight mode: 50m filter (battery-efficient during airborne phases)
            if self.isTracking && location.speed >= 0 {
                let speedKts = location.speed * 1.94384
                if self.isGroundMode && speedKts > 40 {
                    self.setGroundMode(false)
                } else if !self.isGroundMode && speedKts < 20 {
                    self.setGroundMode(true)
                }
            }

            if shouldRecord, let appState = self.appState {
                let point = GPSPoint(from: location)
                appState.addGPSPoint(point, airportDataService: self.airportDataService)
                self.lastRecordedTime = now

                // Process location for flight event detection (go-arounds, touch-and-gos)
                if let detector = self.flightEventDetector,
                   let airportService = self.airportDataService,
                   appState.engineStartTime != nil {
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
            case .denied:
                self.locationError = "Location access denied. Please enable in Settings."
            case .restricted:
                self.locationError = "Location access restricted."
            case .notDetermined:
                self.locationError = nil
            @unknown default:
                self.locationError = "Unknown authorization status."
            }
        }
    }
}
