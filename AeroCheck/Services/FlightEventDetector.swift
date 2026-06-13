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
        touchAndGoAccelSpeedKts: 40.0,
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

        // Touch-and-go acceleration: equal to touchdownSpeed (provides hysteresis)
        // Previously touchdownSpeed - 5, but the narrow 5 kts gap caused false TGs
        // from GPS ground speed fluctuations during approach with headwind.
        self.touchAndGoAccelSpeedKts = self.touchdownSpeedKts

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

    // MARK: - Clock Seam

    /// Injectable clock. Defaults to wall-clock; scripted-trajectory tests substitute a synthetic
    /// clock so the time-based cooldown / takeoff-suppression / pending-expiry logic is exercised
    /// deterministically without real-time sleeps. Behaviour in production is identical. (PR-34)
    var clock: () -> Date = { Date() }

    // MARK: - State Machine

    private var state: DetectorState = .idle
    private var stateAirport: Airport?
    private var stateEntryTime: Date?

    /// Whether touchdown state was entered via low approach (altitude confirmed < 100 ft AGL)
    /// vs speed-based fallback from airportZone (altitude unconfirmed).
    /// Used to gate touch-and-go detection: TG from speed-based fallback requires altitude validation.
    private var touchdownViaLowApproach: Bool = false

    // MARK: - Airborne Tracking

    /// Whether the aircraft has exceeded airborne speed at least once during this session.
    /// Full-stop detection is suppressed until the aircraft has actually flown.
    /// Reset to false after each full stop to require proof of flight before detecting another.
    private var hasBeenAirborne: Bool = false

    /// Speed threshold (knots) that must be exceeded to consider the aircraft "has been airborne".
    /// Well above max taxi speed (~15 kts) and well below any aircraft's Vso (~42+ kts).
    private let airborneEvidenceSpeedKts: Double = 30.0

    /// Whether the aircraft has been airborne since the last landing event (full stop or T&G).
    /// Prevents false positives from ground taxi/parking after a confirmed landing.
    /// Starts as true so the first landing of the flight can be detected.
    private var airborneAfterLanding: Bool = true

    /// Altitude (feet MSL) at which the last landing event was detected.
    /// Used with airborneAfterLanding to require altitude gain before allowing another landing.
    private var lastLandingAltMsl: Double = 0

    /// Current altitude (feet MSL) from most recent GPS reading. Used by emit functions.
    private var currentAltMslFt: Double = 0

    // MARK: - Speed Tracking

    /// Speed history for smoothing (last `speedSmoothingReadings`, interval-scaled)
    private var speedHistory: [(timestamp: Date, speedKts: Double)] = []

    /// Minimum speed recorded during low approach (knots)
    private var minSpeedInLowApproach: Double = .infinity

    /// Minimum speed recorded during touchdown (knots)
    private var minSpeedInTouchdown: Double = .infinity

    /// Number of GPS readings below touchdown speed threshold
    private var touchdownSpeedReadings: Int = 0

    /// Time when touchdown state was entered
    private var touchdownEntryTime: Date?

    /// Altitude AGL (feet) when touchdown state was entered.
    /// Used for altitude-based go-around detection from touchdown state.
    private var touchdownAltAglFt: Double = 0

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

    /// GPS recording interval (seconds) the detector is currently tuned for. Set via
    /// `configure(...)` at flight start. Detection thresholds below are derived from
    /// wall-clock durations so they are correct at any user-selected interval (1–30 s),
    /// not just the legacy 5 s cadence (PERF-05). At 5 s these reproduce the previous
    /// constants exactly (40 s → 8 readings, 15 s → 3 readings).
    private var recordingInterval: TimeInterval = 5.0

    /// Target dwell at taxi speed to declare a full stop (~40 s).
    private let fullStopDwellSeconds: TimeInterval = 40.0
    /// Target dwell below touchdown speed to confirm a touchdown (~15 s).
    private let touchdownConfirmDwellSeconds: TimeInterval = 15.0
    /// Speed-smoothing window (~15 s) to reduce GPS noise.
    private let speedSmoothingSeconds: TimeInterval = 15.0

    /// Number of consecutive readings spanning `seconds` at the current interval (min 2,
    /// so a single noisy sample can never trigger a transition).
    private func readings(forSeconds seconds: TimeInterval) -> Int {
        max(2, Int((seconds / max(recordingInterval, 0.5)).rounded(.up)))
    }

    /// Readings at taxi speed needed to declare a full stop (≈ `fullStopDwellSeconds`).
    /// `internal` (not `private`) so the interval scaling is unit-testable (PERF-05).
    var requiredTaxiSpeedReadings: Int { readings(forSeconds: fullStopDwellSeconds) }
    /// Number of recent readings averaged for speed smoothing (≈ `speedSmoothingSeconds`).
    var speedSmoothingReadings: Int { readings(forSeconds: speedSmoothingSeconds) }

    /// Extended cooldown after a full-stop landing (seconds).
    /// Prevents subsequent taxi + takeoff from being classified as T&G.
    private let fullStopCooldownSeconds: TimeInterval = 180.0

    /// End time of full-stop cooldown period
    private var fullStopCooldownUntil: Date?

    // MARK: - Detection Thresholds

    // Speed thresholds (configured per-aircraft, with sensible defaults)
    private var speedConfig: AircraftSpeedConfig = .defaults
    /// Readings below touchdown speed needed to confirm a touchdown (≈ `touchdownConfirmDwellSeconds`).
    var minTouchdownReadings: Int { readings(forSeconds: touchdownConfirmDwellSeconds) }

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
    private let touchdownTimeoutSeconds: TimeInterval = 300.0

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
    func configure(speeds: [SpeedReference], stallSpeed: Int, recordingInterval: TimeInterval = 5.0) {
        speedConfig = AircraftSpeedConfig(speeds: speeds, stallSpeed: stallSpeed)
        self.recordingInterval = recordingInterval > 0 ? recordingInterval : 5.0
        print("[FlightEventDetector] Configured for aircraft: touchdown=\(Int(speedConfig.touchdownSpeedKts)) kts, goAroundMin=\(Int(speedConfig.goAroundMinSpeedKts)) kts, T&G accel=\(Int(speedConfig.touchAndGoAccelSpeedKts)) kts; interval=\(self.recordingInterval)s → fullStop=\(requiredTaxiSpeedReadings) readings, touchdown=\(minTouchdownReadings), smoothing=\(speedSmoothingReadings)")
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
        let now = clock()

        // PR-40: expire a pending event the pilot never confirmed/dismissed within a bounded window.
        // Each emit guards `pendingX == nil`, so a pending event that's never consumed (e.g. its
        // confirmation overlay was behind the full-screen map) would otherwise silently block EVERY
        // subsequent event of that type for the rest of the flight.
        expireStalePendingEvents(now: now)

        // Update speed history (keep enough readings for the interval-scaled smoothing window)
        speedHistory.append((timestamp: now, speedKts: rawSpeedKts))
        while speedHistory.count > speedSmoothingReadings {
            speedHistory.removeFirst()
        }

        let speedKts = smoothedSpeedKts()

        // Track whether aircraft has been airborne during this session
        if !hasBeenAirborne && speedKts > airborneEvidenceSpeedKts {
            hasBeenAirborne = true
            print("[FlightEventDetector] Aircraft has been airborne (speed: \(Int(speedKts)) kts)")
        }

        // Track current altitude for use by emit functions
        let altMslFt = location.altitude * 3.28084
        currentAltMslFt = altMslFt

        // Track whether aircraft has been airborne since last landing event.
        // Requires both speed > 30 kts AND altitude gain > 200 ft above landing altitude.
        if !airborneAfterLanding && speedKts > airborneEvidenceSpeedKts && altMslFt > lastLandingAltMsl + 200.0 {
            airborneAfterLanding = true
            print("[FlightEventDetector] Airborne after landing (speed: \(Int(speedKts)) kts, alt: \(Int(altMslFt)) ft MSL, landing was at \(Int(lastLandingAltMsl)) ft MSL)")
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
        airborneAfterLanding = true
        lastLandingAltMsl = 0
        currentAltMslFt = 0
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

    /// PR-40: clear pending events older than the expiry window so a never-consumed confirmation
    /// can't block all future detections of that type.
    private static let pendingEventExpirySeconds: TimeInterval = 180
    private func expireStalePendingEvents(now: Date) {
        if let e = pendingGoAround, now.timeIntervalSince(e.timestamp) > Self.pendingEventExpirySeconds {
            pendingGoAround = nil
        }
        if let e = pendingTouchAndGo, now.timeIntervalSince(e.timestamp) > Self.pendingEventExpirySeconds {
            pendingTouchAndGo = nil
        }
        if let e = pendingFullStop, now.timeIntervalSince(e.timestamp) > Self.pendingEventExpirySeconds {
            pendingFullStop = nil
        }
    }

    /// Called by the manual event buttons (LANDED / GO AROUND / TOUCH AND GO) so the automatic
    /// detector doesn't then emit a DUPLICATE for the same physical event. Mirrors the suppression
    /// the emit* paths apply: clears any matching pending event, stamps the event/cooldown times,
    /// and (for landings) requires fresh airborne evidence before the next auto landing event.
    /// dismissFullStop() only cleared an already-pending event; a manual LANDED while vacating fires
    /// the detector's pending full stop AFTERWARDS, so the suppression must be set proactively. (PR-07)
    func notifyManualEvent(_ type: FlightEventType, at explicitTime: Date? = nil) {
        let time = explicitTime ?? clock()
        lastEventTime = time
        touchdownSpeedReadings = 0
        minSpeedInTouchdown = .infinity
        consecutiveTaxiSpeedReadings = 0
        switch type {
        case .fullStop:
            pendingFullStop = nil
            airborneAfterLanding = false
            hasBeenAirborne = false
            lastLandingAltMsl = currentAltMslFt
            fullStopCooldownUntil = time.addingTimeInterval(fullStopCooldownSeconds)
            transitionToIdle()
        case .touchAndGo:
            pendingTouchAndGo = nil
            airborneAfterLanding = false
            lastLandingAltMsl = currentAltMslFt
            lastTakeoffTime = time
        case .goAround:
            pendingGoAround = nil
            lastTakeoffTime = time
        }
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
            touchdownAltAglFt = altAglFt
            minSpeedInTouchdown = speedKts
            touchdownSpeedReadings = 1
            consecutiveTaxiSpeedReadings = speedKts < speedConfig.taxiSpeedKts ? 1 : 0
            touchdownViaLowApproach = false  // Altitude not confirmed
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
            touchdownAltAglFt = altAglFt
            minSpeedInTouchdown = speedKts
            touchdownSpeedReadings = 1
            consecutiveTaxiSpeedReadings = speedKts < speedConfig.taxiSpeedKts ? 1 : 0
            touchdownViaLowApproach = true  // Altitude confirmed < 100 ft AGL
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

        // Go-around from touchdown: aircraft altitude climbing significantly above touchdown level.
        // This catches go-arounds where speed briefly dipped below touchdown threshold
        // during approach before the pilot applied full power.
        let altGainFt = altAglFt - touchdownAltAglFt
        if altGainFt > 150 && speedKts > speedConfig.goAroundMinSpeedKts {
            print("[FlightEventDetector] Go-around from touchdown (alt gain: \(Int(altGainFt)) ft, speed: \(Int(speedKts)) kts)")
            emitGoAround(airport: stateAirport)
            // Transition back to airport zone
            state = .airportZone
            stateEntryTime = now
            touchdownEntryTime = nil
            touchdownSpeedReadings = 0
            minSpeedInTouchdown = .infinity
            consecutiveTaxiSpeedReadings = 0
            return
        }

        // Full-stop detection: sustained very low speed = the plane has stopped
        if consecutiveTaxiSpeedReadings >= requiredTaxiSpeedReadings {
            print("[FlightEventDetector] Full stop detected (speed < \(Int(speedConfig.taxiSpeedKts)) kts for \(consecutiveTaxiSpeedReadings) readings)")
            emitFullStop(airport: stateAirport)
            fullStopCooldownUntil = now.addingTimeInterval(fullStopCooldownSeconds)
            transitionToIdle()
            return
        }

        // PR-22: a balked landing (go-around) recovers speed in seconds, but 150 ft of raw GPS climb
        // takes ~13 s — so the touch-and-go branch below would fire first and mislabel it. "Ground
        // evidence" means the aircraft actually slowed to a true ground-roll speed (below taxi speed);
        // without it, a speed recovery while climbing away is a go-around, not a touch-and-go. This
        // catches it on a much smaller (faster) climb confirmation than the 150 ft branch above.
        let hasGroundEvidence = minSpeedInTouchdown < speedConfig.taxiSpeedKts
        if speedKts >= speedConfig.touchAndGoAccelSpeedKts
            && touchdownSpeedReadings >= minTouchdownReadings
            && !hasGroundEvidence
            && altGainFt > 50 {
            print("[FlightEventDetector] Go-around (speed recovered, climbing \(Int(altGainFt)) ft, no ground evidence)")
            emitGoAround(airport: stateAirport)
            state = .airportZone
            stateEntryTime = now
            touchdownEntryTime = nil
            touchdownSpeedReadings = 0
            minSpeedInTouchdown = .infinity
            consecutiveTaxiSpeedReadings = 0
            return
        }

        // Check for touch-and-go: speed increases back above acceleration threshold after having at
        // least minTouchdownReadings below touchdownSpeedKts, AND there is ground evidence (slowed to
        // a true rollout speed) or the touchdown was altitude-confirmed via low approach. Without
        // either, the speed-recovery case above has already classified it as a go-around. (PR-22)
        if speedKts >= speedConfig.touchAndGoAccelSpeedKts
            && touchdownSpeedReadings >= minTouchdownReadings
            && (hasGroundEvidence || touchdownViaLowApproach || altAglFt < lowApproachEntryAltAglFt) {
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

    /// Returns smoothed speed (average of the interval-scaled recent window) to reduce GPS noise
    private func smoothedSpeedKts() -> Double {
        let count = min(speedSmoothingReadings, speedHistory.count)
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
           clock().timeIntervalSince(takeoffTime) < takeoffSuppressionSeconds {
            print("[FlightEventDetector] Go-around suppressed (within \(Int(takeoffSuppressionSeconds))s of takeoff)")
            return
        }

        let message: String
        if let airport = airport {
            message = String(localized: "Go-around detected at \(airport.name)")
        } else {
            message = String(localized: "Go-around detected")
        }

        let now = clock()
        let event = DetectedFlightEvent(type: .goAround, timestamp: now, airport: airport, message: message)
        pendingGoAround = event
        lastEventTime = now
        lastTakeoffTime = now
        print("[FlightEventDetector] GO-AROUND: \(message)")
    }

    private func emitTouchAndGo(airport: Airport?) {
        // Suppress if aircraft has never been airborne in this session
        guard hasBeenAirborne else {
            print("[FlightEventDetector] Touch-and-go suppressed (aircraft has not been airborne)")
            return
        }

        // Suppress if aircraft hasn't been airborne since last landing event
        guard airborneAfterLanding else {
            print("[FlightEventDetector] Touch-and-go suppressed (not airborne since last landing)")
            return
        }

        guard pendingTouchAndGo == nil else { return }

        // Suppress events within the takeoff suppression window
        if let takeoffTime = lastTakeoffTime,
           clock().timeIntervalSince(takeoffTime) < takeoffSuppressionSeconds {
            print("[FlightEventDetector] Touch-and-go suppressed (within \(Int(takeoffSuppressionSeconds))s of takeoff)")
            return
        }

        let message: String
        if let airport = airport {
            message = String(localized: "Touch-and-go detected at \(airport.name)")
        } else {
            message = String(localized: "Touch-and-go detected")
        }

        let now = clock()
        let event = DetectedFlightEvent(type: .touchAndGo, timestamp: now, airport: airport, message: message)
        pendingTouchAndGo = event
        lastEventTime = now
        lastTakeoffTime = now
        // Record landing altitude and require airborne evidence before next landing event
        lastLandingAltMsl = currentAltMslFt
        airborneAfterLanding = false
        print("[FlightEventDetector] TOUCH-AND-GO: \(message)")
    }

    private func emitFullStop(airport: Airport?) {
        // Suppress full-stop if aircraft has never been airborne in this session
        guard hasBeenAirborne else {
            print("[FlightEventDetector] Full stop suppressed (aircraft has not been airborne)")
            transitionToIdle()
            return
        }

        // Suppress if aircraft hasn't been airborne since last landing event
        guard airborneAfterLanding else {
            print("[FlightEventDetector] Full stop suppressed (not airborne since last landing)")
            transitionToIdle()
            return
        }

        guard pendingFullStop == nil else { return }

        // Suppress events within the takeoff suppression window
        if let takeoffTime = lastTakeoffTime,
           clock().timeIntervalSince(takeoffTime) < takeoffSuppressionSeconds {
            print("[FlightEventDetector] Full stop suppressed (within \(Int(takeoffSuppressionSeconds))s of takeoff)")
            return
        }

        let message: String
        if let airport = airport {
            message = String(localized: "Full-stop landing detected at \(airport.name)")
        } else {
            message = String(localized: "Full-stop landing detected")
        }

        let event = DetectedFlightEvent(type: .fullStop, timestamp: clock(), airport: airport, message: message)
        pendingFullStop = event
        lastEventTime = clock()
        // Record landing altitude and require airborne evidence before next landing event
        lastLandingAltMsl = currentAltMslFt
        airborneAfterLanding = false
        hasBeenAirborne = false
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
        touchdownAltAglFt = 0
        touchdownSpeedReadings = 0
        consecutiveTaxiSpeedReadings = 0
        touchdownViaLowApproach = false
    }
}
