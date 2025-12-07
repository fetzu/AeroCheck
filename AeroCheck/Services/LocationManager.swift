import Foundation
import CoreLocation
import Combine

/// GPS signal quality status
enum GPSSignalStatus {
    case good       // Green: accurate signal
    case degraded   // Orange: inaccurate or stale signal (>2.5s since last update)
    case lost       // Red: no signal for 10+ seconds

    var color: String {
        switch self {
        case .good: return "aviationGreen"
        case .degraded: return "orange"
        case .lost: return "aviationRed"
        }
    }
}

/// Manages GPS location tracking during flights
class LocationManager: NSObject, ObservableObject {
    // MARK: - Published Properties

    @Published var currentLocation: CLLocation?
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var isTracking: Bool = false
    @Published var locationError: String?
    @Published var gpsSignalStatus: GPSSignalStatus = .good

    // MARK: - Private Properties

    private let locationManager = CLLocationManager()
    private var recordingInterval: TimeInterval = 5.0
    private var lastRecordedTime: Date?
    private weak var appState: AppState?

    // GPS accuracy tracking
    private var lastGoodSignalTime: Date?
    private var lastLocationUpdateTime: Date?
    private let signalDegradedThreshold: TimeInterval = 2.5  // 2.5 seconds without update = degraded
    private let signalLostThreshold: TimeInterval = 10.0  // 10 seconds without update = lost
    private let horizontalAccuracyThreshold: CLLocationAccuracy = 50.0  // 50 meters
    private var signalCheckTimer: Timer?
    
    // MARK: - Initialization
    
    override init() {
        super.init()
        setupLocationManager()
    }
    
    private func setupLocationManager() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 10 // meters
        locationManager.activityType = .airborne
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        
        // Check current authorization
        authorizationStatus = locationManager.authorizationStatus
    }
    
    // MARK: - Public Methods
    
    func requestAuthorization() {
        locationManager.requestWhenInUseAuthorization()
    }
    
    func startTracking(appState: AppState, interval: TimeInterval = 5.0) {
        self.appState = appState
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
    }

    // MARK: - Signal Quality Monitoring

    private func startSignalCheckTimer() {
        signalCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkSignalStatus()
        }
    }

    private func stopSignalCheckTimer() {
        signalCheckTimer?.invalidate()
        signalCheckTimer = nil
    }

    private func checkSignalStatus() {
        guard isTracking else { return }

        let now = Date()

        // Check time since last location update
        if let lastUpdate = lastLocationUpdateTime {
            let timeSinceLastUpdate = now.timeIntervalSince(lastUpdate)

            // Lost: no update for 10+ seconds
            if timeSinceLastUpdate >= signalLostThreshold {
                if gpsSignalStatus != .lost {
                    gpsSignalStatus = .lost
                }
            }
            // Degraded: no update for 2.5+ seconds (but not yet lost)
            else if timeSinceLastUpdate >= signalDegradedThreshold {
                if gpsSignalStatus == .good {
                    gpsSignalStatus = .degraded
                }
            }
        }
    }

    private func updateSignalQuality(from location: CLLocation) {
        let now = Date()
        let accuracy = location.horizontalAccuracy

        // Always update the last location update time when we receive any location
        lastLocationUpdateTime = now

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
    
    /// Current speed in knots (converted from m/s)
    var currentSpeedKnots: Double {
        guard let speed = currentLocation?.speed, speed >= 0 else { return 0 }
        return speed * 1.94384 // m/s to knots
    }
    
    /// Current speed in m/s (raw GPS value)
    var currentSpeedMPS: Double {
        guard let speed = currentLocation?.speed, speed >= 0 else { return 0 }
        return speed
    }

    /// Current altitude in meters (raw GPS value)
    var currentAltitudeMeters: Double {
        currentLocation?.altitude ?? 0
    }

    /// Current altitude in feet (converted from meters)
    var currentAltitudeFeet: Double {
        currentAltitudeMeters * 3.28084 // meters to feet
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationManager: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }

        // Update current location
        currentLocation = location

        // Update signal quality based on accuracy
        updateSignalQuality(from: location)

        // Check if we should record this point
        let now = Date()
        let shouldRecord: Bool

        if let lastTime = lastRecordedTime {
            shouldRecord = now.timeIntervalSince(lastTime) >= recordingInterval
        } else {
            shouldRecord = true
        }

        if shouldRecord, let appState = appState {
            let point = GPSPoint(from: location)
            Task { @MainActor in
                appState.addGPSPoint(point)
            }
            lastRecordedTime = now
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        locationError = error.localizedDescription
    }
    
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        
        switch authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            locationError = nil
        case .denied:
            locationError = "Location access denied. Please enable in Settings."
        case .restricted:
            locationError = "Location access restricted."
        case .notDetermined:
            locationError = nil
        @unknown default:
            locationError = "Unknown authorization status."
        }
    }
}
