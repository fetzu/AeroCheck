import Foundation

/// The country an aerodrome is in, from its ICAO location indicator: the first letters name the State (ICAO Doc
/// 7910), "LS" Switzerland, "LF" France, "K" the United States. For an aerodrome this beats the country boundaries,
/// whose polygons are drawn coarse enough to put Bressaucourt, 1.5 km from France, in both countries, and beats the
/// route's countries, which are alphabetical and widened by 10 NM (Basel-Mulhouse read Switzerland). The briefing
/// and the close-out go by the country an aerodrome is in, so they ask here first. (6.5.0)
enum ICAOCountry {

    /// The ISO-2 country of `ident`, or nil when it isn't a four-letter ICAO code or its prefix isn't known.
    static func country(of ident: String?) -> String? {
        guard let ident = ident?.trimmingCharacters(in: .whitespaces).uppercased(), ident.count == 4,
              ident.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) || ("0"..."9").contains($0) }) else { return nil }
        if let country = exceptions[ident] { return country }
        if let country = twoLetter[String(ident.prefix(2))] { return country }
        return oneLetter[String(ident.prefix(1))]
    }

    /// Aerodromes whose country is not their prefix's: the Isle of Man and the Faroe Islands are briefed and
    /// closed as their own countries (the server's registry has IM and FO), Montenegro shares LY with Serbia.
    private static let exceptions: [String: String] = [
        "EGNS": "IM", "EKVG": "FO", "LYPG": "ME", "LYTV": "ME", "LYNK": "ME",
    ]

    /// Two-letter prefixes: Europe and its neighbours, and the few States elsewhere that share a first letter.
    private static let twoLetter: [String: String] = [
        // Europe, west and north
        "LS": "CH", "LF": "FR", "LN": "MC", "ED": "DE", "ET": "DE", "LO": "AT", "LI": "IT", "LM": "MT", "LE": "ES",
        "GC": "ES", "GE": "ES", "LX": "GI", "LP": "PT", "EG": "GB", "EI": "IE", "EB": "BE", "EL": "LU", "EH": "NL",
        "EK": "DK", "BG": "GL", "BI": "IS", "EN": "NO", "ES": "SE", "EF": "FI", "EE": "EE", "EV": "LV", "EY": "LT",
        "EP": "PL",
        // Europe, centre and south-east
        "LK": "CZ", "LZ": "SK", "LH": "HU", "LJ": "SI", "LD": "HR", "LQ": "BA", "LY": "RS", "BK": "XK", "LW": "MK",
        "LA": "AL", "LG": "GR", "LB": "BG", "LR": "RO", "LU": "MD", "LT": "TR", "LC": "CY", "UK": "UA", "UM": "BY",
        "UG": "GE", "UD": "AM", "UB": "AZ", "LL": "IL",
        // Elsewhere, where the first letter alone would mislead
        "NZ": "NZ", "PA": "US", "PH": "US", "PG": "GU", "PJ": "US", "PM": "US", "PW": "US", "TJ": "PR", "TI": "VI",
    ]

    /// One-letter prefixes for the large States that own a whole letter.
    private static let oneLetter: [String: String] = ["K": "US", "C": "CA", "Y": "AU"]
}
