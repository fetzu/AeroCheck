import Foundation
import CoreLocation

/// Detected flight event type
enum FlightEventType: String {
    case goAround = "Go-Around"
    case touchAndGo = "Touch-and-Go"
    case fullStop = "Full Stop"
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

/// Aircraft-specific speed thresholds for event detection.
/// Derived from the aircraft's published speeds (Vso, Vr, etc.)
struct AircraftSpeedConfig {
    let touchdownSpeedKts: Double       // Below this = on/near ground
    let goAroundMinSpeedKts: Double     // If never below this in low approach = go-around
    let touchAndGoAccelSpeedKts: Double // Acceleration above this after touchdown = T&G
    let taxiSpeedKts: Double            // Below this for extended time = full stop

    /// Default thresholds (fallback when no aircraft data available)
    static let defaults = AircraftSpeedConfig(
        touchdownSpeedKts: 40.0,
        goAroundMinSpeedKts: 25.0,
        touchAndGoAccelSpeedKts: 35.0,
        taxiSpeedKts: 10.0
    )

    /// Create configuration from aircraft speed references
    /// - Parameters:
    ///   - speeds: Array of SpeedReference from the aircraft checklist
    ///   - stallSpeed: Aircraft's clean stall speed (Vs) in KIAS
    init(speeds: [SpeedReference], stallSpeed: Int) {
        let vso = AircraftSpeedConfig.extractSpeed(named: "Vso", from: speeds)
        let vr = AircraftSpeedConfig.extractSpeed(named: "Vr", from: speeds)

        let vsoValue = vso ?? Double(stallSpeed) * 0.85
        let vrValue = vr ?? Double(stallSpeed) * 1.1

        // Touchdown threshold: Vr + 5 kts
        // During a touch-and-go, the plane briefly decelerates below rotation speed.
        // Using Vr + margin ensures we detect touchdown even with GPS smoothing.
        self.touchdownSpeedKts = vrValue + 5.0

        // Go-around minimum speed: Vso + 5 kts
        // If the plane's minimum speed during low approach never drops below this,
        // it was never configured for landing = go-around.
        self.goAroundMinSpeedKts = vsoValue + 5.0

        // Touch-and-go acceleration: touchdownSpeed - 5 kts
        self.touchAndGoAccelSpeedKts = self.touchdownSpeedKts - 5.0

        // Taxi speed: universal across aircraft types
        self.taxiSpeedKts = 10.0
    }

    private init(touchdownSpeedKts: Double, goAroundMinSpeedKts: Double, touchAndGoAccelSpeedKts: Double, taxiSpeedKts: Double) {
        self.touchdownSpeedKts = touchdownSpeedKts
        self.goAroundMinSpeedKts = goAroundMinSpeedKts
        self.touchAndGoAccelSpeedKts = touchAndGoAccelSpeedKts
        self.taxiSpeedKts = taxiSpeedKts
    }

    /// Extract a numeric speed value from the speeds array by name.
    /// Handles range values like "60-55" by taking the first (higher) value.
    /// Handles slash values like "70/66" by taking the first value.
    private static func extractSpeed(named name: String, from speeds: [SpeedReference]) -> Double? {
        guard let ref = speeds.first(where: { $0.name == name }) else { return nil }
        let value = ref.value
        if let dashRange = value.range(of: "-"), dashRange.lowerBound != value.startIndex {
            let first = String(value[value.startIndex..<dashRange.lowerBound])
            return Double(first.trimmingCharacters(in: .whitespaces))
        }
        if value.contains("/") {
            let parts = value.components(separatedBy: "/")
            return Double(parts[0].trimmingCharacters(in: .whitespaces))
        }
        return Double(value.trimmingCharacters(in: .whitespaces))
    }
}

/// Detects go-arounds, touch-and-goes, and full-stop landings during flight using GPS data and airport proximity.
///
/// Uses a finite state machine with four states:
/// - **idle**: Not near any airport
/// - **airportZone**: Within 2 NM of airport and below 500 ft AGL
/// - **lowApproach**: Within 1 NM and below 100 ft AGL (go-around detection zone)
/// - **touchdown**: Speed dropped below touchdown threshold near airport
///
/// Speed thresholds are aircraft-specific when configured via `configure(speeds:stallSpeed:)`.
@MainActor
class FlightEventDetector: ObservableObject {
    // MARK: - Published Properties

    /// Pending go-around event awaiting user confirmation
    @Published var pendingGoAround: DetectedFlightEvent?

    /// Pending touch-and-go event awaiting user confirmation
    @Published var pendingTouchAndGo: DetectedFlightEvent?

    /// Pending full-stop event awaiting user confirmation
    @Published var pendingFullStop: DetectedFlightEvent?

    // MARK: - State Machine

    private var state: DetectorState = .idle
    private var stateAirport: Airport?
    private var stateEntryTime: Date?

    // MARK: - Airborne Tracking

    /// Whether the aircraft has exceeded airborne speed at least once during this session.
    /// Full-stop detection is suppressed until the aircraft has actually flown.
    private var hasBeenAirborne: Bool = false

    /// Speed threshold (knots) that must be exceeded to consider the aircraft "has been airborne".
    /// Well above max taxi speed (~15 kts) and well below any aircraft's Vso (~42+ kts).
    private let airborneEvidenceSpeedKts: Double = 30.0

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

    // MARK: - Takeoff Suppression

    /// Time of last takeoff (line-up or post-T&G/go-around departure).
    /// Events are suppressed for a window after takeoff to prevent false positives.
    private var lastTakeoffTime: Date?

    /// Suppression window after takeoff (seconds).
    /// A touch-and-go cannot occur this soon after departure.
    private let takeoffSuppressionSeconds: TimeInterval = 90.0

    // MARK: - Full-Stop Detection

    /// Number of consecutive readings at taxi speed or below in touchdown state
    private var consecutiveTaxiSpeedReadings: Int = 0

    /// Readings at taxi speed needed to declare full stop (at 5-sec GPS interval, ~30 seconds)
    private let requiredTaxiSpeedReadings: Int = 6

    /// Extended cooldown after a full-stop landing (seconds).
    /// Prevents subsequent taxi + takeoff from being classified as T&G.
    private let fullStopCooldownSeconds: TimeInterval = 180.0

    /// End time of full-stop cooldown period
    private var fullStopCooldownUntil: Date?

    // MARK: - Detection Thresholds

    // Speed thresholds (configured per-aircraft, with sensible defaults)
    private var speedConfig: AircraftSpeedConfig = .defaults
    private let minTouchdownReadings: Int = 1

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

    // Cooldown between events
    private let eventCooldownSeconds: TimeInterval = 45.0

    // Touchdown timeout (full stop fallback)
    private let touchdownTimeoutSeconds: TimeInterval = 120.0

    // MARK: - Conversion Constants

    private let metersPerSecondToKnots: Double = 1.94384
    private let nauticalMilesToMeters: Double = 1852.0
    private let feetToMeters: Double = 0.3048

    // MARK: - Public Methods

    /// Configure detection thresholds based on the current aircraft's speed data.
    /// Call this when a flight starts, after the checklist is loaded.
    /// - Parameters:
    ///   - speeds: Speed reference data from the aircraft checklist
    ///   - stallSpeed: Aircraft's clean stall speed (Vs) in KIAS
    func configure(speeds: [SpeedReference], stallSpeed: Int) {
        speedConfig = AircraftSpeedConfig(speeds: speeds, stallSpeed: stallSpeed)
        print("[FlightEventDetector] Configured for aircraft: touchdown=\(Int(speedConfig.touchdownSpeedKts)) kts, goAroundMin=\(Int(speedConfig.goAroundMinSpeedKts)) kts, T&G accel=\(Int(speedConfig.touchAndGoAccelSpeedKts)) kts")
    }

    /// Set the takeoff time (call when line-up or first departure occurs)
    func setTakeoffTime(_ time: Date) {
        lastTakeoffTime = time
    }

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

        // Track whether aircraft has been airborne during this session
        if !hasBeenAirborne && speedKts > airborneEvidenceSpeedKts {
            hasBeenAirborne = true
            print("[FlightEventDetector] Aircraft has been airborne (speed: \(Int(speedKts)) kts)")
        }

        // Check cooldown - skip detection if too soon after last event
        if let lastEvent = lastEventTime, now.timeIntervalSince(lastEvent) < eventCooldownSeconds {
            return
        }

        // Check full-stop cooldown - longer cooldown after confirmed full stop
        if let fullStopUntil = fullStopCooldownUntil, now < fullStopUntil {
            if state == .touchdown {
                transitionToIdle()
            }
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
        pendingFullStop = nil
        lastTakeoffTime = nil
        fullStopCooldownUntil = nil
        speedConfig = .defaults
        hasBeenAirborne = false
    }

    /// Dismiss pending go-around without recording
    func dismissGoAround() {
        pendingGoAround = nil
    }

    /// Dismiss pending touch-and-go without recording
    func dismissTouchAndGo() {
        pendingTouchAndGo = nil
    }

    /// Dismiss pending full-stop without recording
    func dismissFullStop() {
        pendingFullStop = nil
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
        if speedKts < speedConfig.touchdownSpeedKts && distanceNm <= lowApproachEntryDistanceNm {
            state = .touchdown
            stateEntryTime = now
            touchdownEntryTime = now
            minSpeedInTouchdown = speedKts
            touchdownSpeedReadings = 1
            consecutiveTaxiSpeedReadings = speedKts < speedConfig.taxiSpeedKts ? 1 : 0
            print("[FlightEventDetector] Speed-based touchdown at \(airport.ident) (speed: \(Int(speedKts)) kts)")
        }
    }

    private func handleLowApproach(speedKts: Double, distanceNm: Double, altAglFt: Double, airport: Airport, now: Date) {
        // Track minimum speed
        minSpeedInLowApproach = min(minSpeedInLowApproach, speedKts)

        // Check for touchdown (speed drops below threshold)
        if speedKts < speedConfig.touchdownSpeedKts {
            state = .touchdown
            stateEntryTime = now
            touchdownEntryTime = now
            minSpeedInTouchdown = speedKts
            touchdownSpeedReadings = 1
            consecutiveTaxiSpeedReadings = speedKts < speedConfig.taxiSpeedKts ? 1 : 0
            print("[FlightEventDetector] Touchdown in low approach at \(airport.ident) (speed: \(Int(speedKts)) kts)")
            return
        }

        // Check for go-around: exiting low approach zone without touching down
        // AND minimum speed stayed above go-around threshold (never slowed to landing speed)
        if distanceNm > lowApproachExitDistanceNm || altAglFt > lowApproachExitAltAglFt {
            if minSpeedInLowApproach > speedConfig.goAroundMinSpeedKts {
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
        if speedKts < speedConfig.touchdownSpeedKts {
            touchdownSpeedReadings += 1
        }

        // Track consecutive taxi-speed readings for full-stop detection
        if speedKts < speedConfig.taxiSpeedKts {
            consecutiveTaxiSpeedReadings += 1
        } else {
            consecutiveTaxiSpeedReadings = 0
        }

        // Full-stop detection: sustained very low speed = the plane has stopped
        if consecutiveTaxiSpeedReadings >= requiredTaxiSpeedReadings {
            print("[FlightEventDetector] Full stop detected (speed < \(Int(speedConfig.taxiSpeedKts)) kts for \(consecutiveTaxiSpeedReadings) readings)")
            emitFullStop(airport: stateAirport)
            fullStopCooldownUntil = now.addingTimeInterval(fullStopCooldownSeconds)
            transitionToIdle()
            return
        }

        // Check for touch-and-go: speed increases back above acceleration threshold
        // after having at least minTouchdownReadings below touchdownSpeedKts
        if speedKts >= speedConfig.touchAndGoAccelSpeedKts && touchdownSpeedReadings >= minTouchdownReadings {
            emitTouchAndGo(airport: stateAirport)
            // Transition back to airport zone (aircraft will likely do another circuit)
            state = .airportZone
            stateEntryTime = now
            touchdownEntryTime = nil
            touchdownSpeedReadings = 0
            minSpeedInTouchdown = .infinity
            consecutiveTaxiSpeedReadings = 0
            return
        }

        // Check for exit from airport zone entirely
        if distanceNm > airportZoneExitDistanceNm {
            transitionToIdle()
            return
        }

        // Safety timeout: if in touchdown state for too long, it's likely a full stop
        if let entry = touchdownEntryTime, now.timeIntervalSince(entry) > touchdownTimeoutSeconds {
            print("[FlightEventDetector] Touchdown timeout - likely full stop")
            emitFullStop(airport: stateAirport)
            fullStopCooldownUntil = now.addingTimeInterval(fullStopCooldownSeconds)
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
        // Suppress if aircraft has never been airborne in this session
        guard hasBeenAirborne else {
            print("[FlightEventDetector] Go-around suppressed (aircraft has not been airborne)")
            return
        }

        guard pendingGoAround == nil else { return }

        // Suppress events within the takeoff suppression window
        if let takeoffTime = lastTakeoffTime,
           Date().timeIntervalSince(takeoffTime) < takeoffSuppressionSeconds {
            print("[FlightEventDetector] Go-around suppressed (within \(Int(takeoffSuppressionSeconds))s of takeoff)")
            return
        }

        let message: String
        if let airport = airport {
            message = String(localized: "Go-around detected at \(airport.name)")
        } else {
            message = String(localized: "Go-around detected")
        }

        let event = DetectedFlightEvent(type: .goAround, timestamp: Date(), airport: airport, message: message)
        pendingGoAround = event
        lastEventTime = Date()
        lastTakeoffTime = Date()
        print("[FlightEventDetector] GO-AROUND: \(message)")
    }

    private func emitTouchAndGo(airport: Airport?) {
        // Suppress if aircraft has never been airborne in this session
        guard hasBeenAirborne else {
            print("[FlightEventDetector] Touch-and-go suppressed (aircraft has not been airborne)")
            return
        }

        guard pendingTouchAndGo == nil else { return }

        // Suppress events within the takeoff suppression window
        if let takeoffTime = lastTakeoffTime,
           Date().timeIntervalSince(takeoffTime) < takeoffSuppressionSeconds {
            print("[FlightEventDetector] Touch-and-go suppressed (within \(Int(takeoffSuppressionSeconds))s of takeoff)")
            return
        }

        let message: String
        if let airport = airport {
            message = String(localized: "Touch-and-go detected at \(airport.name)")
        } else {
            message = String(localized: "Touch-and-go detected")
        }

        let event = DetectedFlightEvent(type: .touchAndGo, timestamp: Date(), airport: airport, message: message)
        pendingTouchAndGo = event
        lastEventTime = Date()
        lastTakeoffTime = Date()
        print("[FlightEventDetector] TOUCH-AND-GO: \(message)")
    }

    private func emitFullStop(airport: Airport?) {
        // Suppress full-stop if aircraft has never been airborne in this session
        guard hasBeenAirborne else {
            print("[FlightEventDetector] Full stop suppressed (aircraft has not been airborne)")
            transitionToIdle()
            return
        }

        guard pendingFullStop == nil else { return }

        // Suppress events within the takeoff suppression window
        if let takeoffTime = lastTakeoffTime,
           Date().timeIntervalSince(takeoffTime) < takeoffSuppressionSeconds {
            print("[FlightEventDetector] Full stop suppressed (within \(Int(takeoffSuppressionSeconds))s of takeoff)")
            return
        }

        let message: String
        if let airport = airport {
            message = String(localized: "Full-stop landing detected at \(airport.name)")
        } else {
            message = String(localized: "Full-stop landing detected")
        }

        let event = DetectedFlightEvent(type: .fullStop, timestamp: Date(), airport: airport, message: message)
        pendingFullStop = event
        lastEventTime = Date()
        print("[FlightEventDetector] FULL STOP: \(message)")
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
        consecutiveTaxiSpeedReadings = 0
    }
}
