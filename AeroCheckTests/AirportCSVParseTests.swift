import XCTest
@testable import AeroCheck

/// Guards the CSV parser after moving it off the main actor and rewriting `parseCSVRow` to slice
/// substrings instead of accumulating characters. The new implementation must produce byte-identical
/// output: every `"` stripped, commas split only at even quote-parity. (PERF-07)
final class AirportCSVParseTests: XCTestCase {

    func testSplitsSimpleRow() {
        XCTAssertEqual(AirportDataService.parseCSVRow("a,b,c"), ["a", "b", "c"])
    }

    func testQuotedFieldWithEmbeddedCommaIsOneField() {
        XCTAssertEqual(
            AirportDataService.parseCSVRow("\"Zurich, Intl\",TWR"),
            ["Zurich, Intl", "TWR"]
        )
    }

    func testStripsQuotesFromUnquotedComma() {
        XCTAssertEqual(AirportDataService.parseCSVRow("\"LSZQ\",foo"), ["LSZQ", "foo"])
    }

    func testTrailingAndLeadingEmptyFields() {
        XCTAssertEqual(AirportDataService.parseCSVRow("a,b,"), ["a", "b", ""])
        XCTAssertEqual(AirportDataService.parseCSVRow(",b"), ["", "b"])
        XCTAssertEqual(AirportDataService.parseCSVRow(""), [""])
    }

    func testEmbeddedCommasInsideMultipleQuotedFields() {
        XCTAssertEqual(
            AirportDataService.parseCSVRow("1,\"a,b\",\"c,d\",2"),
            ["1", "a,b", "c,d", "2"]
        )
    }

    func testParseCSVBuildsDictionariesAndFiltersEmpties() {
        let csv = "id,ident,name\n1,LSZH,\"Zurich, Intl\"\n2,LSGG,Geneva"
        let rows = AirportDataService.parseCSV(csv)

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0]["ident"], "LSZH")
        XCTAssertEqual(rows[0]["name"], "Zurich, Intl")
        XCTAssertEqual(rows[1]["ident"], "LSGG")
    }

    func testParseCSVSkipsRowsWithWrongColumnCount() {
        // Second data row has too few columns and must be skipped, not mis-mapped.
        let csv = "a,b,c\n1,2,3\nx,y"
        let rows = AirportDataService.parseCSV(csv)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["c"], "3")
    }

    func testParseCSVOmitsEmptyValues() {
        let csv = "a,b,c\n1,,3"
        let rows = AirportDataService.parseCSV(csv)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["a"], "1")
        XCTAssertNil(rows[0]["b"], "Empty values are not stored")
        XCTAssertEqual(rows[0]["c"], "3")
    }
}
