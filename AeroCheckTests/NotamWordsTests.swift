import XCTest
@testable import AeroCheck

/// What the NOTAM rows say, and the age of the copy. Never "No NOTAMs", never a percentage.
final class NotamWordsTests: NotamTestCase {
    func testTheCopysAgeShowsPastTheHour() {
        let time = noon
        let fresh = NotamCopyState(time: time)
        XCTAssertFalse(fresh.isOld(now: time.addingTimeInterval(3599)))
        XCTAssertTrue(fresh.isOld(now: time.addingTimeInterval(3601)))
        XCTAssertEqual(NotamWords.age(fresh, now: time.addingTimeInterval(60)), "12:00 UTC")
        XCTAssertEqual(fresh.ageHours(now: time.addingTimeInterval(3 * 3600 + 60)), 3)
        XCTAssertNotEqual(NotamWords.age(fresh, now: time.addingTimeInterval(3 * 3600 + 60)), "12:00 UTC")
        XCTAssertNil(NotamWords.age(NotamCopyState(time: nil), now: time))
    }


    func testTheTimesInUTC() throws {
        let n = onRoute("1", start: NotamTime.date("2026-11-06T08:00:00Z"), end: NotamTime.date("2026-11-06T16:00:00Z"))
        XCTAssertTrue(NotamWords.when(n, now: noon).contains("08:00–16:00 UTC"))
        let long = onRoute("2", start: noon.addingTimeInterval(-3600), end: NotamTime.date("2026-11-12T16:00:00Z"))
        XCTAssertEqual(NotamWords.dayMonth(try XCTUnwrap(long.end)).first, "1", "the day first: until 12 Nov")
        XCTAssertEqual(NotamWords.when(long, now: noon), L10n.Notams.until(NotamWords.dayMonth(try XCTUnwrap(long.end))))
        XCTAssertEqual(NotamWords.when(onRoute("3", start: noon.addingTimeInterval(-3600)), now: noon), L10n.Notams.permanent)
    }

    func testAnEstimatedEndSaysSo() {
        var n = onRoute("1", start: noon, end: noon.addingTimeInterval(3600))
        n.estimated = true
        XCTAssertTrue(NotamWords.when(n, now: noon).hasSuffix("EST"))
    }

    func testTheBandShowsOnlyWhenItSaysSomething() {
        let whole = onRoute("1", start: noon)
        XCTAssertFalse(NotamWords.meta(whole, now: noon).contains("SFC"))
        var band = whole
        band.upperFl = 95
        XCTAssertTrue(NotamWords.meta(band, now: noon).contains("SFC"))
        XCTAssertTrue(NotamWords.meta(band, now: noon).contains("FL 095"))
    }

    func testAFieldsOwnNotamOnTheRouteNamesTheField() {
        var n = notam("1", at: "LSZG")
        n.lat = 47.75
        n.lon = 7.20
        let entry = NotamSorter.sort([n], for: flight()).along[0]
        XCTAssertEqual(NotamWords.title(entry).where, "LSZG")
        var airspace = notam("2", at: "LFEE")
        airspace.lat = 47.75
        airspace.lon = 7.20
        XCTAssertEqual(NotamWords.title(NotamSorter.sort([airspace], for: flight()).along[0]).where, L10n.Notams.placeRoute)
    }

    /// The server writes "" for a location it doesn't have: the row still says where.
    func testANotamWithNoLocationStillNamesItsPlace() {
        var n = notam("1", at: "", lat: 47.75, lon: 7.20)
        n.fir = nil
        XCTAssertEqual(NotamWords.title(NotamSorter.sort([n], for: flight()).along[0]).where, L10n.Notams.placeRoute)
    }

    func testTheSortingSaysWhatItUsed() {
        let line = NotamWords.sortedBy(flight(), now: noon)
        for part in ["LSZQ → LFGA", "12:00–15:00 UTC", "6500", L10n.Notams.corridor] { XCTAssertTrue(line.contains(part), part) }
        XCTAssertFalse(NotamWords.sortedBy(flight(ceiling: nil), now: noon).contains(" ft"))
    }

    func testNoWordSaysThereAreNoNotamsOrGivesAPercentage() {
        for words in [L10n.Notams.noneFound, L10n.Notams.noListHere, L10n.Notams.notice, L10n.Notams.alongFlight] {
            XCTAssertFalse(words.localizedCaseInsensitiveContains("No NOTAMs"), words)
            XCTAssertFalse(words.contains("%"), words)
        }
    }
}
