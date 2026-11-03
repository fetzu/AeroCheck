import XCTest
import MapKit
import UIKit
@testable import AeroCheck

/// An aerodrome's card on the map (6.7.0, the author's answers c1 A, c2 A, c3 A): what it holds, how it is laid out,
/// and how MapKit's anchor places it over the marker and keeps it open while it is touched.
@MainActor
final class AerodromeCardTests: XCTestCase {

    private func airport(_ ident: String, name: String = "BRESSAUCOURT", lat: Double = 47.3924, lon: Double = 7.0289) -> Airport {
        Airport(id: abs(ident.hashValue % 100_000), ident: ident, type: .smallAirport, name: name, latitude: lat,
                longitude: lon, elevation: 1_400, continent: "EU", isoCountry: "CH", isoRegion: "CH-JU",
                municipality: nil, scheduledService: false, gpsCode: ident, iataCode: nil, localCode: nil)
    }

    private func content(_ airport: Airport, frequencies: String? = "AD 122.055\nAPP 119.350", note: AerodromeNote? = nil,
                         inFlight: Bool = false, divert: Bool = false, add: Bool = false) -> AerodromeCardContent {
        AerodromeCardContent.make(airport: airport, frequencyLines: frequencies, note: note, inFlight: inFlight,
                                  chart: nil, canOpenNote: true, canDivert: divert, canAddToRoute: add)
    }

    // MARK: The name (c3 A)

    func testANameInCapitalsIsShownInTitleCaseItsSmallWordsSmall() {
        XCTAssertEqual(AerodromeName.display("BRESSAUCOURT"), "Bressaucourt")
        XCTAssertEqual(AerodromeName.display("LA CHAUX-DE-FONDS"), "La Chaux-de-Fonds")
        XCTAssertEqual(AerodromeName.display("LES EPLATURES"), "Les Eplatures")
        XCTAssertEqual(AerodromeName.display("BERN-BELP"), "Bern-Belp")
        XCTAssertEqual(AerodromeName.display("ST. GALLEN-ALTENRHEIN"), "St. Gallen-Altenrhein")
        XCTAssertEqual(AerodromeName.display("SAINT-GALL ALTENRHEIN"), "Saint-Gall Altenrhein")
        XCTAssertEqual(AerodromeName.display("L'ABBAYE"), "L'Abbaye")
        XCTAssertEqual(AerodromeName.display("AERODROME DE COLMAR HOUSSEN"), "Aerodrome de Colmar Houssen")
        XCTAssertEqual(AerodromeName.display("ÉCUVILLENS"), "Écuvillens")
        // Written in mixed case, a name is shown as the data writes it.
        XCTAssertEqual(AerodromeName.display("Grenchen"), "Grenchen")
        XCTAssertEqual(AerodromeName.display("EuroAirport Basel-Mulhouse-Freiburg"), "EuroAirport Basel-Mulhouse-Freiburg")
        XCTAssertEqual(AerodromeName.display("CH-0002"), "CH-0002", "a code with a letter run stays")
        XCTAssertEqual(AerodromeName.display(""), "")
    }

    // MARK: What it holds

    func testTheCardHoldsTheCodeTheNameAndEachFrequency() {
        let card = content(airport("LSZQ"))
        XCTAssertEqual(card.ident, "LSZQ")
        XCTAssertEqual(card.name, "Bressaucourt")
        XCTAssertEqual(card.frequencies, [.init(label: "AD", value: "122.055"), .init(label: "APP", value: "119.350")])
        XCTAssertEqual(content(airport("LSZQ"), frequencies: nil).frequencies, [])
        XCTAssertEqual(AerodromeCardContent.frequencies(from: "122.500"), [.init(label: "", value: "122.500")])
    }

    /// The buttons in the surface's order: the chart, the note, Divert in flight, "+ Route" in the builder.
    func testTheButtonsFollowTheSurface() {
        let field = airport("LSZQ")
        XCTAssertEqual(content(field).actions, [.note(existing: false)])
        XCTAssertEqual(content(field, inFlight: true, divert: true).actions, [.divert])
        XCTAssertEqual(content(field, add: true).actions, [.note(existing: false), .addToRoute])
        let dryRun = AerodromeCardContent.make(airport: field, frequencyLines: nil, note: nil, inFlight: true, chart: nil,
                                               canOpenNote: false, canDivert: true, canAddToRoute: false)
        XCTAssertEqual(dryRun.actions, [.divert], "the dry run shows no notes (n7 B)")
    }

    // MARK: How it is laid out

    func testTheCardsButtonsShareOneRowAndItsHeightFitsItsContent() throws {
        let note = AerodromeNote(ident: "LSZQ", name: "BRESSAUCOURT", latitude: 47.39, longitude: 7.03,
                                 arrival: "Downwind 24 from the north, over Courgenay.", onTheGround: "Fuel at the club.")
        let ground = AerodromeCardView(content: content(airport("LSZQ"), note: note, add: true), metrics: .ground,
                                       tint: .systemTeal, width: 380) { _ in }
        ground.layoutIfNeeded()
        let buttons = ground.buttons
        XCTAssertEqual(buttons.map(\.accessibilityIdentifier), ["aerodromeCard.note", "aerodromeCard.addToRoute"])
        XCTAssertEqual(buttons[0].frame.width, buttons[1].frame.width, accuracy: 1)
        XCTAssertEqual(buttons[0].frame.minY, buttons[1].frame.minY, accuracy: 1)
        XCTAssertTrue(buttons.allSatisfy { $0.frame.height >= 44 })
        XCTAssertEqual(buttons[0].accessibilityLabel, L10n.AerodromeNotes.yourNote)
        XCTAssertGreaterThan(ground.bounds.height, 150)
        XCTAssertLessThan(ground.bounds.height, 320, "no room left empty")
        // Every button inside the card, above its tail.
        for button in buttons {
            XCTAssertLessThanOrEqual(button.convert(button.bounds, to: ground).maxY,
                                     ground.bounds.height - AerodromeCardView.tailHeight)
        }

        let flight = AerodromeCardView(content: content(airport("LSZQ"), note: note, inFlight: true, divert: true),
                                       metrics: .flight(.kneeboard), tint: .systemTeal, width: 520) { _ in }
        flight.layoutIfNeeded()
        XCTAssertEqual(flight.buttons.map(\.accessibilityIdentifier), ["aerodromeCard.note", "aerodromeCard.divert"])
        XCTAssertTrue(flight.buttons.allSatisfy { $0.frame.height >= CockpitTarget.control(.kneeboard) })
        XCTAssertNotNil(flight.findLabel("aerodromeCard.note.arrival"))
        XCTAssertNil(flight.findLabel("aerodromeCard.note.onTheGround"), "in flight, the Arrival part alone")
    }

    /// A word too long beside its symbol in its share of the row puts every symbol above its word: "Déroutement" on
    /// the phone's Cockpit, three buttons across.
    func testALongWordStacksTheRowsSymbols() {
        let font = UIFont.aero(size: 17, weight: .semibold)
        XCTAssertTrue(AerodromeCardView.stacksSymbols(titles: ["Carte", "Note", "Déroutement"], font: font,
                                                      symbolSize: 21, rowWidth: 330))
        XCTAssertFalse(AerodromeCardView.stacksSymbols(titles: ["Chart", "Note", "Divert"], font: font,
                                                       symbolSize: 21, rowWidth: 330))
        XCTAssertFalse(AerodromeCardView.stacksSymbols(titles: ["Carte", "Déroutement"], font: font,
                                                       symbolSize: 21, rowWidth: 488), "two across on the iPad")
        XCTAssertFalse(AerodromeCardView.stacksSymbols(titles: [], font: font, symbolSize: 21, rowWidth: 100))
    }

    /// The card's Divert says what the Cockpit's own button says: "Dérouter" in French, not "Déroutement", which
    /// the phone cut off (the author's r2-11).
    func testTheCardsDivertIsTheCockpitsWord() {
        XCTAssertEqual(AerodromeCardView.title(for: .divert), L10n.Act.divert)
    }

    func testAButtonTellsTheCardWhatItIs() throws {
        var done: [AerodromeCardContent.Action] = []
        let card = AerodromeCardView(content: content(airport("LSZQ"), inFlight: true, divert: true), metrics: .ground,
                                     tint: .systemTeal, width: 380) { done.append($0) }
        try XCTUnwrap(card.buttons.first).sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(done, [.divert])
    }

    // MARK: The anchor

    /// Over the marker, the tail on it; moved sideways to stay inside the map; the map moves down for a card that
    /// would leave it at the top, never for a marker off the map.
    func testTheAnchorKeepsTheCardOverItsMarkerAndInsideTheMap() {
        let area = CGRect(x: 12, y: 12, width: 796, height: 976)
        let size = CGSize(width: 380, height: 200)
        let middle = CalloutPlacement.frame(for: size, over: CGPoint(x: 410, y: 600), in: area)
        XCTAssertEqual(middle.midX, 410, accuracy: 0.5)
        XCTAssertEqual(middle.maxY, 600 - CalloutPlacement.gap, accuracy: 0.5)
        XCTAssertEqual(CalloutPlacement.shortfall(of: middle, anchor: CGPoint(x: 410, y: 600), in: area), 0)

        let atTheLeft = CalloutPlacement.frame(for: size, over: CGPoint(x: 40, y: 600), in: area)
        XCTAssertEqual(atTheLeft.minX, area.minX, "kept inside the map")

        let nearTheTop = CGPoint(x: 410, y: 100)
        let high = CalloutPlacement.frame(for: size, over: nearTheTop, in: area)
        XCTAssertEqual(CalloutPlacement.shortfall(of: high, anchor: nearTheTop, in: area), area.minY - high.minY,
                       accuracy: 0.5)
        XCTAssertEqual(CalloutPlacement.shortfall(of: high, anchor: CGPoint(x: 410, y: -500), in: area), 0,
                       "a marker not placed yet moves nothing")
    }
}

private extension UIView {
    func findLabel(_ identifier: String) -> UILabel? {
        for view in subviews {
            if let label = view as? UILabel, label.accessibilityIdentifier == identifier { return label }
            if let found = view.findLabel(identifier) { return found }
        }
        return nil
    }
}
