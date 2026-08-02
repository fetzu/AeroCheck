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

/// Every event the detector emitted this flight, whether or not the pilot confirmed it.
/// The corpus fixture tests assert against this sequence; the reconciliation pass (PR-B)
/// reads it as the detector's own record of the flight.
struct EmittedFlightEvent: Equatable {
    let type: FlightEventType
    let timestamp: Date
    let airportIdent: String?
}

/// A median-filtered relative barometric altitude sample from `BarometricAltitudeService`.
struct BaroAltitudeSample {
    /// Relative altitude in feet since the altimeter session started (CMAltimeter datum).
    let relativeAltitudeFt: Double
    let timestamp: Date
}

/// Internal state for the v2 detection state machine (port of detector_v2.py)
private enum DetectorState {
    case ground     // parked / taxiing
    case climbout   // takeoff roll completed, climbing, not yet 300 ft
    case airborne   // has climbed ≥300 ft since last ground contact
    case approach   // descended into the <400 ft / 1.5 nm window
    case rollout    // touchdown evidence — rolling / stopping on the runway
}

/// Aircraft-specific speed thresholds for event detection, derived from the aircraft's
/// published speeds (Vso, Vr). The v2 detector consumes Vso/Vr directly; the derived
/// thresholds mirror the validated Python prototype exactly.
struct AircraftSpeedConfig {
    let vsoKts: Double
    let vrKts: Double

    /// Below this near the field = possible touchdown (Vr + 5).
    var touchdownSpeedKts: Double { vrKts + 5.0 }
    /// Raw speed dip below this during a rollout = wheels-on evidence (max(Vso − 5, 24)).
    var rolloutSpeedKts: Double { max(vsoKts - 5.0, 24.0) }

    /// Default thresholds (fallback when no aircraft data available).
    /// Matches the validated harness defaults (vso 38 / vr 45).
    static let defaults = AircraftSpeedConfig(vsoKts: 38.0, vrKts: 45.0)

    init(vsoKts: Double, vrKts: Double) {
        self.vsoKts = vsoKts
        self.vrKts = vrKts
    }

    /// Create configuration from aircraft speed references
    /// - Parameters:
    ///   - speeds: Array of SpeedReference from the aircraft checklist
    ///   - stallSpeed: Aircraft's clean stall speed (Vs) in KIAS
    init(speeds: [SpeedReference], stallSpeed: Int) {
        let vso = AircraftSpeedConfig.extractSpeed(named: "Vso", from: speeds)
        let vr = AircraftSpeedConfig.extractSpeed(named: "Vr", from: speeds)
        self.vsoKts = vso ?? Double(stallSpeed) * 0.85
        self.vrKts = vr ?? Double(stallSpeed) * 1.1
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

/// Detects takeoffs, go-arounds, touch-and-goes, and full-stop landings from GPS (and,
/// when available, barometric) data. Swift port of the validated v2 prototype
/// (CLAUDE/review/flight-events/detector_v2.py — 19/20 labeled flights, 43/49 exact vs
/// club billing). The Python prototype is the authoritative spec for the GPS path; any
/// behavioural change must be re-validated against that harness.
///
/// v2 design, in five rules:
/// 1. The takeoff is a first-class event (ground → acceleration through Vr → climb). It
///    anchors the 60 s suppression window at the real liftoff and defines "has flown"
///    (300 ft of climb, not 30 kt of taxi).
/// 2. GPS altitude bias is calibrated while parked, with a sticky fixed-wing-only anchor,
///    and refreshed from flat ground samples at every confirmed touch.
/// 3. Wheels-on evidence = a raw-speed dip below max(Vso−5, 24) OR altitude flat at ground
///    level (<15 ft corrected AGL) — never a 15 s speed mean (median-of-3 raw instead).
/// 4. Touches classify at climb-away: stopped ≥10 s → FS (emitted at the stop, stamped at
///    touchdown), ground evidence → T&G, neither → GA.
/// 5. Go-around = descended into the <400 ft / 1.5 nm window then climbed 150 ft off the
///    minimum without touchdown evidence — stamped at the lowest point (decision D4).
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
    /// clock so the time-based suppression / stillness / pending-expiry logic is exercised
    /// deterministically without real-time sleeps. Behaviour in production is identical. (PR-34)
    var clock: () -> Date = { Date() }

    // MARK: - Event Record

    /// Every emission this flight, in order (see `EmittedFlightEvent`).
    private(set) var emittedEvents: [EmittedFlightEvent] = []

    /// Detected liftoff times (first fast sample of each initial takeoff acceleration run).
    private(set) var takeoffTimes: [Date] = []

    /// Test / reconciliation seam: called on every emission, before the pending-event publish.
    var onEvent: ((FlightEventType, Date) -> Void)?

    // MARK: - Conversion Constants

    private let metersPerSecondToKnots = 1.94384
    private let nauticalMilesToMeters = 1852.0
    private let feetToMeters = 0.3048

    // MARK: - Tunables (validated against the 53-flight corpus — do not tweak casually;
    // the Python harness in CLAUDE/review/flight-events/ is the referee)

    /// Suppression window after a takeoff / climb-away (seconds). Anchored at real liftoff.
    private let takeoffSuppressionSeconds: TimeInterval = 60.0
    /// Stillness dwell that turns a rollout into a full stop (matches the real
    /// after-landing-check stop: land → roll to exit → stop ~10 s → roll to parking).
    private let fullStopStillnessSeconds: TimeInterval = 10.0
    /// Rollout timeout: crawling around the field this long after touchdown = full stop.
    private let rolloutTimeoutSeconds: TimeInterval = 300.0
    /// Corrected AGL below which a flat sample counts as ground contact. 15 ft, not 40:
    /// instructor go-arounds bottom flat at 19–52 ft; wheels-on reads ~0 ± 10 ft once the
    /// bias is calibrated. Deliberate ground effect below 15 ft is the barometer's job.
    private let flatAglBarFt: Double = 15.0
    /// Max |Δaltitude| between consecutive samples for a "flat pair" (ft).
    private let flatPairMaxDeltaFt: Double = 12.0
    /// Barometer freshness window: a baro sample older than this falls back to GPS.
    private let baroFreshnessSeconds: TimeInterval = 3.0
    /// Duplicate-event guard: auto-emissions within this window of a manual event of the
    /// same class are suppressed (a second landing <60 s after the first is physically
    /// impossible in these aircraft).
    private let manualEventDedupeSeconds: TimeInterval = 60.0

    // MARK: - State Machine (mirrors detector_v2.py field-for-field)

    private var state: DetectorState = .ground
    private var anchor: Airport?                 // sticky fixed-wing airport anchor
    private var altBiasFt: Double?               // GPS alt − field elev measured while parked
    private var biasSamples: [Double] = []
    private var lastTakeoffTime: Date?
    private var hasFlown = false                 // climbed ≥300 ft AGL since last landing
    private var rawSpeedWindow: [Double] = []    // median-of-3 raw speed
    private var altHistory: [(time: Date, altFt: Double)] = []
    private var minAglInApproach: Double?
    private var minAglTime: Date?
    private var minRawSpeedInRollout: Double?
    private var touchdownTime: Date?
    private var stillSince: Date?
    private var accelRun = 0
    private var rolloutMinAgl: Double?
    private var firstFastSample: Date?           // first >25 kt sample of the takeoff run
    private var approachFlatPairs = 0
    private var flatAltSamples: [Double] = []    // altitudes of flat samples (per-touch bias refresh)
    private var flatRun = 0
    private var flatPeak = 0
    private var lastAltFt: Double?

    // MARK: - Barometer Fusion

    /// Latest median-filtered relative baro altitude, fed by LocationManager per fix.
    private var latestBaroSample: BaroAltitudeSample?
    /// Relative baro altitude at the last detected ground contact — the zero for baro AGL.
    /// Re-zeroed at every parked calibration sample and every confirmed touch, so weather
    /// drift (~28 ft/h) never accumulates. The baro is NEVER used as absolute altitude.
    private var baroGroundZeroFt: Double?
    /// Baro relative altitude at the previous processed fix (for the flat-pair Δ test).
    private var prevBaroRelFt: Double?
    private var prevBaroTimestamp: Date?

    // MARK: - Manual-Event Dedupe

    private var lastManualLandingTime: Date?     // TG or FS (shared physical-impossibility window)
    private var lastManualGoAroundTime: Date?

    // MARK: - Configuration

    private var speedConfig: AircraftSpeedConfig = .defaults

    /// Configure detection thresholds based on the current aircraft's speed data.
    /// Call this when a flight starts, after the checklist is loaded.
    /// `recordingInterval` is accepted for API compatibility; the v2 state machine uses
    /// wall-clock dwells throughout, so it needs no reading-count scaling.
    func configure(speeds: [SpeedReference], stallSpeed: Int, recordingInterval: TimeInterval = 5.0) {
        let config = AircraftSpeedConfig(speeds: speeds, stallSpeed: stallSpeed)
        // An unresolved checklist (no speeds, stall 0) would collapse every threshold —
        // taxiing at 6 kt would read as a takeoff roll. Fall back to the validated
        // defaults; they are aircraft-agnostic enough for every type in the fleet.
        speedConfig = (config.vsoKts > 0 && config.vrKts > 0) ? config : .defaults
        AppLog.flightEvents.debugLine("Configured v2: Vso=\(Int(speedConfig.vsoKts)) Vr=\(Int(speedConfig.vrKts)) → touchdown<\(Int(speedConfig.touchdownSpeedKts)) kt, rollout dip<\(Int(speedConfig.rolloutSpeedKts)) kt")
    }

    /// Direct Vso/Vr configuration — used by the corpus fixture tests and the offline
    /// reconciliation pass, which carry the aircraft's speeds as plain numbers.
    func configure(vsoKts: Double, vrKts: Double) {
        speedConfig = AircraftSpeedConfig(vsoKts: vsoKts, vrKts: vrKts)
    }

    /// Seed the takeoff/suppression anchor before the first detected liftoff
    /// (call when line-up occurs; the detected liftoff supersedes it).
    func setTakeoffTime(_ time: Date) {
        lastTakeoffTime = time
    }

    // MARK: - Main Processing

    /// Process a new location update to detect flight events.
    /// - Parameters:
    ///   - location: Current GPS location
    ///   - nearbyAirports: Airports near the current position (fixed-wing filtered upstream)
    ///   - baroSample: Latest median-filtered relative baro altitude, if the device has a
    ///     barometer. Consumed as the vertical reference for the ground-contact and
    ///     descend/climb tests when fresh (<3 s); GPS otherwise.
    func processLocation(_ location: CLLocation, nearbyAirports: [Airport], baroSample: BaroAltitudeSample? = nil) {
        let now = clock()

        // PR-40: expire a pending event the pilot never confirmed/dismissed within a bounded
        // window, so a never-consumed confirmation can't block later events of that type.
        expireStalePendingEvents(now: now)

        if let baroSample { latestBaroSample = baroSample }

        // Invalid GPS speed (CLLocation -1) is never converted to 0 kt: the sample still
        // updates the altitude trend and anchor below, but takes no speed-based decision.
        let rawSpeedKts: Double? = location.speed >= 0 ? location.speed * metersPerSecondToKnots : nil

        let altFt = location.altitude / feetToMeters
        altHistory.append((now, altFt))
        altHistory.removeAll { now.timeIntervalSince($0.time) > 20 }

        // Anchor: fixed-wing airports only, sticky while within 3 nm. (The feed is already
        // fixed-wing filtered; the filter here keeps the detector correct on any feed.)
        let fixedWing = nearbyAirports.filter { AirportType.fixedWing.contains($0.type) }
        if let current = anchor {
            let dAnchorNm = distanceNm(from: location, to: current)
            if dAnchorNm > 3.0 {
                anchor = fixedWing.first
                if anchor != nil { altBiasFt = nil }   // new field → stale bias
            }
        }
        if anchor == nil { anchor = fixedWing.first }
        guard let anchor else { return }

        let distNm = distanceNm(from: location, to: anchor)
        // Bias-corrected GPS AGL (uncorrected until the parked calibration lands).
        let gpsAgl = altFt - Double(anchor.elevation ?? 0) - (altBiasFt ?? 0)
        let agl: Double? = effectiveAgl(gpsAgl: gpsAgl, now: now)

        guard let raw = rawSpeedKts else {
            trackPrevBaro(now: now)
            return   // invalid fix: never treated as 0 kt in flight logic
        }
        let spd = medianOf3(raw)
        let prevAlt = lastAltFt
        lastAltFt = altFt

        switch state {
        case .ground:
            handleGround(now: now, raw: raw, altFt: altFt, distNm: distNm)
        case .climbout:
            handleClimbout(agl: agl, spd: spd)
        case .airborne:
            handleAirborne(now: now, raw: raw, spd: spd, agl: agl, distNm: distNm)
        case .approach:
            handleApproach(now: now, raw: raw, altFt: altFt, prevAlt: prevAlt, agl: agl, distNm: distNm)
        case .rollout:
            handleRollout(now: now, raw: raw, spd: spd, altFt: altFt, agl: agl)
        }

        trackPrevBaro(now: now)
    }

    // MARK: - State Handlers

    private func handleGround(now: Date, raw: Double, altFt: Double, distNm: Double) {
        // Calibrate the GPS altitude bias while parked near the field, and zero the baro
        // reference at the same moment — this is known ground contact.
        if raw < 5, distNm < 1.5 {
            biasSamples.append(altFt - Double(anchor?.elevation ?? 0))
            if biasSamples.count >= 4 {
                let recent = biasSamples.suffix(20).sorted()
                altBiasFt = recent[recent.count / 2]
            }
            zeroBaroReference(now: now)
        }
        // Takeoff: acceleration run through Vr with the liftoff anchored at the first fast
        // sample, so suppression starts at the real liftoff — not a checklist tap.
        if raw > 25, firstFastSample == nil {
            firstFastSample = now
        }
        if raw < 15 {
            firstFastSample = nil
            accelRun = 0
        }
        if raw > speedConfig.vrKts + 5 {
            accelRun += 1
            if accelRun >= 2 {
                let liftoff = firstFastSample ?? now
                lastTakeoffTime = liftoff
                takeoffTimes.append(liftoff)
                state = .climbout
                firstFastSample = nil
                accelRun = 0
                AppLog.flightEvents.debugLine("Takeoff detected at \(anchor?.ident ?? "?") (liftoff \(liftoff))")
            }
        } else {
            accelRun = 0
        }
    }

    private func handleClimbout(agl: Double?, spd: Double) {
        if let agl, agl > 300 {
            hasFlown = true
            state = .airborne
        } else if spd < 15 {
            // Aborted takeoff — back to ground, nothing logged (a non-event by construction).
            state = .ground
        }
    }

    private func handleAirborne(now: Date, raw: Double, spd: Double, agl: Double?, distNm: Double) {
        if let agl, agl < 400, distNm < 1.5, climbRateFpm(now: now) < -100 {
            state = .approach
            minAglInApproach = agl
            minAglTime = now
            approachFlatPairs = 0
        } else if spd < speedConfig.touchdownSpeedKts, distNm < 1.0, let agl, agl < 250 {
            // Direct touchdown fallback (steep/fast approach missed the window).
            enterRollout(now: now, raw: raw, agl: agl)
        }
    }

    private func handleApproach(now: Date, raw: Double, altFt: Double, prevAlt: Double?, agl: Double?, distNm: Double) {
        if let agl, let minAgl = minAglInApproach, agl < minAgl {
            minAglInApproach = agl
            minAglTime = now
        }
        // Ground-contact evidence INDEPENDENT of speed: a flat pair (|Δalt| < 12 ft) at
        // ground level. High-speed rolling touches (roulés at 45–60 kt GS) never drop below
        // the touchdown speed threshold, yet their altitude flatlines on the runway.
        // Requires a calibrated bias, so an uncalibrated GPS day cannot fake touches.
        // The Δ prefers baro (±1 ft @1 Hz) over GPS when a fresh sample exists.
        if altBiasFt != nil, let agl, agl < flatAglBarFt, distNm < 0.6,
           let delta = verticalDelta(altFt: altFt, prevAlt: prevAlt, now: now),
           abs(delta) < flatPairMaxDeltaFt {
            approachFlatPairs += 1
            flatAltSamples.append(altFt)
        }
        // Touchdown: raw speed low near the field (or below Vso anywhere in the window).
        if (raw < speedConfig.touchdownSpeedKts && distNm < 1.2 && (agl == nil || agl! < 150))
            || raw < speedConfig.vsoKts {
            enterRollout(now: now, raw: raw, agl: agl)
            return
        }
        // Go-around: descended into the window, then climbed ≥150 ft above the minimum.
        if let agl, let minAgl = minAglInApproach, minAgl < 300, agl - minAgl > 150 {
            if isSuppressed(at: now) {
                state = .climbout
            } else {
                if hasFlown {
                    // Flat at ground level on the way through → the wheels were on (or as
                    // near as the sensors can know): a touch-and-go, not a go-around.
                    let kind: FlightEventType = approachFlatPairs >= 1 ? .touchAndGo : .goAround
                    emit(kind, at: minAglTime ?? now)
                }
                afterLiftoff(now: now)
            }
            return
        }
        // Drifted away without descending to the window → back to airborne.
        if distNm > 2.0 || (agl ?? 0) > 600 {
            state = .airborne
        }
    }

    private func handleRollout(now: Date, raw: Double, spd: Double, altFt: Double, agl: Double?) {
        minRawSpeedInRollout = min(minRawSpeedInRollout ?? raw, raw)
        if rolloutMinAgl == nil || (agl != nil && agl! < rolloutMinAgl!) {
            rolloutMinAgl = agl
        }
        // Ground-roll signature: at ground level (<15 ft corrected AGL) while below
        // touchdown speed. A go-around's altitude is V-shaped and never lingers there; a
        // rolling wheel's does. (The prototype's per-sample Δalt term self-compares after
        // the history update and is identically zero — the validated behaviour is this
        // level test alone, preserved exactly. The corpus numbers depend on it.)
        let flat = raw < speedConfig.touchdownSpeedKts + 5 && (agl == nil || agl! < flatAglBarFt)
        flatRun = flat ? flatRun + 1 : 0
        if flat { flatAltSamples.append(altFt) }
        flatPeak = max(flatPeak, flatRun)

        // Stillness → full stop, stamped at TOUCHDOWN, not at the end of the dwell.
        if raw < 5 {
            if stillSince == nil { stillSince = now }
            if now.timeIntervalSince(stillSince!) >= fullStopStillnessSeconds {
                if hasFlown, !isSuppressed(at: now) {
                    emit(.fullStop, at: touchdownTime ?? now)
                }
                hasFlown = false
                state = .ground
                zeroBaroReference(now: now)
                resetRollout()
                return
            }
        } else {
            stillSince = nil
        }

        // Liftoff again → classify T&G vs GA at the climb-away (one decision point).
        let climbed = agl != nil && rolloutMinAgl != nil && agl! - rolloutMinAgl! > 120
        if spd > speedConfig.vrKts + 8, climbed {
            let groundEvidence = (minRawSpeedInRollout ?? .infinity) <= speedConfig.rolloutSpeedKts
                || flatPeak >= 1 || approachFlatPairs >= 1
            if !isSuppressed(at: now), hasFlown {
                emit(groundEvidence ? .touchAndGo : .goAround, at: touchdownTime ?? now)
            }
            afterLiftoff(now: now)
            return
        }

        // Timeout: crawling around the field → treat as full stop.
        if let touch = touchdownTime, now.timeIntervalSince(touch) > rolloutTimeoutSeconds {
            if hasFlown, !isSuppressed(at: now) {
                emit(.fullStop, at: touch)
            }
            hasFlown = false
            state = .ground
            zeroBaroReference(now: now)
            resetRollout()
        }
    }

    // MARK: - End-of-Flight Flush

    /// Flight ended (recording stopped). Six of the 53 corpus flights end within seconds of
    /// vacating the runway — the stillness dwell never completes and the flight's only
    /// landing would be silently lost. If the aircraft was in a rollout with touchdown
    /// evidence when the flight ended, that WAS the landing. Returns the flushed full-stop
    /// (stamped at touchdown) for the caller to record; the caller dedupes against events
    /// the pilot already recorded.
    func flushEndOfFlight() -> DetectedFlightEvent? {
        guard state == .rollout, hasFlown, let touch = touchdownTime else { return nil }
        hasFlown = false
        state = .ground
        resetRollout()
        let event = DetectedFlightEvent(
            type: .fullStop,
            timestamp: touch,
            airport: anchor,
            message: fullStopMessage(airport: anchor)
        )
        emittedEvents.append(EmittedFlightEvent(type: .fullStop, timestamp: touch, airportIdent: anchor?.ident))
        AppLog.flightEvents.debugLine("End-of-flight flush: full stop at \(touch) (\(anchor?.ident ?? "?"))")
        return event
    }

    // MARK: - Reset / Dismiss

    /// Reset all detection state (call when flight ends, after `flushEndOfFlight()`)
    func reset() {
        state = .ground
        anchor = nil
        altBiasFt = nil
        biasSamples = []
        lastTakeoffTime = nil
        hasFlown = false
        rawSpeedWindow = []
        altHistory = []
        minAglInApproach = nil
        minAglTime = nil
        firstFastSample = nil
        accelRun = 0
        approachFlatPairs = 0
        flatAltSamples = []
        lastAltFt = nil
        resetRollout()
        pendingGoAround = nil
        pendingTouchAndGo = nil
        pendingFullStop = nil
        emittedEvents = []
        takeoffTimes = []
        speedConfig = .defaults
        latestBaroSample = nil
        baroGroundZeroFt = nil
        prevBaroRelFt = nil
        prevBaroTimestamp = nil
        lastManualLandingTime = nil
        lastManualGoAroundTime = nil
    }

    /// Dismiss pending go-around without recording
    func dismissGoAround() { pendingGoAround = nil }

    /// Dismiss pending touch-and-go without recording
    func dismissTouchAndGo() { pendingTouchAndGo = nil }

    /// Dismiss pending full-stop without recording
    func dismissFullStop() { pendingFullStop = nil }

    /// PR-40: clear pending events older than the expiry window so a never-consumed
    /// confirmation can't block all future detections of that type.
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

    // MARK: - Manual Events

    /// Called by the manual event buttons (LANDED / GO AROUND / TOUCH AND GO) so the
    /// automatic detector doesn't emit a DUPLICATE for the same physical event (PR-07),
    /// and so the state machine follows the pilot's declaration.
    /// Returns the detector's best physical timestamp for the event — the touchdown time
    /// if a rollout is in progress, the approach minimum for a go-around — so the manual
    /// record can carry the real time instead of "now" (replaces backDatedStopTime()).
    @discardableResult
    func notifyManualEvent(_ type: FlightEventType, at explicitTime: Date? = nil) -> Date? {
        let time = explicitTime ?? clock()
        switch type {
        case .fullStop:
            pendingFullStop = nil
            lastManualLandingTime = time
            let physical = (state == .rollout) ? touchdownTime : nil
            hasFlown = false
            state = .ground
            zeroBaroReference(now: time)
            resetRollout()
            return physical
        case .touchAndGo:
            pendingTouchAndGo = nil
            lastManualLandingTime = time
            let physical = (state == .rollout) ? touchdownTime : nil
            lastTakeoffTime = time
            if state == .rollout || state == .approach {
                afterLiftoff(now: time)
            }
            return physical
        case .goAround:
            pendingGoAround = nil
            lastManualGoAroundTime = time
            let physical = (state == .approach || state == .rollout) ? minAglTime : nil
            lastTakeoffTime = time
            if state == .rollout || state == .approach {
                afterLiftoff(now: time)
            }
            return physical
        }
    }

    // MARK: - Helpers (state machine)

    private func enterRollout(now: Date, raw: Double, agl: Double?) {
        state = .rollout
        touchdownTime = now
        minRawSpeedInRollout = raw
        rolloutMinAgl = agl
        stillSince = nil
        AppLog.flightEvents.debugLine("Rollout entered at \(anchor?.ident ?? "?") (raw \(Int(raw)) kt, agl \(agl.map { String(Int($0)) } ?? "—") ft)")
    }

    private func afterLiftoff(now: Date) {
        lastTakeoffTime = now
        state = .climbout
        resetRollout()
        minAglInApproach = nil
        approachFlatPairs = 0
    }

    private func resetRollout() {
        touchdownTime = nil
        minRawSpeedInRollout = nil
        rolloutMinAgl = nil
        stillSince = nil
        flatRun = 0
        flatPeak = 0
    }

    private func isSuppressed(at now: Date) -> Bool {
        guard let takeoff = lastTakeoffTime else { return false }
        return now.timeIntervalSince(takeoff) < takeoffSuppressionSeconds
    }

    private func medianOf3(_ value: Double) -> Double {
        rawSpeedWindow.append(value)
        if rawSpeedWindow.count > 3 { rawSpeedWindow.removeFirst() }
        return rawSpeedWindow.sorted()[rawSpeedWindow.count / 2]
    }

    private func climbRateFpm(now: Date) -> Double {
        let window = altHistory.filter { now.timeIntervalSince($0.time) <= 14 }
        guard let first = window.first, let last = window.last, window.count >= 2 else { return 0 }
        let dt = last.time.timeIntervalSince(first.time)
        guard dt > 0 else { return 0 }
        return (last.altFt - first.altFt) / dt * 60.0
    }

    private func distanceNm(from location: CLLocation, to airport: Airport) -> Double {
        location.distance(from: CLLocation(latitude: airport.latitude, longitude: airport.longitude)) / nauticalMilesToMeters
    }

    // MARK: - Helpers (barometer fusion)

    /// The vertical reference for the ground-contact and descend/climb tests: baro AGL
    /// (relative altitude re-zeroed at the last detected ground contact) when a fresh
    /// sample exists and a zero is established, bias-corrected GPS AGL otherwise. The
    /// baro is never used as absolute altitude — weather drift makes that meaningless.
    private func effectiveAgl(gpsAgl: Double, now: Date) -> Double {
        if let sample = latestBaroSample, let zero = baroGroundZeroFt,
           now.timeIntervalSince(sample.timestamp) < baroFreshnessSeconds {
            return sample.relativeAltitudeFt - zero
        }
        return gpsAgl
    }

    /// Per-sample vertical delta for the approach flat-pair test. Prefers consecutive baro
    /// samples (±1 ft) over consecutive GPS altitudes; falls back to GPS when either end of
    /// the pair lacks fresh baro.
    private func verticalDelta(altFt: Double, prevAlt: Double?, now: Date) -> Double? {
        if let sample = latestBaroSample, let prevRel = prevBaroRelFt, let prevAt = prevBaroTimestamp,
           now.timeIntervalSince(sample.timestamp) < baroFreshnessSeconds,
           now.timeIntervalSince(prevAt) < 15 {
            return sample.relativeAltitudeFt - prevRel
        }
        guard let prevAlt else { return nil }
        return altFt - prevAlt
    }

    private func trackPrevBaro(now: Date) {
        if let sample = latestBaroSample, now.timeIntervalSince(sample.timestamp) < baroFreshnessSeconds {
            prevBaroRelFt = sample.relativeAltitudeFt
            prevBaroTimestamp = sample.timestamp
        }
    }

    /// Re-zero the relative-baro ground reference at a known ground contact.
    private func zeroBaroReference(now: Date) {
        if let sample = latestBaroSample, now.timeIntervalSince(sample.timestamp) < baroFreshnessSeconds * 2 {
            baroGroundZeroFt = sample.relativeAltitudeFt
        }
    }

    // MARK: - Event Emission

    private func emit(_ kind: FlightEventType, at time: Date) {
        // Manual-event dedupe: an auto event of the same physical class within 60 s of a
        // manual one is the same event.
        let now = clock()
        switch kind {
        case .touchAndGo, .fullStop:
            if let manual = lastManualLandingTime, abs(now.timeIntervalSince(manual)) < manualEventDedupeSeconds {
                AppLog.flightEvents.debugLine("\(kind.rawValue) suppressed (manual landing \(Int(abs(now.timeIntervalSince(manual)))) s ago)")
                return
            }
        case .goAround:
            if let manual = lastManualGoAroundTime, abs(now.timeIntervalSince(manual)) < manualEventDedupeSeconds {
                AppLog.flightEvents.debugLine("Go-around suppressed (manual go-around \(Int(abs(now.timeIntervalSince(manual)))) s ago)")
                return
            }
        }

        emittedEvents.append(EmittedFlightEvent(type: kind, timestamp: time, airportIdent: anchor?.ident))
        onEvent?(kind, time)

        // Per-touch bias refresh: GPS bias drifts 10–20 ft across a session; the flat
        // samples of a confirmed touch are a fresh ground-truth measurement of it.
        if kind != .goAround, flatAltSamples.count >= 2, let anchor {
            let sorted = flatAltSamples.sorted()
            altBiasFt = sorted[sorted.count / 2] - Double(anchor.elevation ?? 0)
        }
        if kind != .goAround {
            zeroBaroReference(now: now)
        }
        flatAltSamples = []

        let airport = anchor
        switch kind {
        case .goAround:
            guard pendingGoAround == nil else { return }
            let message = airport.map { String(localized: "Go-around detected at \($0.name)") }
                ?? String(localized: "Go-around detected")
            pendingGoAround = DetectedFlightEvent(type: .goAround, timestamp: time, airport: airport, message: message)
            AppLog.flightEvents.debugLine("GO-AROUND at \(time) (\(airport?.ident ?? "?"))")
        case .touchAndGo:
            guard pendingTouchAndGo == nil else { return }
            let message = airport.map { String(localized: "Touch-and-go detected at \($0.name)") }
                ?? String(localized: "Touch-and-go detected")
            pendingTouchAndGo = DetectedFlightEvent(type: .touchAndGo, timestamp: time, airport: airport, message: message)
            AppLog.flightEvents.debugLine("TOUCH-AND-GO at \(time) (\(airport?.ident ?? "?"))")
        case .fullStop:
            guard pendingFullStop == nil else { return }
            pendingFullStop = DetectedFlightEvent(type: .fullStop, timestamp: time, airport: airport, message: fullStopMessage(airport: airport))
            AppLog.flightEvents.debugLine("FULL STOP at \(time) (\(airport?.ident ?? "?"))")
        }
    }

    private func fullStopMessage(airport: Airport?) -> String {
        airport.map { String(localized: "Full-stop landing detected at \($0.name)") }
            ?? String(localized: "Full-stop landing detected")
    }
}
