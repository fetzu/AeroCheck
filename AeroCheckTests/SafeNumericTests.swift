//
//  SafeNumericTests.swift
//  AeroCheckTests
//
//  SEC-C14: `Int(someDouble)` is an unconditional Swift TRAP — a process kill, not a catchable
//  error — for NaN, ±Infinity, or any magnitude outside Int's range. The app converts
//  externally-supplied Doubles to Int in the OpenAIP parsers, the grid-key math, and the live
//  instrument readouts, so any one of those was a single crafted or corrupt value from taking the
//  app down mid-flight.
//

import XCTest
@testable import AeroCheck

final class SafeNumericTests: XCTestCase {

    func testSafeIntRejectsNonFiniteValues() {
        XCTAssertNil(Double.nan.safeInt)
        XCTAssertNil(Double.infinity.safeInt)
        XCTAssertNil((-Double.infinity).safeInt)
    }

    func testSafeIntRejectsOutOfRangeValues() {
        // The value the review reproduced a hard trap (exit 133) with.
        XCTAssertNil(1e300.safeInt)
        XCTAssertNil((-1e300).safeInt)
    }

    func testSafeIntConvertsOrdinaryValues() {
        XCTAssertEqual((42.0).safeInt, 42)
        XCTAssertEqual((-7.9).safeInt, -7, "truncates toward zero, like Int(Double)")
        XCTAssertEqual((0.0).safeInt, 0)
    }

    func testSafeIntFallbackIsUsedOnlyWhenUnrepresentable() {
        XCTAssertEqual(Double.nan.safeInt(or: -1), -1)
        XCTAssertEqual(1e300.safeInt(or: -1), -1)
        XCTAssertEqual((17.0).safeInt(or: -1), 17)
    }

    func testSafeRoundedIntRoundsBeforeConverting() {
        XCTAssertEqual((2.6).safeRoundedInt(), 3)
        XCTAssertEqual((2.6).safeRoundedInt(.down), 2)
        XCTAssertEqual((-2.6).safeRoundedInt(.down), -3)
        XCTAssertNil(Double.nan.safeRoundedInt())
        XCTAssertNil(Double.infinity.safeRoundedInt(.down))
    }

    // The grid-key shape used by the four OpenAIP services: a non-finite feed coordinate used to
    // trap here, killing the whole per-country download and the app with it.
    func testGridKeyMathSurvivesNonFiniteCoordinate() {
        let gridCellDegrees = 1.0
        XCTAssertEqual((Double.nan / gridCellDegrees).safeRoundedInt(.down, or: 0), 0)
        XCTAssertEqual((1e300 / gridCellDegrees).safeRoundedInt(.down, or: 0), 0)
        XCTAssertEqual((47.4 / gridCellDegrees).safeRoundedInt(.down, or: 0), 47)
    }

    func testPlausibleRangeRejectsNonFiniteAndOutOfEnvelope() {
        XCTAssertFalse(PlausibleRange.isPlausible(.nan, in: PlausibleRange.speedMPS))
        XCTAssertFalse(PlausibleRange.isPlausible(.infinity, in: PlausibleRange.altitudeMeters))
        XCTAssertFalse(PlausibleRange.isPlausible(1e19, in: PlausibleRange.speedMPS))
        XCTAssertTrue(PlausibleRange.isPlausible(60, in: PlausibleRange.speedMPS))
        XCTAssertTrue(PlausibleRange.isPlausible(2_500, in: PlausibleRange.altitudeMeters))
    }
}
