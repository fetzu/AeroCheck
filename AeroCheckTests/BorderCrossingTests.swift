import XCTest
@testable import AeroCheck

/// The border pack (v5.0.0) and the A5 nav log.
///
/// The pack's whole value is that it never overstates a requirement, so most of this suite is about
/// what it refuses to claim rather than what it asserts.
final class BorderCrossingTests: XCTestCase {

    // MARK: - The pack's honesty rules

    func testAnUncuratedCountryReturnsNothingRatherThanAnEmptyRule() {
        // The dangerous failure would be a default-constructed rule reading "not required" for a
        // country nobody has checked. Absent must stay absent so the UI can say "not checked yet".
        XCTAssertNil(BorderCrossingGuide.rule(for: "ZZ"))
        XCTAssertNil(BorderCrossingGuide.rule(for: ""))
    }

    func testLookupIsCaseAndWhitespaceInsensitive() {
        XCTAssertNotNil(BorderCrossingGuide.rule(for: "fr"))
        XCTAssertNotNil(BorderCrossingGuide.rule(for: " FR "))
        XCTAssertEqual(BorderCrossingGuide.rule(for: "fr")?.country, "FR")
    }

    func testUnknownIsTreatedAsDemandingNotAsAbsent() {
        // "Not established" must never read like "not required" — an obligation nobody has verified
        // is one the pilot still has to satisfy.
        XCTAssertTrue(BorderRequirement.unknown.isDemanding)
        XCTAssertTrue(BorderRequirement.required.isDemanding)
        XCTAssertTrue(BorderRequirement.conditional.isDemanding)
        XCTAssertFalse(BorderRequirement.notRequired.isDemanding)
    }

    func testEveryCuratedRuleCarriesAnHTTPSSourceAndAReviewDate() {
        for code in BorderCrossingGuide.curatedCountries {
            let rule = try! XCTUnwrap(BorderCrossingGuide.rule(for: code))
            XCTAssertEqual(rule.country, code)
            XCTAssertEqual(rule.officialURL.scheme, "https", "\(code): the source must be a real https page")
            XCTAssertFalse(rule.countryName.isEmpty, "\(code): needs a display name")
            // yyyy-mm-dd. A rule nobody has dated cannot be aged, and an undateable rule is one
            // nobody can tell is stale.
            XCTAssertEqual(rule.lastReviewed.count, 10, "\(code): lastReviewed must be yyyy-mm-dd")
            XCTAssertNotNil(ISO8601DateFormatter().date(from: rule.lastReviewed + "T00:00:00Z"),
                            "\(code): lastReviewed must parse as a date")
        }
    }

    func testALeadTimeOnlyAppearsWhereNotificationIsActuallyRequired() {
        // A lead time attached to a "not required" rule would be a contradiction a pilot has to
        // resolve in their head at the worst moment.
        for code in BorderCrossingGuide.curatedCountries {
            let rule = try! XCTUnwrap(BorderCrossingGuide.rule(for: code))
            if rule.priorNotification == .notRequired {
                XCTAssertNil(rule.noticeLeadTime, "\(code): a lead time contradicts 'not required'")
            }
        }
    }

    func testSwissSideAlwaysExistsBecauseItAppliesInBothDirections() {
        // Switzerland is in Schengen but outside the EU customs union, so its own formalities apply
        // whichever country is at the other end.
        let ch = BorderCrossingGuide.switzerland
        XCTAssertEqual(ch.country, "CH")
        XCTAssertEqual(ch.officialURL.scheme, "https")
        XCTAssertTrue(ch.customsAerodrome.isDemanding, "category A-C is the rule, D only under conditions")
    }

    func testUKRequiresNotificationWithALeadTime() {
        let uk = try! XCTUnwrap(BorderCrossingGuide.rule(for: "GB"))
        XCTAssertEqual(uk.priorNotification, .required)
        XCTAssertNotNil(uk.noticeLeadTime, "the GAR window is the whole point of the UK entry")
    }

    func testFranceNoLongerRequiresAPreavis() {
        // French customs confirmed the préavis is gone for flights from Switzerland; stale AIP
        // entries still say otherwise, which is exactly why this is pinned.
        let fr = try! XCTUnwrap(BorderCrossingGuide.rule(for: "FR"))
        XCTAssertEqual(fr.priorNotification, .notRequired)
        XCTAssertNil(fr.noticeLeadTime)
    }

    func testARuleWithAnUnknownIsFlaggedAsHavingAnOpenQuestion() {
        let open = BorderCrossingRule(
            country: "XX", countryName: "Test",
            customsAerodrome: .unknown, priorNotification: .required, noticeLeadTime: "1 h",
            officialURL: URL(string: "https://example.com")!, lastReviewed: "2026-09-01"
        )
        XCTAssertTrue(open.hasOpenQuestion)

        let settled = BorderCrossingRule(
            country: "XX", countryName: "Test",
            customsAerodrome: .required, priorNotification: .required, noticeLeadTime: "1 h",
            officialURL: URL(string: "https://example.com")!, lastReviewed: "2026-09-01"
        )
        XCTAssertFalse(settled.hasOpenQuestion)
    }

    // MARK: - A5 nav log

    private func plan() -> FlightPlan {
        var plan = FlightPlan(name: "Test")
        plan.waypoints = [
            FlightPlanWaypoint(name: "LSZQ", coordinate: .init(latitude: 47.4247, longitude: 7.1869)),
            FlightPlanWaypoint(name: "LSGY", coordinate: .init(latitude: 46.7619, longitude: 6.6141)),
        ]
        plan.fuelFlow = 25
        plan.tripFuel = 20
        return plan
    }

    func testA4RemainsTheDefaultSoExistingCallSitesAreUnchanged() {
        let data = try! XCTUnwrap(FlightPlanExportService.exportToPDF(plan()))
        XCTAssertEqual(pageSize(of: data)?.width ?? 0, 595, accuracy: 1)
        XCTAssertEqual(pageSize(of: data)?.height ?? 0, 842, accuracy: 1)
    }

    func testA5ProducesAKneeboardSizedPage() {
        let data = try! XCTUnwrap(FlightPlanExportService.exportToPDF(plan(), paperSize: .a5))
        let size = try! XCTUnwrap(pageSize(of: data))
        XCTAssertEqual(size.width, 420, accuracy: 1)
        XCTAssertEqual(size.height, 595, accuracy: 1)
    }

    func testBothPaperSizesRenderASinglePage() {
        for paper in FlightPlanExportService.PaperSize.allCases {
            let data = try! XCTUnwrap(FlightPlanExportService.exportToPDF(plan(), paperSize: paper))
            XCTAssertEqual(pageCount(of: data), 1, "\(paper.label) should be one sheet")
        }
    }

    /// Reads the first page's media box straight from the produced PDF, so this tests the artefact
    /// rather than the constant that made it.
    private func pageSize(of data: Data) -> CGSize? {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              let page = document.page(at: 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        return CGSize(width: box.width, height: box.height)
    }

    private func pageCount(of data: Data) -> Int {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider) else { return 0 }
        return document.numberOfPages
    }
}
