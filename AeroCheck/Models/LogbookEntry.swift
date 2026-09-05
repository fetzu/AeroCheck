import Foundation

// MARK: - Logbook line (v5.0.0)
//
// Drafts the line an EASA Part-FCL logbook wants for a flight the app already recorded, per
// AMC1 FCL.050. It is a PREVIEW, not a logbook: capzlog and FOCA's own dLogbook are the two
// FCL.050-certified products in Switzerland, and the useful thing this app can do is fill in the
// columns it genuinely knows and hand them over, rather than pretend to be a system of record.
//
// What is derived, and what is not, matters here. Dates, places, block times and landings come
// from the recorded flight and are as good as the tracking. Function time is a JUDGEMENT — the app
// cannot know whether a flight was PIC or dual — so it is defaulted from a signal (the flight
// plan's instructor field) and left editable. Night time is not computed at all: EASA night runs
// from the end of evening civil twilight to the beginning of morning civil twilight, and a plausible
// wrong number in a logbook column is worse than an empty one the pilot fills in.

/// The pilot's role, i.e. AMC1 FCL.050's "pilot function time" group.
enum LogbookFunction: String, Codable, CaseIterable, Sendable {
    case pic
    case dual
    case coPilot
    case instructor
}

/// The pilot's edits to the derived line. Everything is optional: absent means "use what the flight
/// says", so a line stays correct if the underlying flight is later reconciled.
struct LogbookOverrides: Codable, Equatable, Sendable {
    var picName: String?
    var function: LogbookFunction?
    /// Minutes flown at night, entered by the pilot. Deliberately not computed — see the note above.
    var nightMinutes: Int?
    /// Minutes under IFR, entered by the pilot.
    var ifrMinutes: Int?
    var remarks: String?

    var isEmpty: Bool {
        picName == nil && function == nil && nightMinutes == nil && ifrMinutes == nil
            && (remarks?.isEmpty ?? true)
    }
}

/// One rendered logbook line. Values are strings because this exists to be read, copied and pasted
/// into a logbook — the arithmetic has already happened.
struct LogbookLine: Equatable, Sendable {
    var date: String
    var departurePlace: String
    var departureTimeUTC: String
    var arrivalPlace: String
    var arrivalTimeUTC: String
    var aircraftModel: String
    var aircraftRegistration: String
    var singlePilotTime: String
    var totalTime: String
    var picName: String
    var landingsDay: Int
    var landingsNight: Int
    var nightTime: String
    var ifrTime: String
    var functionLabel: String
    var functionTime: String
    var remarks: String

    /// Column order as AMC1 FCL.050 lists them, for CSV export and the copied text.
    static let csvHeader = [
        "Date", "Departure", "Dep time (UTC)", "Arrival", "Arr time (UTC)",
        "Aircraft model", "Registration", "SE time", "Total time", "PIC name",
        "Ldg day", "Ldg night", "Night", "IFR", "Function", "Function time", "Remarks",
    ]

    var csvRow: [String] {
        [
            date, departurePlace, departureTimeUTC, arrivalPlace, arrivalTimeUTC,
            aircraftModel, aircraftRegistration, singlePilotTime, totalTime, picName,
            String(landingsDay), String(landingsNight), nightTime, ifrTime,
            functionLabel, functionTime, remarks,
        ]
    }
}

// MARK: - Builder

/// Turns a recorded flight into a logbook line. Pure and testable: everything it needs arrives as a
/// parameter, so there is no clock, no locale surprise and no service.
enum LogbookLineBuilder {

    /// `defaultPilotName` is the pilot's own name from settings; EASA wants the PIC named, and
    /// "SELF" is the accepted convention when that is the person writing the logbook.
    static func build(
        flight: Flight,
        overrides: LogbookOverrides? = nil,
        defaultPilotName: String? = nil
    ) -> LogbookLine {
        let blockOff = flight.blockOffTime ?? flight.engineStartTime ?? flight.startTime
        let blockOn = flight.blockOnTime ?? flight.engineShutdownTime ?? flight.stopTime

        let total = flight.blockTime
        let totalText = formatHoursMinutes(total)

        // A flight plan carrying an instructor is the one honest signal the app has that the flight
        // was dual. Everything else defaults to PIC, which is what a private pilot flying alone logs.
        let inferredFunction: LogbookFunction = {
            if let explicit = overrides?.function { return explicit }
            let instructor = flight.flightPlan?.instructor?.trimmingCharacters(in: .whitespaces)
            return (instructor?.isEmpty == false) ? .dual : .pic
        }()

        // Landings: the detector separates full stops from touch-and-gos, and a logbook counts
        // landings, so both belong in the day column unless the pilot says otherwise.
        let landings = flight.totalLandings
        let nightMinutes = overrides?.nightMinutes ?? 0
        let ifrMinutes = overrides?.ifrMinutes ?? 0

        return LogbookLine(
            date: formatDate(blockOff),
            departurePlace: flight.departureAirportIdent ?? "",
            departureTimeUTC: formatTimeUTC(blockOff),
            arrivalPlace: flight.arrivalAirportIdent ?? "",
            arrivalTimeUTC: formatTimeUTC(blockOn),
            aircraftModel: flight.aircraftType ?? flight.airplane,
            aircraftRegistration: flight.aircraftRegistration ?? "",
            singlePilotTime: totalText,
            totalTime: totalText,
            picName: resolvedPICName(overrides: overrides,
                                     defaultPilotName: defaultPilotName,
                                     function: inferredFunction,
                                     flight: flight),
            landingsDay: landings,
            landingsNight: 0,
            nightTime: formatMinutes(nightMinutes),
            ifrTime: formatMinutes(ifrMinutes),
            functionLabel: label(for: inferredFunction),
            functionTime: totalText,
            remarks: overrides?.remarks ?? defaultRemarks(for: flight)
        )
    }

    /// On a dual flight the PIC is the instructor, not the pilot writing the logbook — logging
    /// "SELF" there would be a false entry, so the instructor's name is used when it is known.
    private static func resolvedPICName(
        overrides: LogbookOverrides?,
        defaultPilotName: String?,
        function: LogbookFunction,
        flight: Flight
    ) -> String {
        if let explicit = overrides?.picName, !explicit.isEmpty { return explicit }
        if function == .dual {
            let instructor = flight.flightPlan?.instructor?.trimmingCharacters(in: .whitespaces)
            if let instructor, !instructor.isEmpty { return instructor }
        }
        if let name = defaultPilotName?.trimmingCharacters(in: .whitespaces), !name.isEmpty { return name }
        return "SELF"
    }

    private static func defaultRemarks(for flight: Flight) -> String {
        var parts: [String] = []
        if flight.touchAndGoCount > 0 {
            parts.append(L10n.Logbook.remarkTouchAndGo(flight.touchAndGoCount))
        }
        if flight.goAroundCount > 0 {
            parts.append(L10n.Logbook.remarkGoAround(flight.goAroundCount))
        }
        return parts.joined(separator: ", ")
    }

    static func label(for function: LogbookFunction) -> String {
        switch function {
        case .pic:        return L10n.Logbook.functionPIC
        case .dual:       return L10n.Logbook.functionDual
        case .coPilot:    return L10n.Logbook.functionCoPilot
        case .instructor: return L10n.Logbook.functionInstructor
        }
    }

    // MARK: - Formatting
    //
    // UTC and 24-hour throughout: AMC1 FCL.050 is explicit that logbook times are UTC, and a local
    // time silently written into that column is the kind of error nobody catches at an audit.

    private static let utc = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!

    static func formatDate(_ date: Date?) -> String {
        guard let date else { return "" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        guard let d = c.day, let m = c.month, let y = c.year else { return "" }
        return String(format: "%02d.%02d.%04d", d, m, y)
    }

    static func formatTimeUTC(_ date: Date?) -> String {
        guard let date else { return "" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let c = calendar.dateComponents([.hour, .minute], from: date)
        guard let h = c.hour, let m = c.minute else { return "" }
        return String(format: "%02d:%02d", h, m)
    }

    /// `H:MM`, the form a paper logbook column expects.
    static func formatHoursMinutes(_ interval: TimeInterval?) -> String {
        guard let interval, interval > 0 else { return "" }
        let totalMinutes = Int((interval / 60).rounded())
        return String(format: "%d:%02d", totalMinutes / 60, totalMinutes % 60)
    }

    static func formatMinutes(_ minutes: Int) -> String {
        guard minutes > 0 else { return "" }
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }

    // MARK: - Export

    /// CSV for the line, with the header — the shape capzlog and dLogbook importers expect to see.
    static func csv(for lines: [LogbookLine]) -> String {
        var rows = [LogbookLine.csvHeader.joined(separator: ",")]
        for line in lines {
            rows.append(line.csvRow.map(escapeCSV).joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }

    private static func escapeCSV(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    /// A human-readable block for copying into a paper logbook or an email.
    static func plainText(for line: LogbookLine) -> String {
        zip(LogbookLine.csvHeader, line.csvRow)
            .filter { !$0.1.isEmpty }
            .map { "\($0.0): \($0.1)" }
            .joined(separator: "\n")
    }
}
