import Foundation

// MARK: - What the app keeps per aircraft for mass and balance (6.11.0)
//
// The data itself comes from the server, per registration (`AircraftMassBalance`). What is kept here
// is the pilot's side of it: that they compared the data with the aircraft's own handbook and
// confirmed it, a newer line of the record they typed, their own figures for an aircraft the server
// has no data for, and the last load, so a routine flight starts filled.
//
// Nothing here turns into "inside limits" by itself. A confirmation holds for one revision of the
// data and for twelve months; a new revision, or a year, asks again.

/// The pilot's side of one registration's mass and balance.
struct MassBalanceSetup: Equatable, Sendable {
    /// The revision of the server's data the pilot confirmed against the handbook. Nil: not confirmed.
    var confirmedRevision: Int?
    var confirmedAt: Date?
    /// The pilot said the server's data is not this aircraft's ("something differs"): it is not used.
    var declinedRevision: Int?
    /// The empty aircraft from a line of the record newer than the server's, typed by the pilot.
    var ownEmpty: AircraftMassBalance.EmptyMass?
    /// The pilot's own figures, for an aircraft with no data from the server or with data declined.
    var ownData: AircraftMassBalance?
    /// When the pilot last said their own figures are the aircraft's.
    var ownConfirmedAt: Date?
    /// The load of the last flight prepared, and its day.
    var lastLoad: MassBalanceLoad?
    var lastLoadDay: Date?

    init(confirmedRevision: Int? = nil, confirmedAt: Date? = nil, declinedRevision: Int? = nil,
         ownEmpty: AircraftMassBalance.EmptyMass? = nil, ownData: AircraftMassBalance? = nil,
         ownConfirmedAt: Date? = nil, lastLoad: MassBalanceLoad? = nil, lastLoadDay: Date? = nil) {
        self.confirmedRevision = confirmedRevision
        self.confirmedAt = confirmedAt
        self.declinedRevision = declinedRevision
        self.ownEmpty = ownEmpty
        self.ownData = ownData
        self.ownConfirmedAt = ownConfirmedAt
        self.lastLoad = lastLoad
        self.lastLoadDay = lastLoadDay
    }

    /// A confirmation is asked again after this long (the author's r3): the aircraft may have had work
    /// done that nobody reported.
    static let confirmationLifetime: TimeInterval = 365 * 24 * 3600
}

extension MassBalanceSetup: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        confirmedRevision = try c.decodeIfPresent(Int.self, forKey: .confirmedRevision)
        confirmedAt = try c.decodeIfPresent(Date.self, forKey: .confirmedAt)
        declinedRevision = try c.decodeIfPresent(Int.self, forKey: .declinedRevision)
        // A stored figure this build can't read (a unit a later build added, say) is dropped, not
        // allowed to take the whole settings record down.
        ownEmpty = try? c.decodeIfPresent(AircraftMassBalance.EmptyMass.self, forKey: .ownEmpty)
        ownData = try? c.decodeIfPresent(AircraftMassBalance.self, forKey: .ownData)
        ownConfirmedAt = try c.decodeIfPresent(Date.self, forKey: .ownConfirmedAt)
        lastLoad = try? c.decodeIfPresent(MassBalanceLoad.self, forKey: .lastLoad)
        lastLoadDay = try c.decodeIfPresent(Date.self, forKey: .lastLoadDay)
    }
}

/// Everything mass and balance keeps in the settings: one protected field for older builds.
struct MassBalanceSettings: Equatable, Sendable {
    /// By registration, upper case.
    var setups: [String: MassBalanceSetup] = [:]
    /// The pilot's own mass with what they carry, in kg: the start value of the pilot's seat.
    var pilotMassKg: Double?

    init(setups: [String: MassBalanceSetup] = [:], pilotMassKg: Double? = nil) {
        self.setups = setups
        self.pilotMassKg = pilotMassKg
    }

    static func key(for registration: String) -> String {
        registration.trimmingCharacters(in: .whitespaces).uppercased()
    }

    subscript(registration: String) -> MassBalanceSetup {
        get { setups[Self.key(for: registration)] ?? MassBalanceSetup() }
        set { setups[Self.key(for: registration)] = newValue }
    }
}

extension MassBalanceSettings: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        setups = try c.decodeIfPresent([String: MassBalanceSetup].self, forKey: .setups) ?? [:]
        pilotMassKg = try c.decodeIfPresent(Double.self, forKey: .pilotMassKg)
    }
}

// MARK: - What the sheet computes with

/// The data, the empty mass and the confirmation the sheet uses for one registration, resolved from
/// the server's file and the pilot's side.
struct MassBalanceBasis: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        /// The server's file for this registration.
        case shipped
        /// The pilot's own figures.
        case pilot
    }

    var data: AircraftMassBalance
    var source: Source
    /// Nil when no empty mass is known: nothing is computed then.
    var empty: AircraftMassBalance.EmptyMass?
    /// Whether the empty mass is the pilot's own line of the record rather than the data's.
    var emptyIsPilots: Bool
    var isConfirmed: Bool
    /// Why it is not confirmed, when it isn't.
    var unconfirmed: Unconfirmed?

    enum Unconfirmed: Equatable, Sendable {
        /// Never confirmed for this aircraft.
        case never
        /// The data changed since the confirmation.
        case dataChanged
        /// The confirmation is older than twelve months.
        case yearPassed
    }
}

extension MassBalanceSetup {

    /// What the sheet computes with, or nil when there is neither data from the server nor the pilot's
    /// own figures: the first-time steps then ask for them.
    func basis(shipped: AircraftMassBalance?, now: Date) -> MassBalanceBasis? {
        if let shipped, declinedRevision != shipped.revision {
            // The newer line of the record wins, whoever holds it. Dates are `YYYY-MM-DD`: they sort as text.
            var empty = shipped.empty
            var pilots = false
            if let ownEmpty, ownEmpty.date > (shipped.empty?.date ?? "") {
                empty = ownEmpty
                pilots = true
            }
            let why: MassBalanceBasis.Unconfirmed?
            if confirmedRevision == nil || confirmedAt == nil { why = .never }
            else if confirmedRevision != shipped.revision { why = .dataChanged }
            else if let confirmedAt, now.timeIntervalSince(confirmedAt) > Self.confirmationLifetime { why = .yearPassed }
            else { why = nil }
            return MassBalanceBasis(data: shipped, source: .shipped, empty: empty, emptyIsPilots: pilots,
                                    isConfirmed: why == nil, unconfirmed: why)
        }
        guard let ownData, ownData.isUsable else { return nil }
        let why: MassBalanceBasis.Unconfirmed?
        if let ownConfirmedAt {
            why = now.timeIntervalSince(ownConfirmedAt) > Self.confirmationLifetime ? .yearPassed : nil
        } else {
            why = .never
        }
        return MassBalanceBasis(data: ownData, source: .pilot, empty: ownEmpty ?? ownData.empty,
                                emptyIsPilots: true, isConfirmed: why == nil, unconfirmed: why)
    }

    /// The pilot compared the server's data with the handbook and the record, and it matches.
    mutating func confirm(revision: Int, at date: Date) {
        confirmedRevision = revision
        confirmedAt = date
        declinedRevision = nil
    }

    /// "Something differs": this revision of the server's data is not used for this aircraft. A later
    /// revision is offered again.
    mutating func decline(revision: Int) {
        declinedRevision = revision
        confirmedRevision = nil
        confirmedAt = nil
    }

    /// The load a sheet starts with: today's as it was left, an earlier day's marked as not
    /// today's, and none when nothing was ever entered.
    func startingLoad(on day: Date = Date(), calendar: Calendar = .current) -> MassBalanceLoad? {
        // A sheet opened and left blank is no load: the next one starts from nothing, and is today's.
        guard let lastLoad, let lastLoadDay, !lastLoad.isBlank else { return nil }
        // The same day, the sheet is as it was left. From an earlier day it is last time's load,
        // and nothing better than that until the pilot says it is today's.
        return calendar.isDate(lastLoadDay, inSameDayAs: day) ? lastLoad : lastLoad.carriedOver(from: lastLoadDay)
    }
}
