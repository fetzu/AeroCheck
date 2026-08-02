import Foundation
import CoreMotion

/// Thin wrapper around `CMAltimeter` providing median-filtered RELATIVE barometric
/// altitude at the sensor's native ~1 Hz cadence.
///
/// The barometer is two orders of magnitude better than GPS vertically (±0.3 m at 1 Hz vs
/// ±10–30 ft at 5–12 s), which is what makes wheel-contact plateaus and go-around
/// descend/climb profiles unambiguous to the flight-event detector. Two hard constraints,
/// both from the 53-flight validation (see FlightEventDetector):
/// - **Relative only.** Weather drift is ~1 hPa/h ≈ 28 ft/h, so the absolute value is
///   meaningless. The detector re-zeroes the reference at every detected ground contact;
///   this service never converts to MSL.
/// - **3 s median filter.** Cabin pressure transients (vents, doors, prop wash) add
///   ±10–20 ft spikes that a median absorbs without smearing a real touchdown step.
///
/// Delivery continues in the background while the app's background *location* session is
/// active (CoreMotion piggybacks on the location background mode); `LocationManager`
/// starts/stops this service with GPS tracking, so no extra background mode is needed.
/// On devices without a barometer (and on the simulator) the service is inert:
/// `isAvailable` is false, `start()` is a no-op, and `currentSample` stays nil — the
/// detector then runs GPS-only, exactly as validated.
@MainActor
final class BarometricAltitudeService {
    /// Whether this device has a barometer (false on the simulator).
    static var isAvailable: Bool { CMAltimeter.isRelativeAltitudeAvailable() }

    /// Latest median-filtered sample (feet, relative to the CMAltimeter session datum).
    private(set) var currentSample: BaroAltitudeSample?

    /// Latest RAW relative altitude in meters, for recording on `GPSPoint.baroAltitude`.
    /// Raw (not median-filtered) so the recorded track keeps full sensor fidelity for the
    /// post-flight reconciliation pass and future re-validation.
    private(set) var rawRelativeAltitudeM: Double?

    private(set) var isActive = false

    private let altimeter = CMAltimeter()
    /// Raw samples inside the median window: (relative altitude ft, timestamp).
    private var window: [(ft: Double, at: Date)] = []
    private let medianWindowSeconds: TimeInterval = 3.0
    private let metersToFeet = 3.28084

    func start() {
        guard !isActive, Self.isAvailable else { return }
        isActive = true
        window = []
        rawRelativeAltitudeM = nil
        currentSample = nil
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, error in
            guard let self, let data else {
                if let error {
                    AppLog.flightEvents.debugLine("Barometer error: \(error.localizedDescription)")
                }
                return
            }
            MainActor.assumeIsolated {
                self.ingest(relativeAltitudeM: data.relativeAltitude.doubleValue)
            }
        }
        AppLog.flightEvents.debugLine("Barometer started (relative altitude, 3 s median)")
    }

    func stop() {
        guard isActive else { return }
        altimeter.stopRelativeAltitudeUpdates()
        isActive = false
        window = []
        currentSample = nil
        rawRelativeAltitudeM = nil
        AppLog.flightEvents.debugLine("Barometer stopped")
    }

    /// Test seam: inject a sample as if delivered by CMAltimeter.
    func ingest(relativeAltitudeM: Double, at time: Date = Date()) {
        rawRelativeAltitudeM = relativeAltitudeM
        let ft = relativeAltitudeM * metersToFeet
        window.append((ft, time))
        window.removeAll { time.timeIntervalSince($0.at) > medianWindowSeconds }
        guard !window.isEmpty else { return }
        let sorted = window.map(\.ft).sorted()
        currentSample = BaroAltitudeSample(relativeAltitudeFt: sorted[sorted.count / 2], timestamp: time)
    }
}
