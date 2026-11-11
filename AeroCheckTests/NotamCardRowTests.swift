import UIKit
import XCTest
@testable import AeroCheck

/// The aerodrome card's row: there when the field has NOTAMs on the device, and otherwise nothing at all (the author).
@MainActor
final class NotamCardRowTests: XCTestCase {
    private func airport() -> Airport {
        Airport(id: 1, ident: "LSZG", type: .smallAirport, name: "Grenchen", latitude: 47.18, longitude: 7.41, elevation: 1411, continent: "EU",
                isoCountry: "CH", isoRegion: "CH-SO", municipality: nil, scheduledService: false, gpsCode: "LSZG", iataCode: nil, localCode: nil)
    }

    private func card(_ notams: [Notam], inFlight: Bool = false, onNotams: (() -> Void)? = nil) -> AerodromeCardView {
        var facts = AerodromeFacts()
        facts.notams = notams
        let content = AerodromeCardContent.make(airport: airport(), frequencyLines: nil, note: nil, inFlight: inFlight, chart: nil,
                                                canOpenNote: false, canDivert: false, canAddToRoute: false, facts: facts)
        return AerodromeCardView(content: content, metrics: inFlight ? .flight(.kneeboard) : .ground, tint: .systemBlue, width: 360,
                                 onNotams: onNotams) { _ in }
    }

    private func views(in view: UIView) -> [UIView] { view.subviews + view.subviews.flatMap(views) }
    /// A button, not a plain control: a plain one loses a real touch to the map's own tap, which closes the card.
    private func row(_ card: AerodromeCardView) -> UIButton? {
        views(in: card).first { $0.accessibilityIdentifier == "aerodromeCard.notams" } as? UIButton
    }

    private let closed = [Notam(id: "1", number: "B1/26", location: "LSZG", text: "RWY 06/24 CLSD"),
                          Notam(id: "2", number: "B2/26", location: "LSZG", text: "TWY A CLSD")]

    func testWithNotamsTheRowCountsThemAndShowsTheFirst() throws {
        let tall = card(closed)
        let empty = card([])
        XCTAssertGreaterThan(tall.frame.height, empty.frame.height)
        let label = try XCTUnwrap(row(tall)?.accessibilityLabel)
        XCTAssertEqual(label, "NOTAM 2, RWY 06/24 CLSD")
    }

    func testWithNoneThereIsNoRowAtAll() {
        let empty = card([])
        XCTAssertNil(empty.content.notamRow)
        XCTAssertNil(row(empty))
        let texts = views(in: empty).compactMap { ($0 as? UILabel)?.text }
        XCTAssertFalse(texts.contains { $0.contains("NOTAM") }, "no text, no dash, nothing")
    }

    func testATapReads() throws {
        var opened = 0
        let shown = card(closed) { opened += 1 }
        try XCTUnwrap(row(shown)).sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(opened, 1)
    }

    func testInFlightTheRowIsATouchTarget() throws {
        let shown = card(closed, inFlight: true)
        shown.layoutIfNeeded()
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(row(shown)).frame.height, CockpitTarget.control(.kneeboard))
    }

    func testTheRowLeavesTheButtonsAlone() {
        XCTAssertTrue(card(closed).buttons.isEmpty)
    }
}
