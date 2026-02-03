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

/// Detects go-arounds and touch-and-goes during flight using GPS data and airport proximity
@MainActor
class FlightEventDetector: ObservableObject {
    // MARK: - Published Properties

    /// Pending go-around event awaiting user confirmation
    @Published var pendingGoAround: DetectedFlightEvent?

    /// Pending touch-and-go event awaiting user confirmation
    @Published var pendingTouchAndGo: DetectedFlightEvent?

    // MARK: - Detection State

    /// Whether the aircraft is currently on approach
    private var isApproaching = false

    /// The airport being approached
    private var approachAirport: Airport?

    /// Minimum speed recorded during approach (m/s)
    private var minSpeedDuringApproach: Double = .infinity

    /// Whether touchdown has been detected (speed dropped significantly)
    private var touchdownDetected = false

    /// Time when ground roll started (stable low speed after touchdown)
    private var groundRollStartTime: Date?

    /// Previous altitude readings for trend detection
    private var altitudeHistory: [(timestamp: Date, altitude: Double)] = []

    /// Previous distance to approach airport
    private var previousDistanceToAirport: Double = .infinity

    /// Whether we're tracking for a potential go-around
    private var trackingGoAround = false

    /// Whether we're tracking for a potential touch-and-go
    private var trackingTouchAndGo = false

    // MARK: - Detection Thresholds

    /// Maximum distance from airport to consider as approach (nautical miles)
    private let approachDistanceNm: Double = 3.0

    /// Maximum altitude AGL to consider as approach (feet)
    private let approachAltitudeFt: Double = 2000.0

    /// Speed threshold for touchdown detection (knots)
    private let touchdownSpeedKts: Double = 50.0

    /// Minimum speed that indicates no touchdown occurred (knots) - go-around indicator
    private let noTouchdownSpeedKts: Double = 30.0

    /// Speed threshold for takeoff after touch-and-go (knots)
    private let takeoffSpeedKts: Double = 60.0

    /// Minimum ground roll duration before acceleration indicates touch-and-go (seconds)
    private let minGroundRollDuration: TimeInterval = 5.0

    /// Altitude increase that indicates climb after go-around (meters)
    private let climbAltitudeThreshold: Double = 30.0 // ~100 feet

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
        let speedKts = location.speed * metersPerSecondToKnots
        let altitudeM = location.altitude

        // Update altitude history (keep last 10 readings for trend detection)
        let now = Date()
        altitudeHistory.append((timestamp: now, altitude: altitudeM))
        if altitudeHistory.count > 10 {
            altitudeHistory.removeFirst()
        }

        // Find nearest airport within approach distance
        let nearestAirport = nearbyAirports.first
        let distanceToAirport: Double
        if let airport = nearestAirport {
            let airportLocation = CLLocation(latitude: airport.latitude, longitude: airport.longitude)
            distanceToAirport = location.distance(from: airportLocation) / nauticalMilesToMeters
        } else {
            distanceToAirport = .infinity
        }

        // Calculate altitude AGL (approximate - using airport elevation if available)
        let fieldElevationM = Double(nearestAirport?.elevation ?? 0) * feetToMeters
        let altitudeAglM = altitudeM - fieldElevationM
        let altitudeAglFt = altitudeAglM / feetToMeters

        // Detect approach phase
        let wasApproaching = isApproaching
        if distanceToAirport <= approachDistanceNm && altitudeAglFt < approachAltitudeFt && isDescending() {
            if !isApproaching {
                // Starting new approach
                startApproach(airport: nearestAirport)
            }
            isApproaching = true
            approachAirport = nearestAirport

            // Track minimum speed during approach
            if speedKts < minSpeedDuringApproach {
                minSpeedDuringApproach = speedKts
            }

            // Check for touchdown (speed drops below threshold)
            if speedKts < touchdownSpeedKts && !touchdownDetected {
                touchdownDetected = true
                groundRollStartTime = now
                print("[FlightEventDetector] Touchdown detected at \(speedKts) kts")
            }

            // Check for ground roll (stable speed after touchdown)
            if touchdownDetected && speedKts < touchdownSpeedKts && speedKts > 10 {
                // Still in ground roll
                if groundRollStartTime == nil {
                    groundRollStartTime = now
                }
            }

            previousDistanceToAirport = distanceToAirport
        } else if wasApproaching {
            // Just exited approach phase
            evaluateApproachOutcome(currentSpeed: speedKts, currentAltitudeAgl: altitudeAglFt, distanceToAirport: distanceToAirport)
        }

        // Touch-and-go detection: acceleration after ground roll
        if touchdownDetected, let rollStart = groundRollStartTime {
            let rollDuration = now.timeIntervalSince(rollStart)
            if rollDuration >= minGroundRollDuration && speedKts > takeoffSpeedKts && isClimbing() {
                // Touch-and-go detected!
                detectTouchAndGo()
            }
        }
    }

    /// Reset all detection state (call when flight ends)
    func reset() {
        isApproaching = false
        approachAirport = nil
        minSpeedDuringApproach = .infinity
        touchdownDetected = false
        groundRollStartTime = nil
        altitudeHistory = []
        previousDistanceToAirport = .infinity
        trackingGoAround = false
        trackingTouchAndGo = false
        pendingGoAround = nil
        pendingTouchAndGo = nil
    }

    /// Dismiss pending go-around without recording
    func dismissGoAround() {
        pendingGoAround = nil
        resetApproachState()
    }

    /// Dismiss pending touch-and-go without recording
    func dismissTouchAndGo() {
        pendingTouchAndGo = nil
        resetApproachState()
    }

    // MARK: - Private Methods

    private func startApproach(airport: Airport?) {
        minSpeedDuringApproach = .infinity
        touchdownDetected = false
        groundRollStartTime = nil
        trackingGoAround = false
        trackingTouchAndGo = false
        print("[FlightEventDetector] Approach started to \(airport?.ident ?? "unknown")")
    }

    private func resetApproachState() {
        isApproaching = false
        approachAirport = nil
        minSpeedDuringApproach = .infinity
        touchdownDetected = false
        groundRollStartTime = nil
        trackingGoAround = false
        trackingTouchAndGo = false
    }

    private func evaluateApproachOutcome(currentSpeed: Double, currentAltitudeAgl: Double, distanceToAirport: Double) {
        // Check if this was a go-around (never touched down and climbing away)
        if minSpeedDuringApproach > noTouchdownSpeedKts && isClimbing() && distanceToAirport > previousDistanceToAirport {
            detectGoAround()
        }

        // If we had a touchdown but didn't detect touch-and-go, it might be a full stop
        // (handled elsewhere in the app flow)

        resetApproachState()
    }

    private func detectGoAround() {
        guard pendingGoAround == nil else { return } // Don't overwrite existing pending event

        let message: String
        if let airport = approachAirport {
            message = String(localized: "Go-around detected at \(airport.name)")
        } else {
            message = String(localized: "Go-around detected")
        }

        let event = DetectedFlightEvent(
            type: .goAround,
            timestamp: Date(),
            airport: approachAirport,
            message: message
        )
        pendingGoAround = event
        print("[FlightEventDetector] Go-around detected: \(message)")
    }

    private func detectTouchAndGo() {
        guard pendingTouchAndGo == nil else { return } // Don't overwrite existing pending event

        let message: String
        if let airport = approachAirport {
            message = String(localized: "Touch-and-go detected at \(airport.name)")
        } else {
            message = String(localized: "Touch-and-go detected")
        }

        let event = DetectedFlightEvent(
            type: .touchAndGo,
            timestamp: Date(),
            airport: approachAirport,
            message: message
        )
        pendingTouchAndGo = event
        print("[FlightEventDetector] Touch-and-go detected: \(message)")

        // Reset approach state after detecting touch-and-go
        touchdownDetected = false
        groundRollStartTime = nil
    }

    /// Check if aircraft is descending based on altitude history
    private func isDescending() -> Bool {
        guard altitudeHistory.count >= 3 else { return false }

        let recent = altitudeHistory.suffix(3)
        let altitudes = recent.map { $0.altitude }

        // Check if generally descending (allowing for small fluctuations)
        let first = altitudes.first ?? 0
        let last = altitudes.last ?? 0
        return last < first - 5 // At least 5 meters lower
    }

    /// Check if aircraft is climbing based on altitude history
    private func isClimbing() -> Bool {
        guard altitudeHistory.count >= 3 else { return false }

        let recent = altitudeHistory.suffix(3)
        let altitudes = recent.map { $0.altitude }

        // Check if generally climbing
        let first = altitudes.first ?? 0
        let last = altitudes.last ?? 0
        return last > first + climbAltitudeThreshold
    }
}
