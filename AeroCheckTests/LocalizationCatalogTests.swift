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
}
