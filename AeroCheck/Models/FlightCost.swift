import Foundation

// MARK: - Flight cost (v5.0.0)
//
// What a flight cost the pilot: the aircraft's hourly rate applied to the hours the club actually
// bills, plus whatever was paid on the ground.
//
// Rates are entered by the pilot, never fetched. Club rates are not published as data anywhere, they
// differ per member category, and the app has no business guessing them. The same goes for landing
// fees: the server publishes WHERE an aerodrome states its tariff (`/api/v3/airfields/tariffs`) and
// the pilot records what they actually paid, because the only automatable fee dataset is
// licence-forbidden and was wrong in seven of eight spot checks.

/// Which measured time the club bills on. Every one of these is already recorded per flight, so the
/// pilot picks the basis once per aircraft and the arithmetic follows.
enum BillingBasis: String, Codable, CaseIterable, Sendable {
    /// Block off to block on. The most common club basis, and what a Swiss tariff usually means.
    case block
    /// Take-off to landing.
    case flight
    /// Hobbs / tachometer difference, when the pilot logged the counter.
    case engineHours

    var label: String {
        switch self {
        case .block:       return L10n.Cost.basisBlock
        case .flight:      return L10n.Cost.basisFlight
        case .engineHours: return L10n.Cost.basisEngineHours
        }
    }
}

/// The pilot's rate for one aircraft, entered once and reused. Keyed by registration where there is
/// one — two tails of the same type routinely bill differently.
struct AircraftRateProfile: Codable, Equatable, Sendable {
    var hourlyRate: Double
    var currency: String
    var basis: BillingBasis

    init(hourlyRate: Double, currency: String = "CHF", basis: BillingBasis = .block) {
        self.hourlyRate = hourlyRate
        self.currency = currency
        self.basis = basis
    }
}

/// One thing paid on the ground.
struct FeeItem: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var label: String
    var amount: Double
    /// Aerodrome it belongs to, when it is a landing or parking fee.
    var icao: String?
}

/// What a flight cost, stored on the flight itself.
///
/// The rate and basis are SNAPSHOT here rather than looked up at display time: a club raising its
/// rate in January must not silently rewrite what last year's flights cost, which is exactly what a
/// live lookup would do to a yearly total.
struct FlightCostEntry: Codable, Equatable, Sendable {
    var currency: String = "CHF"
    var hourlyRate: Double?
    var basis: BillingBasis?
    /// Hours actually billed, snapshot at entry so a later reconciliation cannot move a settled cost.
    var billedHours: Double?
    var fees: [FeeItem] = []
    var note: String?

    var aircraftCost: Double {
        guard let rate = hourlyRate, let hours = billedHours, rate > 0, hours > 0 else { return 0 }
        return rate * hours
    }

    var feesTotal: Double { fees.reduce(0) { $0 + $1.amount } }

    var total: Double { aircraftCost + feesTotal }

    var isEmpty: Bool { hourlyRate == nil && fees.isEmpty && (note?.isEmpty ?? true) }
}

// MARK: - Calculator

enum FlightCostCalculator {

    /// Hours the given basis bills for this flight. Returns nil when the flight never recorded that
    /// basis — a club billing on engine hours cannot be costed from a flight where the pilot skipped
    /// the counter, and inventing a number there would quietly misstate a year's spending.
    static func billableHours(for flight: Flight, basis: BillingBasis) -> Double? {
        switch basis {
        case .block:
            return hours(from: flight.blockTime)
        case .flight:
            return hours(from: flight.flightTime)
        case .engineHours:
            guard let engineHours = flight.engineHoursFlown, engineHours > 0 else { return nil }
            return engineHours
        }
    }

    private static func hours(from interval: TimeInterval?) -> Double? {
        guard let interval, interval > 0 else { return nil }
        return interval / 3600.0
    }

    /// Build a cost entry for a flight from the aircraft's rate profile, leaving fees to the pilot.
    static func makeEntry(for flight: Flight, profile: AircraftRateProfile?) -> FlightCostEntry {
        guard let profile else { return FlightCostEntry() }
        var entry = FlightCostEntry()
        entry.currency = profile.currency
        entry.hourlyRate = profile.hourlyRate
        entry.basis = profile.basis
        entry.billedHours = billableHours(for: flight, basis: profile.basis)
        return entry
    }

    /// Key a rate profile is stored under: the registration when known, else the aircraft type.
    /// Two tails of the same type routinely bill differently, so the registration wins.
    static func profileKey(for flight: Flight) -> String? {
        if let registration = flight.aircraftRegistration, !registration.isEmpty { return registration }
        if let type = flight.aircraftType, !type.isEmpty { return type }
        return nil
    }

    /// Rounded to whole currency units for display. Club invoices are in francs, not centimes, and a
    /// figure like "CHF 464.83" implies a precision an estimate does not have.
    static func formatAmount(_ amount: Double, currency: String) -> String {
        "\(currency) \(Int(amount.rounded()))"
    }
}

// MARK: - Ledger

/// A period's spend, for the Flight Log dashboard.
struct CostLedgerSummary: Equatable, Sendable {
    var currency: String
    var aircraftCost: Double
    var fees: Double
    var flightsWithCost: Int
    var flightsMissingCost: Int

    var total: Double { aircraftCost + fees }
}

enum CostLedger {

    /// Total what is recorded, and say how many flights have nothing recorded.
    ///
    /// The second number is the honest half: a yearly total built from three of forty flights is
    /// not a yearly total, and a dashboard that shows only the sum invites reading it as one.
    /// Mixed currencies are reported under the most common one rather than silently added — this is
    /// a personal ledger, not an accounting package, but adding francs to euros is still wrong.
    static func summarize(flights: [Flight], fallbackCurrency: String = "CHF") -> CostLedgerSummary {
        let entries = flights.compactMap { $0.costEntry }.filter { !$0.isEmpty }
        guard !entries.isEmpty else {
            return CostLedgerSummary(currency: fallbackCurrency, aircraftCost: 0, fees: 0,
                                     flightsWithCost: 0, flightsMissingCost: flights.count)
        }

        var counts: [String: Int] = [:]
        for entry in entries { counts[entry.currency, default: 0] += 1 }
        let currency = counts.max { a, b in
            a.value == b.value ? a.key > b.key : a.value < b.value
        }?.key ?? fallbackCurrency

        let matching = entries.filter { $0.currency == currency }
        return CostLedgerSummary(
            currency: currency,
            aircraftCost: matching.reduce(0) { $0 + $1.aircraftCost },
            fees: matching.reduce(0) { $0 + $1.feesTotal },
            flightsWithCost: matching.count,
            flightsMissingCost: flights.count - matching.count
        )
    }
}
