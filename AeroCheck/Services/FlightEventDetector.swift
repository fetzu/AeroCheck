import Foundation
import CoreLocation

/// Detected flight event type
enum FlightEventType: String {
    case goAround = "Go-Around"
    case touchAndGo = "Touch-and-Go"
}

/// A detected flight event awaiting confirmation
struct DetectedFlightEvent: Identifiable {
    let id = UUID()
    let type: FlightEventType
    let timestamp: Date
    let airport: Airport?
    let message: String
}

/// Internal state for the detection state machine
private enum DetectorState {
    case idle
    case airportZone
    case lowApproach
    case touchdown
}

/// Detects go-arounds and touch-and-goes during flight using GPS data and airport proximity.
///
/// Uses a finite state machine with four states:
/// - **idle**: Not near any airport
/// - **airportZone**: Within 2 NM of airport and below 500 ft AGL
/// - **lowApproach**: Within 1 NM and below 100 ft AGL (go-around detection zone)
/// - **touchdown**: Speed dropped below 40 kts near airport (touch-and-go detection zone)
@MainActor
class FlightEventDetector: ObservableObject {
    // MARK: - Published Properties

    /// Pending go-around event awaiting user confirmation
    @Published var pendingGoAround: DetectedFlightEvent?

    /// Pending touch-and-go event awaiting user confirmation
    @Published var pendingTouchAndGo: DetectedFlightEvent?

    // MARK: - State Machine

    private var state: DetectorState = .idle
    private var stateAirport: Airport?
    private var stateEntryTime: Date?

    // MARK: - Speed Tracking

    /// Speed history for smoothing (last 5 readings)
    private var speedHistory: [(timestamp: Date, speedKts: Double)] = []

    /// Minimum speed recorded during low approach (knots)
    private var minSpeedInLowApproach: Double = .infinity

    /// Minimum speed recorded during touchdown (knots)
    private var minSpeedInTouchdown: Double = .infinity

    /// Number of GPS readings below touchdown speed threshold
    private var touchdownSpeedReadings: Int = 0

    /// Time when touchdown state was entered
    private var touchdownEntryTime: Date?

    // MARK: - Cooldown

    /// Timestamp of last detected event (for cooldown)
    private var lastEventTime: Date?

    // MARK: - Detection Thresholds

    // Airport zone entry/exit (with hysteresis to prevent oscillation)
    private let airportZoneEntryDistanceNm: Double = 2.0
    private let airportZoneExitDistanceNm: Double = 2.5
    private let airportZoneEntryAltAglFt: Double = 500.0
    private let airportZoneExitAltAglFt: Double = 600.0

    // Low approach zone entry/exit (with hysteresis)
    private let lowApproachEntryDistanceNm: Double = 1.0
    private let lowApproachExitDistanceNm: Double = 1.5
    private let lowApproachEntryAltAglFt: Double = 100.0
    private let lowApproachExitAltAglFt: Double = 150.0

    // Speed thresholds (calibrated from real flight data)
    private let touchdownSpeedKts: Double = 40.0         // Below this = on/near ground
    private let goAroundMinSpeedKts: Double = 25.0       // If never below this in low approach = go-around
    private let touchAndGoAccelSpeedKts: Double = 35.0   // Acceleration back above this after touchdown = T&G
    private let minTouchdownReadings: Int = 1            // At least 1 GPS reading below 40 kts (~5-7 sec)

    // Cooldown between events
    private let eventCooldownSeconds: TimeInterval = 45.0

    // Touchdown timeout (full stop detection handled elsewhere)
    private let touchdownTimeoutSeconds: TimeInterval = 120.0

    // MARK: - Conversion Constants

    private let metersPerSecondToKnots: Double = 1.94384
    private let nauticalMilesToMeters: Double = 1852.0
    private let feetToMeters: Double = 0.3048

    // MARK: - Public Methods

    /// Process a new location update to detect flight events
    /// - Parameters:
    ///   - location: Current GPS location
    ///   - nearbyAirports: Airports near the current position (from AirportDataService)
    func processLocation(_ location: CLLocation, nearbyAirports: [Airport]) {
        let rawSpeedKts = max(0, location.speed * metersPerSecondToKnots)
        let now = Date()

        // Update speed history (keep last 5 readings)
        speedHistory.append((timestamp: now, speedKts: rawSpeedKts))
        if speedHistory.count > 5 {
            speedHistory.removeFirst()
        }

        let speedKts = smoothedSpeedKts()

        // Check cooldown - skip detection if too soon after last event
        if let lastEvent = lastEventTime, now.timeIntervalSince(lastEvent) < eventCooldownSeconds {
            return
        }

        // Find nearest airport and calculate distance + AGL
        guard let nearestAirport = nearbyAirports.first else {
            if state != .idle { transitionToIdle() }
            return
        }

        let airportLocation = CLLocation(latitude: nearestAirport.latitude, longitude: nearestAirport.longitude)
        let distanceNm = location.distance(from: airportLocation) / nauticalMilesToMeters
        let fieldElevationM = Double(nearestAirport.elevation ?? 0) * feetToMeters
        let altAglM = location.altitude - fieldElevationM
        let altAglFt = altAglM / feetToMeters

        // State machine dispatch
        switch state {
        case .idle:
            handleIdle(speedKts: speedKts, distanceNm: distanceNm, altAglFt: altAglFt, airport: nearestAirport, now: now)
        case .airportZone:
            handleAirportZone(speedKts: speedKts, distanceNm: distanceNm, altAglFt: altAglFt, airport: nearestAirport, now: now)
        case .lowApproach:
            handleLowApproach(speedKts: speedKts, distanceNm: distanceNm, altAglFt: altAglFt, airport: nearestAirport, now: now)
        case .touchdown:
            handleTouchdown(speedKts: speedKts, distanceNm: distanceNm, altAglFt: altAglFt, airport: nearestAirport, now: now)
        }
    }

    /// Reset all detection state (call when flight ends)
    func reset() {
        transitionToIdle()
        speedHistory = []
        lastEventTime = nil
        pendingGoAround = nil
        pendingTouchAndGo = nil
    }

    /// Dismiss pending go-around without recording
    func dismissGoAround() {
        pendingGoAround = nil
    }

    /// Dismiss pending touch-and-go without recording
    func dismissTouchAndGo() {
        pendingTouchAndGo = nil
    }

    // MARK: - State Handlers

    private func handleIdle(speedKts: Double, distanceNm: Double, altAglFt: Double, airport: Airport, now: Date) {
        if distanceNm <= airportZoneEntryDistanceNm && altAglFt < airportZoneEntryAltAglFt {
            state = .airportZone
            stateAirport = airport
            stateEntryTime = now
            print("[FlightEventDetector] Entered airport zone for \(airport.ident) (dist: \(String(format: "%.2f", distanceNm)) NM, altAGL: \(Int(altAglFt)) ft)")
        }
    }

    private func handleAirportZone(speedKts: Double, distanceNm: Double, altAglFt: Double, airport: Airport, now: Date) {
        // Check for exit (with hysteresis)
        if distanceNm > airportZoneExitDistanceNm || altAglFt > airportZoneExitAltAglFt {
            print("[FlightEventDetector] Exited airport zone (dist: \(String(format: "%.2f", distanceNm)) NM, altAGL: \(Int(altAglFt)) ft)")
            transitionToIdle()
            return
        }

        // Check for descent into low approach zone
        if distanceNm <= lowApproachEntryDistanceNm && altAglFt < lowApproachEntryAltAglFt {
            state = .lowApproach
            stateEntryTime = now
            minSpeedInLowApproach = speedKts
            print("[FlightEventDetector] Entered low approach at \(airport.ident) (speed: \(Int(speedKts)) kts, altAGL: \(Int(altAglFt)) ft)")
            return
        }

        // Speed-based fallback: detect touchdown even if altitude AGL is inaccurate
        // (GPS altitude can have significant error, but speed is reliable)
        if speedKts < touchdownSpeedKts && distanceNm <= lowApproachEntryDistanceNm {
            state = .touchdown
            stateEntryTime = now
            touchdownEntryTime = now
            minSpeedInTouchdown = speedKts
            touchdownSpeedReadings = 1
            print("[FlightEventDetector] Speed-based touchdown at \(airport.ident) (speed: \(Int(speedKts)) kts)")
        }
    }

    private func handleLowApproach(speedKts: Double, distanceNm: Double, altAglFt: Double, airport: Airport, now: Date) {
        // Track minimum speed
        minSpeedInLowApproach = min(minSpeedInLowApproach, speedKts)

        // Check for touchdown (speed drops below threshold)
        if speedKts < touchdownSpeedKts {
            state = .touchdown
            stateEntryTime = now
            touchdownEntryTime = now
            minSpeedInTouchdown = speedKts
            touchdownSpeedReadings = 1
            print("[FlightEventDetector] Touchdown in low approach at \(airport.ident) (speed: \(Int(speedKts)) kts)")
            return
        }

        // Check for go-around: exiting low approach zone without touching down
        // AND minimum speed stayed above go-around threshold (never slowed to landing speed)
        if distanceNm > lowApproachExitDistanceNm || altAglFt > lowApproachExitAltAglFt {
            if minSpeedInLowApproach > goAroundMinSpeedKts {
                emitGoAround(airport: stateAirport)
            }
            // Transition back to airport zone if still within it, otherwise idle
            if distanceNm <= airportZoneExitDistanceNm && altAglFt < airportZoneExitAltAglFt {
                state = .airportZone
                stateEntryTime = now
            } else {
                transitionToIdle()
            }
        }
    }

    private func handleTouchdown(speedKts: Double, distanceNm: Double, altAglFt: Double, airport: Airport, now: Date) {
        minSpeedInTouchdown = min(minSpeedInTouchdown, speedKts)

        // Count readings below touchdown speed
        if speedKts < touchdownSpeedKts {
            touchdownSpeedReadings += 1
        }

        // Check for touch-and-go: speed increases back above acceleration threshold
        // after having at least minTouchdownReadings below touchdownSpeedKts
        if speedKts >= touchAndGoAccelSpeedKts && touchdownSpeedReadings >= minTouchdownReadings {
            emitTouchAndGo(airport: stateAirport)
            // Transition back to airport zone (aircraft will likely do another circuit)
            state = .airportZone
            stateEntryTime = now
            touchdownEntryTime = nil
            touchdownSpeedReadings = 0
            minSpeedInTouchdown = .infinity
            return
        }

        // Check for exit from airport zone entirely
        if distanceNm > airportZoneExitDistanceNm {
            transitionToIdle()
            return
        }

        // Safety timeout: if in touchdown state for too long, it's likely a full stop
        // (full stop landing is handled by AppState separately)
        if let entry = touchdownEntryTime, now.timeIntervalSince(entry) > touchdownTimeoutSeconds {
            print("[FlightEventDetector] Touchdown timeout - likely full stop")
            transitionToIdle()
        }
    }

    // MARK: - Speed Smoothing

    /// Returns smoothed speed (average of last 3 readings) to reduce GPS noise
    private func smoothedSpeedKts() -> Double {
        let count = min(3, speedHistory.count)
        guard count > 0 else { return 0 }
        let recent = speedHistory.suffix(count)
        return recent.map { $0.speedKts }.reduce(0, +) / Double(count)
    }

    // MARK: - Event Emission

    private func emitGoAround(airport: Airport?) {
        guard pendingGoAround == nil else { return }

        let message: String
        if let airport = airport {
            message = String(localized: "Go-around detected at \(airport.name)")
        } else {
            message = String(localized: "Go-around detected")
        }

        let event = DetectedFlightEvent(type: .goAround, timestamp: Date(), airport: airport, message: message)
        pendingGoAround = event
        lastEventTime = Date()
        print("[FlightEventDetector] GO-AROUND: \(message)")
    }

    private func emitTouchAndGo(airport: Airport?) {
        guard pendingTouchAndGo == nil else { return }

        let message: String
        if let airport = airport {
            message = String(localized: "Touch-and-go detected at \(airport.name)")
        } else {
            message = String(localized: "Touch-and-go detected")
        }

        let event = DetectedFlightEvent(type: .touchAndGo, timestamp: Date(), airport: airport, message: message)
        pendingTouchAndGo = event
        lastEventTime = Date()
        print("[FlightEventDetector] TOUCH-AND-GO: \(message)")
    }

    // MARK: - State Transitions

    private func transitionToIdle() {
        state = .idle
        stateAirport = nil
        stateEntryTime = nil
        minSpeedInLowApproach = .infinity
        minSpeedInTouchdown = .infinity
        touchdownEntryTime = nil
        touchdownSpeedReadings = 0
    }
}
