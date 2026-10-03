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
        let path = try XCTUnwrap(Bundle.main.path(forResource: "fr", ofType: "lproj"), "the app ships French")
        return try XCTUnwrap(Bundle(path: path))
    }

    func testNoCatalogKeyUsesPositionalSpecifiers() throws {
        let url = try frenchBundle().bundleURL.appendingPathComponent("Localizable.strings")
        let table = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], "fr.lproj has a compiled Localizable.strings")
        XCTAssertGreaterThan(table.count, 100, "read the real table")
        let positional = table.keys.filter { $0.range(of: #"%\d+\$"#, options: .regularExpression) != nil }
        XCTAssertEqual(positional.sorted(), [], "Swift never looks these keys up: plain %@/%lld in the key, positions only in the value")
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
}
