import XCTest
@testable import AeroCheck

/// The curated land-border table that drives the onboarding "download my region + neighbours"
/// data-download suggestions. (onboarding revamp)
final class OnboardingRegionTests: XCTestCase {

    func testSwitzerlandNeighboursMatchSpec() {
        XCTAssertEqual(Set(CountryNeighbors.neighbors(of: "CH")), Set(["FR", "DE", "IT", "AT"]),
                       "Switzerland → France, Germany, Italy, Austria (micro-states excluded)")
    }

    func testUnitedStatesNeighbours() {
        XCTAssertEqual(Set(CountryNeighbors.neighbors(of: "US")), Set(["CA", "MX"]))
    }

    func testLookupIsCaseInsensitive() {
        XCTAssertEqual(CountryNeighbors.neighbors(of: "ch"), CountryNeighbors.neighbors(of: "CH"))
    }

    func testUnknownCountryHasNoNeighbours() {
        XCTAssertTrue(CountryNeighbors.neighbors(of: "ZZ").isEmpty)
        XCTAssertTrue(CountryNeighbors.neighbors(of: "").isEmpty)
    }

    /// Borders are symmetric: if A lists B and B is in the table, B must list A. Catches table typos.
    func testNeighboursAreReciprocalForKnownPairs() {
        for (country, neighbours) in CountryNeighbors.table {
            for n in neighbours where CountryNeighbors.table[n] != nil {
                XCTAssertTrue(CountryNeighbors.neighbors(of: n).contains(country),
                              "\(n) should list \(country) as a neighbour (reciprocal border)")
            }
        }
    }
}
