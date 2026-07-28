import Foundation
import CoreLocation

/// A surface wind for a departure or approach briefing, and where it came from.
///
/// Three sources of quite different authority feed this, so provenance travels WITH the value
/// rather than being reconstructed at the display site — a model figure must never be able to
/// reach the screen looking like an observation.
struct BriefingWind: Equatable {

    enum Source: Equatable {
        /// An aerodrome observation. The strongest source: measured, at an airfield, in aviation
        /// conventions, and the thing a pilot would read anyway.
        case metar(icao: String)
        /// A MeteoSwiss ground station. Also measured, and far denser than the METAR network over
        /// Switzerland (155 stations vs a handful), so it wins when it is genuinely closer.
        case meteoSwiss(station: String)
        /// Open-Meteo's 10 m model wind. NOT measured. Last resort, and labelled as such.
        case model

        var isObservation: Bool {
            switch self {
            case .metar, .meteoSwiss: return true
            case .model: return false
            }
        }
    }

    /// Nil means the report said VRB — direction is genuinely undefined, not missing. Never
    /// substitute a heading here; that is the whole reason this is optional.
    let directionDeg: Int?
    let speedKt: Int
    let gustKt: Int?
    let source: Source
    /// Distance from the aircraft to the reporting station. Nil for the model, which has no station.
    let distanceNm: Double?
    let observedAt: Date?

    var isVariable: Bool { directionDeg == nil }

    /// The wind itself, which is what the pilot is actually reading.
    /// `"240° 8 kt"`, `"VRB 3 kt"`, `"270° 15 kt G25"`.
    var value: String {
        let dir = directionDeg.map { String(format: "%03d°", $0) } ?? "VRB"
        var text = "\(dir) \(speedKt) kt"
        if let gustKt { text += " G\(gustKt)" }
        return text
    }

    /// Where it came from, for the parenthetical. Deliberately terse: this is the qualifier, not
    /// the message.
    var provenance: String {
        let distance = distanceNm.map { String(format: "%.0f nm", $0) }
        switch source {
        case .metar(let icao):
            return [.some("METAR \(icao)"), distance].compactMap { $0 }.joined(separator: ", ")
        case .meteoSwiss(let station):
            return [.some(station), distance].compactMap { $0 }.joined(separator: ", ")
        case .model:
            return L10n.Briefing.windModelForecast
        }
    }

    /// Value first, provenance last — the pilot reads the wind, then decides how much to trust it.
    /// `"240° 8 kt (METAR LSGG, 21 nm)"`.
    var display: String { "\(value) (\(provenance))" }
}

/// Chooses the briefing wind from whatever sources happen to be available.
///
/// Written as a pure rule over already-fetched candidates, with no networking and no clock, because
/// this decides which of three differently-trustworthy numbers a pilot is shown before a departure
/// or an approach. It is the kind of logic that should fail in a test rather than in a cockpit.
enum BriefingWindLadder {

    /// A METAR further than this is describing different air. Generous, because aerodromes are
    /// sparse and a 40 nm report still beats a model cell.
    static let maxMetarDistanceNm: Double = 60

    /// MeteoSwiss stations are dense, so the bar for "this describes your air" is tighter.
    static let maxStationDistanceKm: Double = 30

    /// Terrain, not distance, is what makes a nearby reading wrong in the Alps: a valley station
    /// and a ridge station 5 km apart report different winds. Applied to both measured sources.
    static let maxAltitudeDeltaM: Double = 500

    /// A candidate observation from the aviation weather proxy.
    struct MetarCandidate: Equatable {
        let icao: String
        let distanceNm: Double
        let elevationM: Double?
        let directionDeg: Int?
        let isVariable: Bool
        let speedKt: Int?
        let gustKt: Int?
        let observedAt: Date?
    }

    /// The model fallback.
    struct ModelCandidate: Equatable {
        let directionDeg: Int
        let speedKt: Int
        let gustKt: Int?
        let validAt: Date?
    }

    /// Pick the best available wind.
    ///
    /// - Parameters:
    ///   - metars: observations sorted by distance (the proxy already sorts; not relied upon).
    ///   - station: the MeteoSwiss reading, when one was fetched.
    ///   - model: Open-Meteo's surface wind, when the winds-aloft call returned one.
    ///   - aircraftAltitudeM: used to reject a reading taken at a very different elevation.
    static func select(
        metars: [MetarCandidate],
        station: WindData?,
        model: ModelCandidate?,
        aircraftAltitudeM: Double?
    ) -> BriefingWind? {

        // 1 — METAR. Nearest first, but only among reports that are close enough, plausibly at the
        // same elevation, and actually carry a wind. A report present but wind-less is skipped
        // rather than shown as calm.
        let usableMetars = metars
            .filter { $0.speedKt != nil }
            .filter { $0.distanceNm <= maxMetarDistanceNm }
            .filter { altitudeIsPlausible(readingM: $0.elevationM, aircraftM: aircraftAltitudeM) }
            .sorted { $0.distanceNm < $1.distanceNm }

        if let best = usableMetars.first, let speedKt = best.speedKt {
            return BriefingWind(
                directionDeg: best.isVariable ? nil : best.directionDeg,
                speedKt: speedKt,
                gustKt: best.gustKt,
                source: .metar(icao: best.icao),
                distanceNm: best.distanceNm,
                observedAt: best.observedAt
            )
        }

        // 2 — MeteoSwiss. Denser than the METAR network over Switzerland, so it is a genuine
        // second rung rather than a formality: in the Alps the nearest station is routinely closer
        // and better matched than the nearest aerodrome.
        if let station,
           station.distanceMeters <= maxStationDistanceKm * 1000,
           altitudeIsPlausible(readingM: station.stationAltitudeMeters, aircraftM: aircraftAltitudeM) {
            return BriefingWind(
                directionDeg: Int(station.directionDegrees.rounded()),
                speedKt: Int(station.speedKnots.rounded()),
                gustKt: nil,
                source: .meteoSwiss(station: station.stationName),
                distanceNm: station.distanceMeters / 1852.0,
                observedAt: station.timestamp
            )
        }

        // 3 — Model. Always last, always labelled, and never gated on distance because a grid cell
        // has no station to be far from.
        if let model {
            return BriefingWind(
                directionDeg: model.directionDeg,
                speedKt: model.speedKt,
                gustKt: model.gustKt,
                source: .model,
                distanceNm: nil,
                observedAt: model.validAt
            )
        }

        // 4 — Nothing usable. Returning nil rather than a placeholder is the point: the briefing
        // shows no wind, which is honest, instead of a fabricated calm.
        return nil
    }

    /// Unknown elevation on either side passes: a missing figure is not evidence of a mismatch, and
    /// rejecting on it would discard good observations at fields the database has no elevation for.
    static func altitudeIsPlausible(readingM: Double?, aircraftM: Double?) -> Bool {
        guard let readingM, let aircraftM else { return true }
        return abs(readingM - aircraftM) <= maxAltitudeDeltaM
    }
}
