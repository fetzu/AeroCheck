import Foundation
import CoreLocation
import Combine

/// Manages GPS location tracking during flights
class LocationManager: NSObject, ObservableObject {
    // MARK: - Published Properties
    
    @Published var currentLocation: CLLocation?
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var isTracking: Bool = false
    @Published var locationError: String?
    
    // MARK: - Private Properties
    
    private let locationManager = CLLocationManager()
    private var recordingInterval: TimeInterval = 5.0
    private var lastRecordedTime: Date?
    private weak var appState: AppState?
    
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
        
        guard authorizationStatus == .authorizedWhenInUse || 
              authorizationStatus == .authorizedAlways else {
            requestAuthorization()
            return
        }
        
        isTracking = true
        locationManager.startUpdatingLocation()
    }
    
    func stopTracking() {
        isTracking = false
        locationManager.stopUpdatingLocation()
        appState = nil
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
}

// MARK: - CLLocationManagerDelegate

extension LocationManager: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        
        // Update current location
        currentLocation = location
        
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
