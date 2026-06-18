//
//  MarketingLocationProvider.swift
//  AéroCheck
//
//  Provides simulated GPS location data for taking marketing screenshots.
//  Enable in Settings by tapping the version number 5 times, then toggle Marketing Mode.
//  When enabled, shake your device to show the marketing controls overlay.
//

import Foundation
import CoreLocation
import Combine

/// Predefined marketing scenarios for screenshots
enum MarketingScenario: String, CaseIterable, Identifiable {
    case lszqAlpineTour = "LSZQ Alpine Tour"
    case swissAlpsFlight = "Swiss Alps Flight"
    case lszjCircuit = "LSZJ Circuit Pattern"
    case jurassicCrossing = "Jura Mountains Crossing"
    case genevaToZurich = "Geneva to Zurich"

    var id: String { rawValue }

    /// Starting position for the scenario
    var startPosition: CLLocationCoordinate2D {
        switch self {
        case .lszqAlpineTour:
            return CLLocationCoordinate2D(latitude: 47.3497, longitude: 7.0278) // LSZQ Bressaucourt
        case .swissAlpsFlight:
            return CLLocationCoordinate2D(latitude: 46.4547, longitude: 7.3514) // Interlaken area
        case .lszjCircuit:
            return CLLocationCoordinate2D(latitude: 47.0386, longitude: 7.1275) // LSZJ Courtelary
        case .jurassicCrossing:
            return CLLocationCoordinate2D(latitude: 47.0867, longitude: 6.8178) // La Chaux-de-Fonds
        case .genevaToZurich:
            return CLLocationCoordinate2D(latitude: 46.2381, longitude: 6.1090) // Geneva
        }
    }

    /// GPS track for the scenario
    var track: [MarketingGPSPoint] {
        switch self {
        case .lszqAlpineTour:
            return MarketingScenario.lszqAlpineTourTrack
        case .swissAlpsFlight:
            return MarketingScenario.swissAlpsTrack
        case .lszjCircuit:
            return MarketingScenario.lszjCircuitTrack
        case .jurassicCrossing:
            return MarketingScenario.jurassicTrack
        case .genevaToZurich:
            return MarketingScenario.genevaZurichTrack
        }
    }

    // MARK: - Predefined Tracks

    /// LSZQ Alpine Tour: Bressaucourt → Chasseral → Sion (T&G) → Samedan (T&G) → Bressaucourt
    private static var lszqAlpineTourTrack: [MarketingGPSPoint] {
        [
            MarketingGPSPoint(lat: 47.3497, lon: 7.0278, alt: 567, speed: 0, course: 250),      // LSZQ start
            MarketingGPSPoint(lat: 47.3350, lon: 6.9900, alt: 900, speed: 95, course: 240),
            MarketingGPSPoint(lat: 47.2700, lon: 6.9000, alt: 1500, speed: 115, course: 220),
            MarketingGPSPoint(lat: 47.1322, lon: 7.0625, alt: 2300, speed: 108, course: 155),   // Over Chasseral
            MarketingGPSPoint(lat: 47.0000, lon: 7.2500, alt: 2800, speed: 118, course: 175),
            MarketingGPSPoint(lat: 46.7500, lon: 7.4000, alt: 3200, speed: 122, course: 190),
            MarketingGPSPoint(lat: 46.3500, lon: 7.4200, alt: 2200, speed: 110, course: 210),
            MarketingGPSPoint(lat: 46.2186, lon: 7.3267, alt: 482, speed: 55, course: 250),     // Sion T&G
            MarketingGPSPoint(lat: 46.2800, lon: 7.1500, alt: 2400, speed: 115, course: 330),
            MarketingGPSPoint(lat: 46.4500, lon: 7.5000, alt: 3500, speed: 120, course: 65),
            MarketingGPSPoint(lat: 46.5200, lon: 8.2000, alt: 4000, speed: 120, course: 75),
            MarketingGPSPoint(lat: 46.5300, lon: 9.4000, alt: 3500, speed: 110, course: 85),
            MarketingGPSPoint(lat: 46.5342, lon: 9.8842, alt: 1707, speed: 55, course: 55),     // Samedan T&G
            MarketingGPSPoint(lat: 46.6500, lon: 9.9000, alt: 3500, speed: 115, course: 340),
            MarketingGPSPoint(lat: 46.9200, lon: 9.0000, alt: 4000, speed: 120, course: 285),
            MarketingGPSPoint(lat: 47.0800, lon: 7.5000, alt: 3000, speed: 112, course: 270),
            MarketingGPSPoint(lat: 47.2200, lon: 7.0800, alt: 2000, speed: 105, course: 310),
            MarketingGPSPoint(lat: 47.3200, lon: 7.0100, alt: 1000, speed: 90, course: 350),
            MarketingGPSPoint(lat: 47.3497, lon: 7.0278, alt: 567, speed: 0, course: 70),       // LSZQ landing
        ]
    }

    /// Flight around Swiss Alps (Interlaken - Grindelwald - Lauterbrunnen)
    private static var swissAlpsTrack: [MarketingGPSPoint] {
        [
            MarketingGPSPoint(lat: 46.4547, lon: 7.3514, alt: 580, speed: 0, course: 90),     // Interlaken start
            MarketingGPSPoint(lat: 46.4650, lon: 7.3800, alt: 1200, speed: 65, course: 75),
            MarketingGPSPoint(lat: 46.4800, lon: 7.4200, alt: 1800, speed: 70, course: 65),
            MarketingGPSPoint(lat: 46.5000, lon: 7.4800, alt: 2400, speed: 72, course: 55),
            MarketingGPSPoint(lat: 46.5200, lon: 7.5500, alt: 2800, speed: 70, course: 50),   // Near Grindelwald
            MarketingGPSPoint(lat: 46.5400, lon: 7.5800, alt: 3000, speed: 68, course: 30),
            MarketingGPSPoint(lat: 46.5600, lon: 7.5600, alt: 3200, speed: 65, course: 330),  // Turning point
            MarketingGPSPoint(lat: 46.5700, lon: 7.5200, alt: 3100, speed: 68, course: 290),
            MarketingGPSPoint(lat: 46.5650, lon: 7.4700, alt: 2900, speed: 70, course: 260),
            MarketingGPSPoint(lat: 46.5550, lon: 7.4200, alt: 2700, speed: 72, course: 245),  // Lauterbrunnen valley
            MarketingGPSPoint(lat: 46.5400, lon: 7.3800, alt: 2400, speed: 70, course: 230),
            MarketingGPSPoint(lat: 46.5200, lon: 7.3500, alt: 2000, speed: 68, course: 220),
            MarketingGPSPoint(lat: 46.4950, lon: 7.3300, alt: 1600, speed: 65, course: 210),
            MarketingGPSPoint(lat: 46.4700, lon: 7.3200, alt: 1200, speed: 62, course: 200),
            MarketingGPSPoint(lat: 46.4547, lon: 7.3514, alt: 580, speed: 0, course: 180),    // Return to Interlaken
        ]
    }

    /// Circuit pattern at LSZJ Courtelary
    private static var lszjCircuitTrack: [MarketingGPSPoint] {
        [
            MarketingGPSPoint(lat: 47.0386, lon: 7.1275, alt: 695, speed: 0, course: 230),    // LSZJ threshold
            MarketingGPSPoint(lat: 47.0360, lon: 7.1200, alt: 720, speed: 55, course: 230),   // Takeoff roll
            MarketingGPSPoint(lat: 47.0320, lon: 7.1100, alt: 850, speed: 65, course: 230),   // Initial climb
            MarketingGPSPoint(lat: 47.0280, lon: 7.1000, alt: 1000, speed: 70, course: 230),  // Crosswind turn
            MarketingGPSPoint(lat: 47.0250, lon: 7.0920, alt: 1100, speed: 72, course: 320),  // Downwind leg
            MarketingGPSPoint(lat: 47.0300, lon: 7.0850, alt: 1150, speed: 72, course: 320),
            MarketingGPSPoint(lat: 47.0380, lon: 7.0800, alt: 1150, speed: 72, course: 320),
            MarketingGPSPoint(lat: 47.0450, lon: 7.0850, alt: 1150, speed: 72, course: 50),   // Abeam threshold
            MarketingGPSPoint(lat: 47.0500, lon: 7.0950, alt: 1100, speed: 70, course: 50),
            MarketingGPSPoint(lat: 47.0530, lon: 7.1100, alt: 1000, speed: 68, course: 50),   // Base turn
            MarketingGPSPoint(lat: 47.0510, lon: 7.1250, alt: 900, speed: 65, course: 140),   // Base leg
            MarketingGPSPoint(lat: 47.0470, lon: 7.1350, alt: 800, speed: 62, course: 140),
            MarketingGPSPoint(lat: 47.0430, lon: 7.1380, alt: 750, speed: 60, course: 230),   // Final turn
            MarketingGPSPoint(lat: 47.0400, lon: 7.1320, alt: 720, speed: 55, course: 230),   // Final approach
            MarketingGPSPoint(lat: 47.0386, lon: 7.1275, alt: 695, speed: 0, course: 230),    // Landing
        ]
    }

    /// Jura Mountains crossing (La Chaux-de-Fonds to Delémont)
    private static var jurassicTrack: [MarketingGPSPoint] {
        [
            MarketingGPSPoint(lat: 47.0867, lon: 6.8178, alt: 1000, speed: 0, course: 45),    // La Chaux-de-Fonds
            MarketingGPSPoint(lat: 47.1000, lon: 6.8500, alt: 1400, speed: 68, course: 50),
            MarketingGPSPoint(lat: 47.1200, lon: 6.8900, alt: 1700, speed: 70, course: 55),
            MarketingGPSPoint(lat: 47.1450, lon: 6.9400, alt: 1900, speed: 72, course: 55),   // Over Chasseral
            MarketingGPSPoint(lat: 47.1700, lon: 6.9900, alt: 2000, speed: 72, course: 60),
            MarketingGPSPoint(lat: 47.2000, lon: 7.0500, alt: 1800, speed: 70, course: 65),
            MarketingGPSPoint(lat: 47.2300, lon: 7.1200, alt: 1500, speed: 68, course: 60),
            MarketingGPSPoint(lat: 47.2600, lon: 7.2000, alt: 1200, speed: 65, course: 55),
            MarketingGPSPoint(lat: 47.2900, lon: 7.2800, alt: 900, speed: 62, course: 50),
            MarketingGPSPoint(lat: 47.3167, lon: 7.3464, alt: 600, speed: 55, course: 45),
            MarketingGPSPoint(lat: 47.3481, lon: 7.3436, alt: 420, speed: 0, course: 45),     // Delémont
        ]
    }

    /// Geneva to Zurich cross-country
    private static var genevaZurichTrack: [MarketingGPSPoint] {
        [
            MarketingGPSPoint(lat: 46.2381, lon: 6.1090, alt: 430, speed: 0, course: 45),     // Geneva
            MarketingGPSPoint(lat: 46.3000, lon: 6.2000, alt: 1200, speed: 75, course: 50),
            MarketingGPSPoint(lat: 46.4000, lon: 6.4000, alt: 2000, speed: 80, course: 55),
            MarketingGPSPoint(lat: 46.5000, lon: 6.6000, alt: 2500, speed: 82, course: 55),   // Over Lausanne
            MarketingGPSPoint(lat: 46.6000, lon: 6.9000, alt: 2800, speed: 85, course: 50),
            MarketingGPSPoint(lat: 46.7500, lon: 7.2000, alt: 3000, speed: 85, course: 45),   // Bern area
            MarketingGPSPoint(lat: 46.9000, lon: 7.5000, alt: 3200, speed: 85, course: 45),
            MarketingGPSPoint(lat: 47.0500, lon: 7.8000, alt: 3000, speed: 82, course: 50),   // Solothurn
            MarketingGPSPoint(lat: 47.2000, lon: 8.2000, alt: 2500, speed: 80, course: 55),
            MarketingGPSPoint(lat: 47.3000, lon: 8.4000, alt: 2000, speed: 78, course: 60),
            MarketingGPSPoint(lat: 47.3800, lon: 8.5000, alt: 1500, speed: 75, course: 65),   // Approaching Zurich
            MarketingGPSPoint(lat: 47.4200, lon: 8.5400, alt: 1000, speed: 70, course: 70),
            MarketingGPSPoint(lat: 47.4500, lon: 8.5600, alt: 700, speed: 65, course: 75),
            MarketingGPSPoint(lat: 47.4647, lon: 8.5492, alt: 432, speed: 0, course: 80),     // Zurich airport
        ]
    }
}

/// A GPS point for marketing scenarios
struct MarketingGPSPoint {
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let speed: Double       // in knots
    let course: Double      // in degrees (hint only, actual heading calculated from travel direction)

    init(lat: Double, lon: Double, alt: Double, speed: Double, course: Double) {
        self.latitude = lat
        self.longitude = lon
        self.altitude = alt
        self.speed = speed
        self.course = course
    }

    /// Convert speed from knots to m/s for CLLocation
    var speedMPS: Double {
        speed * 0.514444
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Calculate bearing from this point to another point
    func bearing(to other: MarketingGPSPoint) -> Double {
        let lat1 = latitude * .pi / 180
        let lat2 = other.latitude * .pi / 180
        let dLon = (other.longitude - longitude) * .pi / 180

        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        var bearing = atan2(y, x) * 180 / .pi

        // Normalize to 0-360
        if bearing < 0 {
            bearing += 360
        }
        return bearing
    }

    /// Calculate distance to another point in meters
    func distance(to other: MarketingGPSPoint) -> Double {
        let R = 6371000.0 // Earth radius in meters
        let lat1 = latitude * .pi / 180
        let lat2 = other.latitude * .pi / 180
        let dLat = (other.latitude - latitude) * .pi / 180
        let dLon = (other.longitude - longitude) * .pi / 180

        let a = sin(dLat / 2) * sin(dLat / 2) +
                cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))

        return R * c
    }

    func toCLLocation(timestamp: Date = Date(), heading: Double? = nil) -> CLLocation {
        CLLocation(
            coordinate: coordinate,
            altitude: altitude,
            horizontalAccuracy: 5.0,
            verticalAccuracy: 10.0,
            course: heading ?? course,
            speed: speedMPS,
            timestamp: timestamp
        )
    }
}

/// Marketing Location Provider - Simulates GPS for screenshots
/// This class can inject fake location data for marketing purposes
@MainActor
class MarketingLocationProvider: ObservableObject {
    static let shared = MarketingLocationProvider()

    // MARK: - Published Properties

    @Published var isActive: Bool = false
    @Published var currentScenario: MarketingScenario = .lszqAlpineTour {
        didSet {
            if isActive {
                // Reset when scenario changes
                stop()
                start()
            }
        }
    }
    @Published var currentIndex: Int = 0
    @Published var playbackSpeed: Double = 1.0  // 1.0 = 1x speed, max 5.0
    @Published var isPaused: Bool = false

    /// Current simulated location
    @Published var currentLocation: CLLocation?

    /// Current heading (calculated from travel direction)
    @Published var currentHeading: Double = 0

    /// Previous path (for showing track on map)
    @Published var previousPath: [CLLocationCoordinate2D] = []

    /// Custom position override (for static screenshots)
    @Published var customPosition: CLLocationCoordinate2D?
    @Published var customAltitude: Double = 1500
    @Published var customSpeed: Double = 70  // knots
    @Published var customHeading: Double = 45
    @Published var useCustomPosition: Bool = false

    // MARK: - Private Properties

    private var simulationTimer: Timer?
    private var startTime: Date?
    private var segmentStartTime: Date?
    private var interpolationProgress: Double = 0  // 0.0 to 1.0 within current segment

    // MARK: - Initialization

    private init() {}

    // MARK: - Public Methods

    /// Start the simulation with the current scenario
    func start() {
        isActive = true
        currentIndex = 0
        interpolationProgress = 0
        previousPath = []
        startTime = Date()
        segmentStartTime = Date()

        // Calculate initial heading
        let track = currentScenario.track
        if track.count > 1 {
            currentHeading = track[0].bearing(to: track[1])
        }

        updateLocation()
        startTimer()
    }

    /// Stop the simulation
    func stop() {
        isActive = false
        simulationTimer?.invalidate()
        simulationTimer = nil
        currentLocation = nil
        previousPath = []
        interpolationProgress = 0
    }

    /// Pause/resume the simulation
    func togglePause() {
        isPaused.toggle()
        if !isPaused {
            // Reset segment start time when resuming
            segmentStartTime = Date()
        }
    }

    /// Move to next waypoint
    func nextWaypoint() {
        let track = currentScenario.track
        if currentIndex < track.count - 1 {
            // Add current waypoint to path
            previousPath.append(track[currentIndex].coordinate)
            currentIndex += 1
            interpolationProgress = 0
            segmentStartTime = Date()

            // Update heading for new segment
            if currentIndex < track.count - 1 {
                currentHeading = track[currentIndex].bearing(to: track[currentIndex + 1])
            }

            updateLocation()
        }
    }

    /// Move to previous waypoint
    func previousWaypoint() {
        if currentIndex > 0 {
            currentIndex -= 1
            interpolationProgress = 0
            segmentStartTime = Date()

            // Remove last point from path
            if !previousPath.isEmpty {
                previousPath.removeLast()
            }

            // Update heading
            let track = currentScenario.track
            if currentIndex < track.count - 1 {
                currentHeading = track[currentIndex].bearing(to: track[currentIndex + 1])
            }

            updateLocation()
        }
    }

    /// Jump to specific waypoint
    func jumpToWaypoint(_ index: Int) {
        let track = currentScenario.track
        guard index >= 0 && index < track.count else { return }

        // Rebuild path up to this point
        previousPath = []
        for i in 0..<index {
            previousPath.append(track[i].coordinate)
        }

        currentIndex = index
        interpolationProgress = 0
        segmentStartTime = Date()

        // Update heading
        if currentIndex < track.count - 1 {
            currentHeading = track[currentIndex].bearing(to: track[currentIndex + 1])
        }

        updateLocation()
    }

    /// Set custom position for static screenshots
    func setCustomPosition(
        latitude: Double,
        longitude: Double,
        altitude: Double,
        speed: Double,
        heading: Double
    ) {
        customPosition = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        customAltitude = altitude
        customSpeed = speed
        customHeading = heading
        useCustomPosition = true
        isActive = true  // Mark as active so GPS status shows as good

        updateLocation()
    }

    /// Clear custom position and return to scenario
    func clearCustomPosition() {
        useCustomPosition = false
        updateLocation()
    }

    /// Hold one static GPS fix and keep publishing it, so the in-flight instruments (SPD / ALT / HDG)
    /// stay lit for a screenshot. (DEV-ONLY — Marketing Mode scene injector)
    ///
    /// Reuses `MarketingGPSPoint.toCLLocation` for the m/s + altitude conversion, stops any running
    /// scenario timer (a held fix must not drift), and publishes via `currentLocation` so the existing
    /// `ContentView` injection path forwards it into `LocationManager`. `altitudeMeters` is the GPS
    /// altitude in METERS (CLLocation native); `speedKnots` and `headingDegrees` are aviation units.
    func holdStaticFix(latitude: Double, longitude: Double, altitudeMeters: Double, speedKnots: Double, headingDegrees: Double) {
        // Stop scenario playback so the timer doesn't overwrite the held fix.
        simulationTimer?.invalidate()
        simulationTimer = nil
        isPaused = true
        useCustomPosition = false // a held fix is published directly via currentLocation, not the custom-position path

        isActive = true // mark active so the GPS status shows good and ContentView forwards the fix

        let point = MarketingGPSPoint(
            lat: latitude,
            lon: longitude,
            alt: altitudeMeters,
            speed: speedKnots,
            course: headingDegrees
        )
        currentHeading = headingDegrees
        // Re-assign to a fresh location each call so `.onChange(of: currentLocation)` always fires.
        currentLocation = point.toCLLocation(heading: headingDegrees)
    }

    /// Get current location for injection into LocationManager
    func getCurrentLocation() -> CLLocation? {
        if useCustomPosition, let pos = customPosition {
            return CLLocation(
                coordinate: pos,
                altitude: customAltitude,
                horizontalAccuracy: 5.0,
                verticalAccuracy: 10.0,
                course: customHeading,
                speed: customSpeed * 0.514444,  // Convert knots to m/s
                timestamp: Date()
            )
        }
        return currentLocation
    }

    // MARK: - Private Methods

    private func startTimer() {
        simulationTimer?.invalidate()

        // Update 10 times per second for smooth interpolation
        simulationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.timerFired()
            }
        }
    }

    /// Calculate how long it should take to travel between two waypoints at max 5x speed
    private func segmentDuration(from: MarketingGPSPoint, to: MarketingGPSPoint) -> TimeInterval {
        let distance = from.distance(to: to)  // meters
        let avgSpeed = (from.speedMPS + to.speedMPS) / 2  // m/s

        // If speed is 0, use a minimum speed of 20 knots for calculation
        let effectiveSpeed = max(avgSpeed, 20 * 0.514444)

        // Real time to travel this segment
        let realTime = distance / effectiveSpeed

        // At max 20x playback, divide by playback speed (capped at 20)
        let cappedPlaybackSpeed = min(playbackSpeed, 20.0)
        return realTime / cappedPlaybackSpeed
    }

    private func timerFired() {
        guard isActive && !isPaused && !useCustomPosition else { return }

        let track = currentScenario.track
        guard currentIndex < track.count else { return }

        // Check if we're at the last waypoint
        if currentIndex >= track.count - 1 {
            // Loop back to start
            currentIndex = 0
            interpolationProgress = 0
            previousPath = []
            segmentStartTime = Date()
            if track.count > 1 {
                currentHeading = track[0].bearing(to: track[1])
            }
            updateLocation()
            return
        }

        let currentPoint = track[currentIndex]
        let nextPoint = track[currentIndex + 1]

        // Calculate segment duration and progress
        let duration = segmentDuration(from: currentPoint, to: nextPoint)
        let elapsed = Date().timeIntervalSince(segmentStartTime ?? Date())
        interpolationProgress = min(elapsed / duration, 1.0)

        // If we've completed this segment, move to next waypoint
        if interpolationProgress >= 1.0 {
            previousPath.append(currentPoint.coordinate)
            currentIndex += 1
            interpolationProgress = 0
            segmentStartTime = Date()

            // Update heading for new segment
            if currentIndex < track.count - 1 {
                currentHeading = track[currentIndex].bearing(to: track[currentIndex + 1])
            }
        }

        updateLocation()
    }

    private func updateLocation() {
        if useCustomPosition, let pos = customPosition {
            currentLocation = CLLocation(
                coordinate: pos,
                altitude: customAltitude,
                horizontalAccuracy: 5.0,
                verticalAccuracy: 10.0,
                course: customHeading,
                speed: customSpeed * 0.514444,
                timestamp: Date()
            )
        } else {
            let track = currentScenario.track
            guard currentIndex < track.count else { return }

            let currentPoint = track[currentIndex]

            // If at last waypoint or no interpolation needed, use current point
            if currentIndex >= track.count - 1 || interpolationProgress == 0 {
                currentLocation = currentPoint.toCLLocation(heading: currentHeading)
            } else {
                // Interpolate between current and next waypoint
                let nextPoint = track[currentIndex + 1]
                let t = interpolationProgress

                let lat = currentPoint.latitude + (nextPoint.latitude - currentPoint.latitude) * t
                let lon = currentPoint.longitude + (nextPoint.longitude - currentPoint.longitude) * t
                let alt = currentPoint.altitude + (nextPoint.altitude - currentPoint.altitude) * t
                let speed = currentPoint.speed + (nextPoint.speed - currentPoint.speed) * t

                // Smoothly interpolate heading (handle wraparound at 360)
                var headingDiff = nextPoint.course - currentPoint.course
                if headingDiff > 180 { headingDiff -= 360 }
                if headingDiff < -180 { headingDiff += 360 }

                // Calculate actual bearing for heading (more realistic)
                let bearing = currentPoint.bearing(to: nextPoint)
                currentHeading = bearing

                let interpolatedPoint = MarketingGPSPoint(
                    lat: lat,
                    lon: lon,
                    alt: alt,
                    speed: speed,
                    course: bearing
                )

                currentLocation = interpolatedPoint.toCLLocation(heading: bearing)
            }
        }
    }
}

// MARK: - Marketing Scene Injector (DEV-ONLY)

/// One-tap marketing screenshot scenes. Each case drives the app into a deterministic UI state
/// (owned aircraft, in-flight HUD, nav plan, conflicts, flight log) so website / App Store captures
/// don't have to be reached by hand. DEV-ONLY — only ever invoked while Marketing Mode is on.
enum MarketingScene: String, CaseIterable, Identifiable {
    case home2Aircraft = "Home — 2 Aircraft"
    case cruiseHUD = "Cruise HUD"
    case navPlanActive = "Nav — Active Plan"
    case planConflicts = "Plan — Conflicts"
    case flightLogDetail = "Flight Log"

    var id: String { rawValue }

    var detail: String {
        switch self {
        case .home2Aircraft: return "F-HVXA + HB-PFA owned"
        case .cruiseHUD: return "Active flight, CRUISE, SPD/ALT/HDG lit"
        case .navPlanActive: return "LSZQ→LSGC→LSGN→LSZB active"
        case .planConflicts: return "Example plan into LSZQ selected"
        case .flightLogDetail: return "Imports the bundled marketing flights"
        }
    }
}

/// Fixed airport coordinates used to build marketing routes without depending on airport data being
/// loaded. Resolved via AirportDataService when available, with these as the fallback. (DEV-ONLY)
private struct MarketingAirport {
    let ident: String
    let latitude: Double
    let longitude: Double
    let elevationFt: Double
}

@MainActor
enum MarketingSceneInjector {

    // ICAO airports referenced by the route scenes (Swiss fields).
    private static let knownAirports: [String: MarketingAirport] = [
        "LSZQ": MarketingAirport(ident: "LSZQ", latitude: 47.3497, longitude: 7.0278, elevationFt: 1860),  // Bressaucourt
        "LSGC": MarketingAirport(ident: "LSGC", latitude: 47.0839, longitude: 6.7928, elevationFt: 3409),  // Les Eplatures
        "LSGN": MarketingAirport(ident: "LSGN", latitude: 46.9575, longitude: 6.8647, elevationFt: 1427),  // Neuchâtel
        "LSZB": MarketingAirport(ident: "LSZB", latitude: 46.9141, longitude: 7.4972, elevationFt: 1673),  // Bern-Belp
        "LSZG": MarketingAirport(ident: "LSZG", latitude: 47.1820, longitude: 7.4170, elevationFt: 1411),  // Grenchen
    ]

    /// Resolve an ICAO to a coordinate, preferring loaded airport data, then the hardcoded fallback.
    private static func coordinate(_ ident: String, airportDataService: AirportDataService) -> CLLocationCoordinate2D? {
        if let a = airportDataService.findAirport(byIdent: ident) {
            return a.coordinate
        }
        if let a = knownAirports[ident] {
            return CLLocationCoordinate2D(latitude: a.latitude, longitude: a.longitude)
        }
        return nil
    }

    /// Inject the given marketing scene. All side effects are dev-gated by the caller (Marketing Mode).
    static func inject(
        _ scene: MarketingScene,
        appState: AppState,
        locationManager: LocationManager,
        subscriptionManager: SubscriptionManager,
        aircraftDataService: AircraftDataService,
        flightPlanManager: FlightPlanManager,
        airportDataService: AirportDataService
    ) {
        switch scene {
        case .home2Aircraft:
            injectHome2Aircraft(appState: appState, subscriptionManager: subscriptionManager, aircraftDataService: aircraftDataService)
        case .cruiseHUD:
            injectCruiseHUD(appState: appState, locationManager: locationManager, airportDataService: airportDataService)
        case .navPlanActive:
            injectNavPlanActive(flightPlanManager: flightPlanManager, airportDataService: airportDataService, locationManager: locationManager)
        case .planConflicts:
            injectPlanConflicts(flightPlanManager: flightPlanManager, airportDataService: airportDataService)
        case .flightLogDetail:
            injectFlightLog(appState: appState)
        }
    }

    // MARK: - Scene 1: Home with exactly two owned aircraft

    private static func injectHome2Aircraft(appState: AppState, subscriptionManager: SubscriptionManager, aircraftDataService: AircraftDataService) {
        // End any active flight so Home is visible.
        if appState.isFlightActive { appState.cancelFlight() }

        // Populate the Home "last flight" card: import the bundled marketing flights so the most
        // recent one (the Alpine Tour) surfaces on Home. (Idempotent.)
        importMarketingFlights(into: appState)

        // Force subscribed so premium aircraft surface, then constrain the owned set to exactly
        // the PA-28-181 (HB-PFA). The bundled WT9 (F-HVXA) is always shown by HomeView.
        // DEBUG-only: the premium-access override (forceSubscribed + owned override) is compiled
        // OUT of release builds so a shipped app can never unlock premium without a real subscription.
        #if DEBUG
        subscriptionManager.setMarketingForceSubscribed(true)

        // applyMarketingOwnedOverride is a no-op until availableAircraft is fetched, so Home would
        // otherwise show only the bundled WT9. If the list is empty or lacks pa28-181, fetch first
        // (on the main actor), THEN apply the override so HB-PFA appears as owned without the user
        // tapping "Get latest aircraft data".
        if aircraftDataService.availableAircraft.contains(where: { $0.id == "pa28-181" }) {
            aircraftDataService.applyMarketingOwnedOverride(ownedIds: ["pa28-181"])
        } else {
            Task { @MainActor in
                await aircraftDataService.fetchAvailableAircraft()
                aircraftDataService.applyMarketingOwnedOverride(ownedIds: ["pa28-181"])
            }
        }
        #endif
    }

    // MARK: - Scene 2: Active flight on CRUISE with a held static fix

    private static func injectCruiseHUD(appState: AppState, locationManager: LocationManager, airportDataService: AirportDataService) {
        // Start a fresh flight on the bundled WT9 (always resolvable, no network needed).
        if appState.isFlightActive { appState.cancelFlight() }
        appState.settings.selectedRemoteAircraftId = nil
        appState.settings.selectedAircraft = .wt9Dynamic
        appState.startFlight()

        // Mark every phase up to and including climb as completed (green); current phase = cruise.
        appState.currentPhase = .cruise
        for phase in ChecklistPhase.allCases where phase.rawValue < ChecklistPhase.cruise.rawValue {
            appState.phaseCompletionStatus[phase] = .completed
            // A worked-through phase shows its highlight past the last item.
            let count = appState.activeChecklist.visibleItemCount(for: phase, learningMode: appState.settings.learningMode)
            appState.currentHighlightedItem[phase] = ChecklistHighlighting.lastItemComplete(visibleCount: count)
        }
        appState.highestCompletedPhase = .climb

        // Cruise: highlight the Fuel-Quantity item with the items before it completed (green).
        // The WT9 cruise checklist lists Fuel Quantity as item 4; locate it by challenge text so the
        // index is robust to checklist edits, falling back to index 3 (the 4th visible item).
        let cruiseItems = appState.activeChecklist.visibleItems(for: .cruise, learningMode: appState.settings.learningMode)
        let fuelIndex = cruiseItems.firstIndex { $0.challenge.lowercased().contains("fuel quantity") } ?? min(3, max(0, cruiseItems.count - 1))
        appState.currentHighlightedItem[.cruise] = fuelIndex
        appState.phaseCompletionStatus[.cruise] = nil // in-progress, not yet completed

        // Record engine start + line up so the in-flight clock and timing readouts are populated.
        let now = Date()
        appState.engineStartTime = now.addingTimeInterval(-25 * 60)
        appState.lineUpTime = now.addingTimeInterval(-20 * 60)
        appState.currentFlight?.engineStartTime = appState.engineStartTime
        appState.currentFlight?.lineUpTime = appState.lineUpTime

        // Load the airport DB FIRST, then inject the held fix. The HUD's NEAREST-frequency strip
        // recomputes on the location change and is throttled to a coarse ~1 NM bucket, so it must see
        // the data the first time the static fix lands — otherwise it resolves nil and never recomputes
        // (the fix never moves). Held just SW of LSZQ Bressaucourt; ~SPD 105 kt, ALT 3500 ft, HDG 315°.
        let altMeters = 3500.0 / 3.28084
        let provider = MarketingLocationProvider.shared
        Task {
            await airportDataService.ensureLoaded()
            provider.holdStaticFix(latitude: 47.364761, longitude: 7.090180, altitudeMeters: altMeters, speedKnots: 105, headingDegrees: 315)
            if let loc = provider.currentLocation {
                locationManager.injectMarketingStaticFix(loc)
            }
        }
    }

    // MARK: - Scene 3: Active nav plan LSZQ → LSGC → LSGN → LSZB

    private static func injectNavPlanActive(flightPlanManager: FlightPlanManager, airportDataService: AirportDataService, locationManager: LocationManager) {
        let route = ["LSZQ", "LSGC", "LSGN", "LSZB"]
        // OurAirports' LSZQ point doesn't line up with the field symbol on the SwissTopo chart, so pin
        // the departure waypoint (and the held fix below) to the charted airport position. (Marketing.)
        let lszqCoord = CLLocationCoordinate2D(latitude: 47.392250, longitude: 7.029552)

        // Build the plan fresh so the LSZQ waypoint always sits on the charted field — a previously
        // saved plan could carry the off-position OurAirports coordinate.
        var plan = flightPlanManager.createFlightPlan(name: "LSZQ → LSZB Tour")
        for ident in route {
            let coord = ident == "LSZQ" ? lszqCoord : coordinate(ident, airportDataService: airportDataService)
            if let coord {
                plan.waypoints.append(FlightPlanWaypoint(name: ident, coordinate: coord))
            }
        }
        plan.calculateRouteData()
        flightPlanManager.updateFlightPlan(plan)
        flightPlanManager.activateFlightPlan(plan)

        // Present LSZQ (index 0) as the departure already passed and the active leg as LSZQ→LSGC:
        // markWaypoint() records LSZQ's ATO and advances currentWaypointIndex to 1 (LSGC). The nav
        // renders index < currentWaypointIndex as passed (green) and == as the active/next waypoint,
        // so LSGC becomes the next waypoint. (Explicit waypoint-index advance — the API the nav reads.)
        flightPlanManager.markWaypoint()

        // Held fix ON the first waypoint LSZQ — the aircraft sits exactly on the field marker (the old
        // fix sat ~3 NM south of it). LSGC is the active next waypoint; the speed + heading drive the
        // ground-track trend vector (1 / 2 / 5 min projection).
        // The LSZQ waypoint sits on the field (lszqCoord); the aircraft sits just down the LSZQ→LSGC
        // leg, SW of the field — "just departed". Charted position supplied for the marketing capture.
        let provider = MarketingLocationProvider.shared
        provider.holdStaticFix(latitude: 47.345151, longitude: 6.982395,
                               altitudeMeters: 2500.0 / 3.28084, speedKnots: 80, headingDegrees: 211)
        if let loc = provider.currentLocation {
            locationManager.injectMarketingStaticFix(loc)
        }

        // Show the leg chronometer mid-run (~1:37) so the nav map reads as an active navigation.
        flightPlanManager.marketingStartChronometer(elapsedSeconds: 95)
    }

    // MARK: - Scene 4: Plan with conflicts (into LSZQ from LSZB)

    private static func injectPlanConflicts(flightPlanManager: FlightPlanManager, airportDataService: AirportDataService) {
        // Prefer an existing example plan FROM LSZB INTO LSZQ (the one saved in the sim).
        let existing = flightPlanManager.flightPlans.first { plan in
            guard let first = plan.waypoints.first?.name.uppercased(),
                  let last = plan.waypoints.last?.name.uppercased() else { return false }
            return first == "LSZB" && last == "LSZQ"
        }

        if let existing {
            // Make it the most-recent / active so the editor opens on it.
            flightPlanManager.activateFlightPlan(existing)
            return
        }

        // Otherwise build LSZB → LSZG → LSZQ.
        let route = ["LSZB", "LSZG", "LSZQ"]
        var plan = flightPlanManager.createFlightPlan(name: "LSZB → LSZQ")
        for ident in route {
            if let coord = coordinate(ident, airportDataService: airportDataService) {
                plan.waypoints.append(FlightPlanWaypoint(name: ident, coordinate: coord))
            }
        }
        plan.calculateRouteData()
        flightPlanManager.updateFlightPlan(plan)
        flightPlanManager.activateFlightPlan(plan)
    }

    // MARK: - Scene 5: Flight Log — import the bundled marketing flights

    /// Filenames (without extension) of the bundled marketing flights, in display order. These are
    /// imported by BOTH the Home and Flight Log scenes.
    private static let marketingFlightFiles = [
        "wright_brothers_1903",
        "harriet_quimby_1912",
        "lindbergh_1927",
        "yeager_1947",
        "lszq_alpine_tour"
    ]

    /// A real recorded flight, bundled for the Flight Log hero only (NOT the Home set). It is the most
    /// recent flight, so it sorts to the top and is the one shown open in detail. (User-supplied export.)
    private static let realHighlightFlightFile = "vol_dalpes_2026"

    private static func injectFlightLog(appState: AppState) {
        let imported = importMarketingFlights(into: appState)
        // Flight Log hero highlights a REAL flight (Vol d'Alpes) on top of the marketing set.
        let real = importFlight(named: realHighlightFlightFile, into: appState)
        print("[Marketing] Imported \(imported) marketing flights + \(real ? 1 : 0) real flight")
    }

    /// Loads the bundled marketing flights into the real flight store (idempotent — skips ids already
    /// present). Shared by the Flight Log scene and the Home scene (so Home's "last flight" card has
    /// something to show). Returns the number newly imported.
    @discardableResult
    private static func importMarketingFlights(into appState: AppState) -> Int {
        marketingFlightFiles.reduce(0) { $0 + (importFlight(named: $1, into: appState) ? 1 : 0) }
    }

    /// Load one bundled flight JSON and insert it via the real persistence path. Idempotent (skips if
    /// the id is already present). Returns true if it was newly imported. The marketing/flights folder
    /// is a blue folder reference, so the JSONs land at <bundle>/flights/<name>.json.
    @discardableResult
    private static func importFlight(named name: String, into appState: AppState) -> Bool {
        guard let url = bundledMarketingFlightURL(named: name),
              let data = try? Data(contentsOf: url),
              let flight = try? Flight.fromJSON(data) else {
            print("[Marketing] Could not load bundled flight \(name)")
            return false
        }
        guard !appState.flights.contains(where: { $0.id == flight.id }) else { return false }
        var f = flight
        f.computeSummaryStats()
        appState.flights.insert(f, at: 0)
        appState.saveFlight(f) // real persistence path → appears in Flight Log
        return true
    }

    /// Resolve a bundled marketing flight JSON URL. Tries the folder-reference layout (flights/),
    /// then a flat bundle layout as a fallback.
    private static func bundledMarketingFlightURL(named name: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "flights") {
            return url
        }
        return Bundle.main.url(forResource: name, withExtension: "json")
    }
}

// MARK: - Marketing Debug View

import SwiftUI

/// Debug overlay for controlling marketing simulation
struct MarketingControlsView: View {
    @ObservedObject var provider = MarketingLocationProvider.shared
    @State private var showCustomControls = false

    // Scene injector (DEV-ONLY). These managers are inherited from ContentView's environment.
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var locationManager: LocationManager
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @EnvironmentObject var aircraftDataService: AircraftDataService
    @EnvironmentObject var flightPlanManager: FlightPlanManager
    @EnvironmentObject var airportDataService: AirportDataService
    @State private var selectedScene: MarketingScene = .home2Aircraft
    @State private var lastInjected: String?

    // Custom position inputs
    @State private var latitudeText = "46.8"
    @State private var longitudeText = "8.2"
    @State private var altitudeText = "1500"
    @State private var speedText = "70"
    @State private var headingText = "45"

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                // Header
                HStack {
                    Text("MARKETING MODE")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                    Spacer()

                    // Active indicator
                    Circle()
                        .fill(provider.isActive ? Color.green : Color.red)
                        .frame(width: 10, height: 10)
                }
                .padding(.horizontal)
                .padding(.top, 8)

                Divider().background(Color.white.opacity(0.3))

                // MARK: - Scene injector (DEV-ONLY)
                VStack(spacing: 6) {
                    HStack {
                        Text("SCENE INJECTOR")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.aviationGold)
                        Spacer()
                    }
                    Picker("Scene", selection: $selectedScene) {
                        ForEach(MarketingScene.allCases) { scene in
                            Text(scene.rawValue).tag(scene)
                        }
                    }
                    .pickerStyle(MenuPickerStyle())

                    Text(selectedScene.detail)
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.6))
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button(action: injectSelectedScene) {
                        Text("Inject Scene")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.aviationGold)

                    if let lastInjected {
                        Text(lastInjected)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.green)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal)

                Divider().background(Color.white.opacity(0.3))

                // Scenario picker
                Picker("Scenario", selection: $provider.currentScenario) {
                    ForEach(MarketingScenario.allCases) { scenario in
                        Text(scenario.rawValue).tag(scenario)
                    }
                }
                .pickerStyle(MenuPickerStyle())
                .padding(.horizontal)

                // Playback speed slider
                VStack(spacing: 4) {
                    HStack {
                        Text("Speed: \(String(format: "%.1fx", provider.playbackSpeed))")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.8))
                        Spacer()
                    }
                    Slider(value: $provider.playbackSpeed, in: 0.5...20.0, step: 0.5)
                        .tint(.aviationGold)
                }
                .padding(.horizontal)

                // Playback controls
                HStack(spacing: 20) {
                    Button(action: { provider.previousWaypoint() }) {
                        Image(systemName: "backward.fill")
                    }

                    Button(action: {
                        if provider.isActive && !provider.useCustomPosition {
                            provider.togglePause()
                        } else {
                            provider.start()
                        }
                    }) {
                        Image(systemName: provider.isActive && !provider.isPaused && !provider.useCustomPosition ? "pause.fill" : "play.fill")
                            .font(.system(size: 24))
                    }

                    Button(action: { provider.nextWaypoint() }) {
                        Image(systemName: "forward.fill")
                    }

                    Button(action: { provider.stop() }) {
                        Image(systemName: "stop.fill")
                    }
                }
                .foregroundColor(.white)
                .padding(.vertical, 8)

                // Current position info
                if let location = provider.currentLocation {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Position: \(String(format: "%.4f", location.coordinate.latitude)), \(String(format: "%.4f", location.coordinate.longitude))")
                        Text("Altitude: \(Int(location.altitude)) m (\(Int(location.altitude * 3.28084)) ft)")
                        Text("Speed: \(Int(location.speed * 1.94384)) kt")
                        Text("Heading: \(Int(provider.currentHeading))°")
                        if !provider.useCustomPosition {
                            Text("Waypoint: \(provider.currentIndex + 1)/\(provider.currentScenario.track.count)")
                        } else {
                            Text("Mode: Custom Position")
                        }
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))
                    .padding(.horizontal)
                }

                Divider().background(Color.white.opacity(0.3))

                // Custom position toggle
                Toggle("Custom Position", isOn: $showCustomControls)
                    .padding(.horizontal)
                    .foregroundColor(.white)

                if showCustomControls {
                    VStack(spacing: 8) {
                        HStack {
                            Text("Lat:")
                                .frame(width: 50, alignment: .trailing)
                            TextField("46.8", text: $latitudeText)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .keyboardType(.decimalPad)
                        }
                        HStack {
                            Text("Lon:")
                                .frame(width: 50, alignment: .trailing)
                            TextField("8.2", text: $longitudeText)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .keyboardType(.decimalPad)
                        }
                        HStack {
                            Text("Alt (m):")
                                .frame(width: 50, alignment: .trailing)
                            TextField("1500", text: $altitudeText)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .keyboardType(.decimalPad)
                        }
                        HStack {
                            Text("Speed:")
                                .frame(width: 50, alignment: .trailing)
                            TextField("70", text: $speedText)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .keyboardType(.decimalPad)
                        }
                        HStack {
                            Text("Hdg:")
                                .frame(width: 50, alignment: .trailing)
                            TextField("45", text: $headingText)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .keyboardType(.decimalPad)
                        }

                        Button("Apply Custom Position") {
                            if let lat = Double(latitudeText),
                               let lon = Double(longitudeText),
                               let alt = Double(altitudeText),
                               let spd = Double(speedText),
                               let hdg = Double(headingText) {
                                provider.setCustomPosition(
                                    latitude: lat,
                                    longitude: lon,
                                    altitude: alt,
                                    speed: spd,
                                    heading: hdg
                                )
                            }
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Use Scenario Track") {
                            provider.clearCustomPosition()
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.horizontal)
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                }
            }
            .padding(.bottom, 12)
        }
        .frame(width: 280)
        .frame(maxHeight: 500)
        .background(Color.black.opacity(0.85))
        .cornerRadius(12)
    }

    /// Drive the app into the selected marketing scene (DEV-ONLY). Always gated by Marketing Mode at
    /// the call site (this overlay only renders when Marketing Mode is on).
    private func injectSelectedScene() {
        MarketingSceneInjector.inject(
            selectedScene,
            appState: appState,
            locationManager: locationManager,
            subscriptionManager: subscriptionManager,
            aircraftDataService: aircraftDataService,
            flightPlanManager: flightPlanManager,
            airportDataService: airportDataService
        )
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        lastInjected = "Injected: \(selectedScene.rawValue) @ \(formatter.string(from: Date()))"
    }
}

// MARK: - Integration Helper

/// Extension to inject marketing location into LocationManager
extension LocationManager {
    /// Call this in a marketing build to use fake locations
    @MainActor func useMarketingLocation() {
        let provider = MarketingLocationProvider.shared

        // Override current location with marketing data
        if let marketingLocation = provider.getCurrentLocation() {
            self.currentLocation = marketingLocation
        }
    }
}

// MARK: - Preview

#Preview {
    let subscriptionManager = SubscriptionManager()
    return MarketingControlsView()
        .frame(height: 600)
        .background(Color.gray)
        .environmentObject(AppState())
        .environmentObject(LocationManager())
        .environmentObject(subscriptionManager)
        .environmentObject(AircraftDataService(subscriptionManager: subscriptionManager))
        .environmentObject(FlightPlanManager())
        .environmentObject(AirportDataService())
}
