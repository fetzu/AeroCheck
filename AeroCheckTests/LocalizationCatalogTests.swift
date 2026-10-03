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
