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

/// How a fee was settled. (6.11.0, the author's f2)
enum FeeStatus: String, CaseIterable, Sendable {
    /// Paid, at the desk or later.
    case paid
    /// The invoice hasn't come yet. The close-out counts it as dealt with; the ledger lists it as
    /// open until it is marked paid. (f3)
    case invoice
    /// It goes on the club's bill.
    case club
    /// Nothing to pay.
    case none
}

/// One thing paid on the ground, or still to pay.
///
/// A landing fee's line carries its aerodrome, how it was settled and, when the pilot knows it, the
/// amount. No amount ever comes from the app or the server: every figure is the pilot's.
struct FeeItem: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var label: String
    /// 0 when no amount was entered: see `hasAmount`.
    var amount: Double
    /// Aerodrome it belongs to, when it is a landing or parking fee.
    var icao: String?

    // 6.11.0. All optional: a line written by an older build has none of them. A flight that
    // carries any of them is stamped with record version 3 (`Flight.stampForContent`).

    /// How it was settled, as text, so a word a later build adds still decodes here.
    var statusRaw: String?
    /// The fee's own currency, when it isn't the flight's. Never converted. (f6)
    var currency: String?
    /// The landings the app counted at that aerodrome on this flight. (f4)
    var landings: Int?
    /// False when the pilot gave an answer without an amount ("Invoice to come" before it comes).
    /// Nil on a line written before 6.11.0, which always had an amount.
    var hasAmount: Bool?
    /// When the answer was given.
    var settledAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id, label, amount, icao, currency, landings, hasAmount, settledAt
        case statusRaw = "status"
    }

    var status: FeeStatus? {
        get { statusRaw.flatMap(FeeStatus.init(rawValue:)) }
        set { statusRaw = newValue?.rawValue }
    }

    /// Whether the line has anything an older build would drop.
    var carriesAnswer: Bool {
        statusRaw != nil || currency != nil || landings != nil || hasAmount != nil || settledAt != nil
    }

    /// Whether its amount is money spent or owed: a line with an amount, paid or to be invoiced, or
    /// a line of an older build. A fee on the club's bill or waived adds nothing here.
    var countsInTotals: Bool {
        guard hasAmount ?? true, amount.isFinite, amount > 0 else { return false }
        switch status {
        case nil, .paid, .invoice: return true
        case .club, .some(.none): return false
        }
    }

    var isInvoiceToCome: Bool { status == .invoice }
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

    /// The currency a fee is in: its own, else the flight's.
    func currency(of fee: FeeItem) -> String { fee.currency ?? currency }

    /// The fees in the flight's own currency. A fee in another currency is never added to it
    /// (`totalsByCurrency` has every currency side by side). (6.11.0, f6)
    var feesTotal: Double {
        fees.filter { $0.countsInTotals && currency(of: $0) == currency }.reduce(0) { $0 + $1.amount }
    }

    var total: Double { aircraftCost + feesTotal }

    /// What the flight cost, per currency: the aircraft in the flight's currency, each fee in its
    /// own. Never converted.
    var totalsByCurrency: [String: Double] {
        var totals: [String: Double] = [:]
        if aircraftCost > 0 { totals[currency, default: 0] += aircraftCost }
        for fee in fees where fee.countsInTotals {
            totals[currency(of: fee), default: 0] += fee.amount
        }
        return totals
    }

    /// Whether any fee carries what an older build would drop.
    var carriesFeeAnswers: Bool { fees.contains { $0.carriesAnswer } }

    /// The landing fee's line of an aerodrome, when the flight has one.
    func feeLine(for icao: String) -> FeeItem? {
        fees.first { $0.icao?.uppercased() == icao.uppercased() }
    }

    /// Records how the fee at an aerodrome was settled, on its line (made if there is none). A nil
    /// amount keeps the answer without a figure.
    mutating func settleFee(at icao: String, label: String, status: FeeStatus, amount: Double?,
                            currency feeCurrency: String?, landings: Int?, at date: Date) {
        var line = feeLine(for: icao) ?? FeeItem(label: label, amount: 0, icao: icao.uppercased())
        line.status = status
        let entered = amount.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        line.amount = entered ?? 0
        line.hasAmount = entered != nil
        line.currency = (feeCurrency == nil || feeCurrency == currency) ? nil : feeCurrency
        if let landings { line.landings = landings }
        line.settledAt = date
        if let index = fees.firstIndex(where: { $0.id == line.id }) { fees[index] = line } else { fees.append(line) }
    }

    /// Whether this entry contributes nothing at all.
    ///
    /// `hasCost` rather than `hourlyRate != nil`: `aircraftCost` also needs `billedHours`, which is
    /// nil whenever the basis was never recorded (a club billing on engine hours, and a pilot who
    /// never logs the counter). An entry with a rate and no hours passed `!isEmpty`, counted as a
    /// flight WITH a cost, and contributed 0 — so the dashboard read "LEDGER CHF 0" over twenty
    /// priced flights with no "N without cost" caveat, because the very guard that would have
    /// raised one was satisfied. (review F-cost-4)
    var isEmpty: Bool { !hasCost && (note?.isEmpty ?? true) }

    /// True when this entry actually produces money.
    var hasCost: Bool { aircraftCost > 0 || !fees.isEmpty }
}

// MARK: - Calculator

enum FlightCostCalculator {

    /// Hours the given basis bills for this flight. Returns nil when the flight never recorded that
    /// basis — a club billing on engine hours cannot be costed from a flight where the pilot skipped
    /// the counter, and inventing a number there would quietly misstate a year's spending.
    static func billableHours(for flight: Flight, basis: BillingBasis) -> Double? {
        switch basis {
        // The logged minutes, not the exact seconds: the bill and the logbook line are read side by
        // side, and 0:31 in one must not be 0:30 in the other. (v5.2)
        case .block:
            return hours(fromMinutes: flight.blockMinutes)
        case .flight:
            return hours(fromMinutes: flight.flightMinutes)
        case .engineHours:
            guard let engineHours = flight.engineHoursFlown, engineHours > 0 else { return nil }
            return engineHours
        }
    }

    private static func hours(fromMinutes minutes: Int?) -> Double? {
        guard let minutes, minutes > 0 else { return nil }
        return Double(minutes) / 60.0
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

    /// Totals in several currencies, side by side and never added: "CHF 395 + EUR 18", the flight's
    /// own currency first, the others in alphabetical order. (6.11.0, f6)
    static func formatTotals(_ totals: [String: Double], first: String) -> String {
        let order = totals.keys.sorted { a, b in
            if (a == first) != (b == first) { return a == first }
            return a < b
        }
        guard !order.isEmpty else { return formatAmount(0, currency: first) }
        return order.map { formatAmount(totals[$0] ?? 0, currency: $0) }.joined(separator: " + ")
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
    /// Every currency of the period, side by side: the aircraft and the fees of each. (6.11.0)
    var totalsByCurrency: [String: Double] = [:]
    /// The fees whose invoice hasn't come yet, oldest first. (6.11.0, f3)
    var invoicesToCome: [CostLedger.OpenInvoice] = []

    var total: Double { aircraftCost + fees }
}

enum CostLedger {

    /// A fee the pilot is still waiting to be invoiced for.
    struct OpenInvoice: Equatable, Sendable {
        var flightId: UUID
        var date: Date?
        var icao: String?
        var label: String
        /// Nil when no amount is known yet.
        var amount: Double?
        var currency: String
    }

    /// Total what is recorded, and say how many flights have nothing recorded.
    ///
    /// The second number is the honest half: a yearly total built from three of forty flights is
    /// not a yearly total, and a dashboard that shows only the sum invites reading it as one.
    /// Mixed currencies are reported under the most common one rather than silently added — this is
    /// a personal ledger, not an accounting package, but adding francs to euros is still wrong.
    /// `rates` lets a flight with no stored `costEntry` still be costed from its aircraft's rate
    /// profile — which is exactly what the per-flight screen already does. Without it the two
    /// disagreed: every flight showed a full cost on its own numbers sheet while the ledger counted
    /// it as having none, so the dashboard read "CHF 420" beside "11 flights without cost" for
    /// twelve identically-priced flights. `costEntry` is only ever written for the flight the pilot
    /// happened to open, so it can never be the whole picture on its own. (review F-cost-3)
    static func summarize(flights: [Flight],
                          rates: [String: AircraftRateProfile] = [:],
                          fallbackCurrency: String = "CHF") -> CostLedgerSummary {
        var totalsByCurrency: [String: Double] = [:]
        var invoices: [OpenInvoice] = []
        let entries = flights.compactMap { flight -> FlightCostEntry? in
            let entry: FlightCostEntry?
            if let stored = flight.costEntry, !stored.isEmpty {
                entry = stored
            } else if flight.costEntry != nil {
                // A stored entry wins even when empty — the pilot may have deliberately cleared it.
                entry = nil
            } else if let key = FlightCostCalculator.profileKey(for: flight), let profile = rates[key] {
                let derived = FlightCostCalculator.makeEntry(for: flight, profile: profile)
                entry = derived.isEmpty ? nil : derived
            } else {
                entry = nil
            }
            guard let entry else { return nil }
            for (currency, amount) in entry.totalsByCurrency { totalsByCurrency[currency, default: 0] += amount }
            for fee in entry.fees where fee.isInvoiceToCome {
                invoices.append(OpenInvoice(flightId: flight.id, date: flight.startTime, icao: fee.icao,
                                            label: fee.label,
                                            amount: (fee.hasAmount ?? true) ? fee.amount : nil,
                                            currency: entry.currency(of: fee)))
            }
            return entry
        }
        invoices.sort { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
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
            flightsMissingCost: flights.count - matching.count,
            totalsByCurrency: totalsByCurrency,
            invoicesToCome: invoices
        )
    }
}

// MARK: - Landing fee lines (6.11.0)

/// Where a flight landed, and how often: what its landing fee lines are made from.
///
/// One line per aerodrome landed at other than the one the flight left from, with the number of
/// landings the app counted there (the author's f4 and f5). The landings are placed from the
/// flight's own track, so a touch-and-go at another field and back in one flight gets its line.
enum LandingFeeLines {

    struct Visit: Equatable, Sendable {
        var icao: String
        var landings: Int
    }

    /// Two logged landings closer than this are one touchdown (as `Flight.landingCounts` counts).
    private static let sameLanding: TimeInterval = 30
    /// A track point further than this from a landing's time says nothing about where it was.
    private static let trackReach: TimeInterval = 120

    /// The aerodromes the flight landed at, in the order of their first landing, without the one it
    /// left from. `nearestAerodrome` gives the ICAO code of the field at a position, or nil.
    ///
    /// A flight with no usable track falls back to its arrival field, as before 6.11.0.
    static func visits(for flight: Flight,
                       nearestAerodrome: (_ latitude: Double, _ longitude: Double) -> String?) -> [Visit] {
        let departure = flight.departureAirportIdent?.uppercased()
        var times: [Date] = []
        for time in (flight.touchAndGoTimes + flight.fullStopTimes).sorted() {
            if let last = times.last, time.timeIntervalSince(last) < sameLanding { continue }
            times.append(time)
        }

        var order: [String] = []
        var counts: [String: Int] = [:]
        let track = flight.gpsTrack
        for time in times {
            guard let point = track.min(by: {
                abs($0.timestamp.timeIntervalSince(time)) < abs($1.timestamp.timeIntervalSince(time))
            }), abs(point.timestamp.timeIntervalSince(time)) <= trackReach,
                  let icao = nearestAerodrome(point.latitude, point.longitude)?.uppercased() else { continue }
            if counts[icao] == nil { order.append(icao) }
            counts[icao, default: 0] += 1
        }

        if order.isEmpty, let arrival = flight.arrivalAirportIdent?.uppercased(), !arrival.isEmpty {
            // No landing could be placed: the arrival field, once, as before.
            order = [arrival]
            counts[arrival] = 1
        }
        return order.filter { $0 != departure }.map { Visit(icao: $0, landings: counts[$0] ?? 1) }
    }

    /// The currency a fee at an aerodrome most likely is in, from its country; nil where the app
    /// would be guessing. It is only the start value of the line: the pilot can change it.
    static func currency(forCountry isoCountry: String?) -> String? {
        guard let country = isoCountry?.uppercased() else { return nil }
        if euroCountries.contains(country) { return "EUR" }
        return otherCurrencies[country]
    }

    private static let euroCountries: Set<String> = [
        "AT", "BE", "BG", "CY", "DE", "EE", "ES", "FI", "FR", "GR", "HR", "IE", "IT", "LT", "LU", "LV", "MT", "NL",
        "PT", "SI", "SK", "MC", "SM", "AD"
    ]

    private static let otherCurrencies: [String: String] = [
        "CH": "CHF", "LI": "CHF", "GB": "GBP", "IM": "GBP", "JE": "GBP", "GG": "GBP", "CZ": "CZK", "PL": "PLN",
        "HU": "HUF", "RO": "RON", "SE": "SEK", "DK": "DKK", "NO": "NOK", "IS": "ISK", "US": "USD"
    ]
}
