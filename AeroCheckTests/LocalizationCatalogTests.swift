import XCTest
@testable import AeroCheck

/// Locks the string catalog's keys to the form Swift looks them up by.
///
/// `String(localized: "Leg \(index) of \(total)")` and `Text("… \(x) …")` look up a key with plain
/// specifiers (`Leg %lld of %lld`), never positional ones. A key hand-added as `Leg %1$lld of %2$lld`
/// is never found, so the French screen silently shows the English text. Positions belong in the
/// translated value only, where French word order needs them.
///
/// Five keys had this during 6.1.0: the leg page's "Leg 3 of 3" and "TRIP · 1 of 6", the two
/// "open in Plan and Prepare" lines, and the map data "3/5 layers" count.
///
/// The French the 6.1 App Store captures found missing is locked here too: the Logbook, the flight
/// detail, the Cockpit's NEXT column, the "1 FLIGHTS" plural and the relative times.
final class LocalizationCatalogTests: XCTestCase {

    /// English in French at 6.1.1, and the "mode Companion" the rest of the app calls "mode compagnon":
    /// the GPS Status drawer, the event cards and the post-flight review's type menu, the FREQ panel's
    /// 121.500, the Logbook's Export menu, year menu and rows, the flight detail's LDG and PLAN vs
    /// ACTUAL, and Companion mode's chip and exit dialog.
    func testTheCockpitLogbookAndCompanionLeftoversHaveTheirFrench() throws {
        let french = try frenchBundle()
        let missing = "\u{1}missing"
        let expected = [
            "gps.reason.reducedAccuracy": "Précision réduite · ± %lld m",
            "gps.reason.noUpdate": "Aucune position depuis %lld s",
            "gps.reason.networkPosition": "Aucune position satellite · position réseau ± %lld m",
            "gps.reason.weakSignal": "Signal faible",
            "gps.reason.noFix": "Aucune position",
            "gps.fix.accuracy": "Précision",
            "gps.fix.vertical": "Verticale",
            "gps.fix.time": "Heure de la position",
            "flightEvent.goAround": "Remise de gaz",
            "flightEvent.touchAndGo": "Posé-décollé",
            "flightEvent.fullStop": "Atterrissage complet",
            "nav.freqEmergency": "Urgence",
            "Listed (%lld)": "Vols listés (%lld)",
            "All flights (%lld)": "Tous les vols (%lld)",
            "flightLog.allYears": "Toutes",
            "flightLog.landingCount": "%lld att.",
            "flightDetail.landingsChip": "ATT",
            "PLAN vs ACTUAL": "PRÉVU vs RÉEL",
            "Waypoint": "Point",
            "COMPANION": "COMPAGNON",
        ]
        for (key, value) in expected {
            XCTAssertEqual(french.localizedString(forKey: key, value: missing, table: nil), value, key)
        }
        XCTAssertEqual(String(format: expected["gps.reason.noUpdate"]!, 12), "Aucune position depuis 12 s")
        for key in ["companion.exitConfirmTitle", "companion.exitConfirmMessage"] {
            let found = french.localizedString(forKey: key, value: missing, table: nil)
            XCTAssertTrue(found.contains("mode compagnon"), "\(key): \(found)")
            XCTAssertFalse(found.contains("Companion"), "\(key): \(found)")
        }
        // The keys that are not the English text carry their English.
        XCTAssertEqual(L10n.GPS.reasonReducedAccuracy(120), "Reduced accuracy · ± 120 m")
        XCTAssertEqual(L10n.GPS.reasonNoUpdate(12), "No position update for 12 s")
        XCTAssertEqual(L10n.GPS.reasonNetworkPosition(35), "No satellite fix · network position ± 35 m")
        XCTAssertEqual(L10n.GPS.fixTime, "Fix time")
        XCTAssertEqual([FlightEventType.goAround, .touchAndGo, .fullStop].map(\.title), ["Go-Around", "Touch-and-Go", "Full Stop"])
        XCTAssertEqual(SwissCommonFrequency.emergency.name, "Emergency")
        XCTAssertEqual(L10n.FlightLog.allYears, "All")
        XCTAssertEqual(L10n.FlightLog.landingCount(3), "3 ldg")
        XCTAssertEqual(L10n.FlightDetail.landingsChip, "LDG")
    }

    private func frenchBundle() throws -> Bundle {
        try languageBundle("fr")
    }

    private func languageBundle(_ language: String) throws -> Bundle {
        let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"), "the app ships \(language)")
        return try XCTUnwrap(Bundle(path: path))
    }

    /// The Logbook's Share Stats sheet read English in French: its section labels, toggles, accents and
    /// layouts took a `String`, never looked up, and its title had no French. (6.2)
    func testTheShareStatsSheetHasItsFrench() throws {
        let french = try frenchBundle()
        let missing = "\u{1}missing"
        let expected = [
            "Share Stats": "Partager les statistiques",
            "COLOR THEME": "THÈME DE COULEUR",
            "ACCENT": "COULEUR D’ACCENTUATION",
            "Gold": "Or",
            "Blue": "Bleu",
            "Green": "Vert",
            "Orange": "Orange",
            "Red": "Rouge",
            "LAYOUT": "DISPOSITION",
            "Tiles": "Tuiles",
            "Hero": "Vedette",
            "CONTENT": "CONTENU",
            "Hours by aircraft": "Heures par avion",
            "Period title": "Titre de la période",
        ]
        for (key, value) in expected {
            XCTAssertEqual(french.localizedString(forKey: key, value: missing, table: nil), value, key)
        }
    }

    func testNoCatalogKeyUsesPositionalSpecifiers() throws {
        let url = try frenchBundle().bundleURL.appendingPathComponent("Localizable.strings")
        let table = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], "fr.lproj has a compiled Localizable.strings")
        XCTAssertGreaterThan(table.count, 100, "read the real table")
        let positional = table.keys.filter { $0.range(of: #"%\d+\$"#, options: .regularExpression) != nil }
        XCTAssertEqual(positional.sorted(), [], "Swift never looks these keys up: plain %@/%lld in the key, positions only in the value")
    }

    /// The Logbook's stats card and the Cockpit strip's VoiceOver read English in French: the card's
    /// tiles took a `String`, never looked up, and the instruments built their values in code. (6.2)
    func testTheStatsCardAndTheInstrumentsHaveTheirFrench() throws {
        let french = try frenchBundle()
        let missing = "\u{1}missing"
        let expected = [
            "FLIGHT LOG": "CARNET DE VOL",
            "HOURS": "HEURES",
            "FLIGHTS": "VOLS",
            "LANDINGS": "ATTERRISSAGES",
            "HOURS BY AIRCRAFT": "HEURES PAR AVION",
            "Ground speed": "Vitesse sol",
            "Heading": "Cap",
            "unknown": "inconnu",
            "GPS signal lost": "Signal GPS perdu",
            "%lld knots ground speed": "%lld nœuds de vitesse sol",
            "%lld feet M S L": "%lld pieds M S L",
            "%lld degrees track": "route %lld degrés",
        ]
        for (key, value) in expected {
            XCTAssertEqual(french.localizedString(forKey: key, value: missing, table: nil), value, key)
        }
        let onTarget = french.localizedString(forKey: "%lld knots ground speed, on target. Target %lld knots", value: missing, table: nil)
        let offTarget = french.localizedString(forKey: "%lld knots ground speed, off target. Target %lld knots", value: missing, table: nil)
        XCTAssertEqual(String(format: onTarget, 55, 55), "55 nœuds de vitesse sol, dans la cible. Vitesse cible 55 nœuds")
        XCTAssertEqual(String(format: offTarget, 45, 76), "45 nœuds de vitesse sol, hors cible. Vitesse cible 76 nœuds")
    }

    func testTheInterpolatedKeysHaveTheirFrench() throws {
        let french = try frenchBundle()
        let missing = "\u{1}missing"
        let expected = [
            "Leg %lld of %lld": "Étape %1$lld sur %2$lld",
            "TRIP · %lld of %lld": "VOYAGE · %1$lld sur %2$lld",
            "%lld/%lld layers": "%1$lld/%2$lld couches",
            "Page %lld of %lld": "Page %1$lld sur %2$lld",
            "%@ still has %lld item(s) open in Plan and Prepare.":
                "Il reste %2$lld élément(s) ouvert(s) dans Planifier et Préparer pour %1$@.",
            "Next: %@ · %lld open in Plan and Prepare": "Suivant : %1$@ · %2$lld ouvert(s) dans Planifier et Préparer",
        ]
        for (key, value) in expected {
            let found = french.localizedString(forKey: key, value: missing, table: nil)
            XCTAssertNotEqual(found, missing, "\(key) has no French")
            XCTAssertEqual(found, value, key)
        }
        XCTAssertEqual(String(format: expected["Leg %lld of %lld"]!, 3, 3), "Étape 3 sur 3")
    }

    // MARK: - The French the 6.1 captures found missing

    /// The Logbook read "1 FLIGHTS" and "1 flight" came from a hand-made "s": the count is a plural in
    /// the catalog, singular for one in both languages.
    func testTheFlightCountIsAPluralInBothLanguages() throws {
        for (language, one, three) in [("en", "1 flight", "3 flights"), ("fr", "1 vol", "3 vols")] {
            let format = try languageBundle(language).localizedString(forKey: "%lld flights", value: nil, table: nil)
            XCTAssertEqual(String.localizedStringWithFormat(format, 1), one, language)
            XCTAssertEqual(String.localizedStringWithFormat(format, 3), three, language)
        }
        XCTAssertEqual(L10n.FlightLog.listHeader(1), "1 FLIGHT")
        XCTAssertEqual(L10n.FlightLog.listHeader(12), "12 FLIGHTS")
        XCTAssertEqual(L10n.FlightLog.monthSummary(1, hours: 1.94), "1 flight · 1.9 h")
        XCTAssertEqual(L10n.FlightLog.monthSummary(4, hours: 6), "4 flights · 6.0 h")
    }

    /// The Logbook list, the flight detail and the Cockpit's NEXT column were English in French.
    func testTheLogbookFlightDetailAndCockpitHaveTheirFrench() throws {
        let french = try frenchBundle()
        let missing = "\u{1}missing"
        let expected = [
            "Hours": "Heures",
            "Flights": "Vols",
            "Landings": "Atterrissages",
            "Filter": "Filtrer",
            "Export": "Exporter",
            "flightDetail.time": "TEMPS",
            "TIMELINE": "CHRONOLOGIE",
            "flightDetail.trackStart": "Départ",
            "flightDetail.trackEnd": "Arrivée",
            "Speed": "Vitesse",
            "flightDetail.blockOff": "Bloc OFF",
            "flightDetail.blockOn": "Bloc ON",
            "cockpit.nextColumn": "SUIVANT",
        ]
        for (key, value) in expected {
            XCTAssertEqual(french.localizedString(forKey: key, value: missing, table: nil), value, key)
        }
        // The keys that are not the English text carry their English.
        XCTAssertEqual(L10n.FlightDetail.time, "TIME")
        XCTAssertEqual(L10n.FlightDetail.trackStart, "Start")
        XCTAssertEqual(L10n.FlightDetail.trackEnd, "End")
        XCTAssertEqual(L10n.Cockpit.nextColumn, "NEXT")
    }

    /// The abbreviated style is CLDR's narrow one, which French writes "-4 m." and "-13 s". Every
    /// relative time goes through `L10n.Time.relative`, in words in both languages.
    func testRelativeTimesReadAsWordsInBothLanguages() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        // 13 s, 4 min, 3 h, 2 days, 130 days ago.
        let offsets: [TimeInterval] = [-13, -240, -10_800, -172_800, -11_232_000]
        let past = offsets.map { now.addingTimeInterval($0) }
        let french = L10n.Time.makeRelativeFormatter(locale: Locale(identifier: "fr_CH"))
        for date in past {
            let text = french.localizedString(for: date, relativeTo: now)
            XCTAssertTrue(text.hasPrefix("il y a "), text)
        }
        XCTAssertTrue(french.localizedString(for: now.addingTimeInterval(3 * 3_600), relativeTo: now).hasPrefix("dans "))
        let english = L10n.Time.makeRelativeFormatter(locale: Locale(identifier: "en_CH"))
        for date in past {
            let text = english.localizedString(for: date, relativeTo: now)
            XCTAssertTrue(text.hasSuffix(" ago"), text)
        }
        XCTAssertTrue(L10n.Time.relative(past[0], to: now).hasSuffix(" ago"))
    }

    /// The Watch app had no localization at all. It has its own catalog (AeroCheckWatch/), read here
    /// from the Watch app the phone app embeds. The FREQ badges say what the phone's panel says.
    func testTheWatchAppShipsFrench() throws {
        let watchApp = Bundle.main.bundleURL.appendingPathComponent("Watch/AeroCheckWatch.app")
        let french = try XCTUnwrap(Bundle(url: watchApp.appendingPathComponent("fr.lproj")), "the Watch app ships French")
        let english = try XCTUnwrap(Bundle(url: watchApp.appendingPathComponent("en.lproj")))
        let missing = "\u{1}missing"
        let phone = try frenchBundle()
        let expected = [
            "NO DATA": "AUCUNE DONNÉE",
            "Connected": "Connecté",
            "Waiting...": "En attente…",
            "Start flight on iPhone": "Démarrez le vol sur l’iPhone",
            "FLIGHT TIME": "TEMPS DE VOL",
            "NEXT": "SUIVANT",
            "CHRONO": "CHRONO",
            "FREQUENCIES": "FRÉQUENCES",
            "LOCAL": "HEURE LOCALE",
            "freq.now": phone.localizedString(forKey: "nav.freqCurrent", value: missing, table: nil),
            "freq.next": phone.localizedString(forKey: "nav.freqNext", value: missing, table: nil),
        ]
        XCTAssertEqual(expected["freq.now"], "ACT")
        XCTAssertEqual(expected["freq.next"], "SUIV")
        for (key, value) in expected {
            XCTAssertEqual(french.localizedString(forKey: key, value: missing, table: nil), value, key)
        }
        XCTAssertEqual(english.localizedString(forKey: "freq.now", value: missing, table: nil), "NOW")
        XCTAssertEqual(english.localizedString(forKey: "freq.next", value: missing, table: nil), "NEXT")
    }
}
