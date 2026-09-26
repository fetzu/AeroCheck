import XCTest
@testable import AeroCheck

/// The fuel-on-board sheet's rules: where the full-tanks figure comes from, what the margin says,
/// how an entry is read, and the pilot's figure surviving a sync. (on-device review #4, point 3)
final class FuelOnBoardTests: XCTestCase {

    private func aircraft(_ registration: String, usableFuel: Double?) -> RemoteAircraftMetadata {
        var meta = RemoteAircraftMetadata(
            id: registration.lowercased(), aircraftType: "PA28", registration: registration,
            modelName: "Piper Archer II", shortModelName: "PA-28-181", aeroclub: nil,
            version: "1.0", lastUpdated: "2026-01-01", isFree: false,
            stallSpeed: 50, pageCount: 4, hasAccess: true, availableLanguages: ["en"])
        meta.usableFuelLitres = usableFuel
        return meta
    }

    // MARK: - Full tanks

    func testTheAircraftsDataWinsOverThePilotsFigure() {
        let resolved = FullTanks.resolve(registration: "HB-PFA", available: [aircraft("HB-PFA", usableFuel: 181.7)],
                                         pilotValues: ["HB-PFA": 150])
        XCTAssertEqual(resolved, FullTanks(litres: 181.7, source: .aircraftData))
    }

    func testThePilotsFigureWhenTheDataHasNone() {
        let resolved = FullTanks.resolve(registration: "f-hvxa", available: [aircraft("HB-PFA", usableFuel: nil)],
                                         pilotValues: ["F-HVXA": 90])
        XCTAssertEqual(resolved, FullTanks(litres: 90, source: .pilot), "keyed by the registration, any case")
    }

    func testNothingKnownAsksThePilot() {
        XCTAssertNil(FullTanks.resolve(registration: "F-HVXA", available: [], pilotValues: [:]))
        XCTAssertNil(FullTanks.resolve(registration: "  ", available: [], pilotValues: ["": 90]))
        XCTAssertNil(FullTanks.resolve(registration: nil, available: [], pilotValues: [:]))
    }

    func testAnImplausibleFigureIsIgnored() {
        XCTAssertNil(FullTanks.resolve(registration: "HB-PFA", available: [aircraft("HB-PFA", usableFuel: 0)],
                                       pilotValues: ["HB-PFA": 5000]))
        XCTAssertEqual(FullTanks.resolve(registration: "HB-PFA", available: [aircraft("HB-PFA", usableFuel: -1)],
                                         pilotValues: ["HB-PFA": 150])?.source, .pilot)
    }

    /// Each tail of a multi-registration aircraft keeps its own figure through the per-tail split.
    func testEachTailKeepsItsOwnFigure() {
        var dr400 = aircraft("HB-KFD", usableFuel: 110)
        dr400.registrations = [
            RemoteAircraftRegistration(registration: "HB-KFD", modelName: "DR400", shortModelName: "DR400", aeroclub: nil,
                                       version: "1", lastUpdated: "x", availableLanguages: nil, usableFuelLitres: 110),
            RemoteAircraftRegistration(registration: "HB-KFI", modelName: "DR400", shortModelName: "DR400", aeroclub: nil,
                                       version: "1", lastUpdated: "x", availableLanguages: nil, usableFuelLitres: 160),
        ]
        let tails = dr400.expandedPerRegistration()
        XCTAssertEqual(FullTanks.resolve(registration: "HB-KFI", available: tails, pilotValues: [:])?.litres, 160)
        XCTAssertEqual(FullTanks.resolve(registration: "HB-KFD", available: tails, pilotValues: [:])?.litres, 110)
    }

    func testTheListDecodesTheFieldAndOlderResponsesWithout() throws {
        let with = try JSONDecoder().decode(RemoteAircraftMetadata.self, from: Data(#"""
        {"id":"pa28-181","aircraftType":"PA28","registration":"HB-PFA","modelName":"Piper Archer",
         "shortModelName":"PA-28","version":"1.0","lastUpdated":"x","isFree":false,"stallSpeed":53,
         "pageCount":4,"hasAccess":true,"usableFuelLitres":181.7}
        """#.utf8))
        XCTAssertEqual(with.usableFuelLitres, 181.7)
        let without = try JSONDecoder().decode(RemoteAircraftMetadata.self, from: Data(#"""
        {"id":"pa28-181","aircraftType":"PA28","registration":"HB-PFA","modelName":"Piper Archer",
         "shortModelName":"PA-28","version":"1.0","lastUpdated":"x","isFree":false,"stallSpeed":53,
         "pageCount":4,"hasAccess":true}
        """#.utf8))
        XCTAssertNil(without.usableFuelLitres)
    }

    // MARK: - The margin

    func testTheMarginInLitresAndMinutes() {
        XCTAssertEqual(FuelOnBoardStatus.make(onBoard: 60, required: 49.5, flowLitresPerHour: 20),
                       .enough(marginLitres: 10.5, minutes: 31))
        XCTAssertEqual(FuelOnBoardStatus.make(onBoard: 49.5, required: 49.5, flowLitresPerHour: 20),
                       .enough(marginLitres: 0, minutes: 0))
        XCTAssertEqual(FuelOnBoardStatus.make(onBoard: 40, required: 49.5, flowLitresPerHour: 20),
                       .short(litres: 9.5))
    }

    func testNothingOnBoardOrNothingRequiredSaysNothing() {
        XCTAssertEqual(FuelOnBoardStatus.make(onBoard: nil, required: 49.5, flowLitresPerHour: 20), .notSet)
        XCTAssertEqual(FuelOnBoardStatus.make(onBoard: 0, required: 49.5, flowLitresPerHour: 20), .notSet)
        XCTAssertEqual(FuelOnBoardStatus.make(onBoard: 60, required: nil, flowLitresPerHour: 20), .notSet)
    }

    func testMoreThanTheTanksHold() {
        XCTAssertTrue(FuelOnBoardStatus.exceedsFullTanks(onBoard: 95, fullTanks: 90))
        XCTAssertFalse(FuelOnBoardStatus.exceedsFullTanks(onBoard: 90, fullTanks: 90))
        XCTAssertFalse(FuelOnBoardStatus.exceedsFullTanks(onBoard: 95, fullTanks: nil))
    }

    // MARK: - Entry

    func testAnEntryReadsWithAPointOrAComma() {
        XCTAssertEqual(FuelEntry.litres(from: "60"), 60)
        XCTAssertEqual(FuelEntry.litres(from: " 60.5 "), 60.5)
        XCTAssertEqual(FuelEntry.litres(from: "60,5"), 60.5)
        XCTAssertNil(FuelEntry.litres(from: ""))
        XCTAssertNil(FuelEntry.litres(from: "sixty"))
        XCTAssertNil(FuelEntry.litres(from: "-5"))
        XCTAssertEqual(FuelEntry.text(90), "90")
        XCTAssertEqual(FuelEntry.text(181.7), "181.7")
    }

    // MARK: - The pilot's figure in the settings

    func testThePilotsFiguresSurviveAnOlderWriter() {
        var local = AppSettings()
        local.fullTanksLitres = ["F-HVXA": 90]
        var incoming = AppSettings()
        incoming.schemaVersion = 4
        incoming.pilotName = "Edited on the iPhone"
        let merged = local.preservingFieldsUnknownTo(incoming)
        XCTAssertEqual(merged.fullTanksLitres, ["F-HVXA": 90], "a schema-4 writer can't carry them")
        XCTAssertEqual(merged.pilotName, "Edited on the iPhone", "but what it can carry, it still decides")
    }

    func testASameSchemaPeerIsTakenAtItsWord() {
        var local = AppSettings()
        local.fullTanksLitres = ["F-HVXA": 90]
        var incoming = AppSettings()
        incoming.fullTanksLitres = [:]
        XCTAssertTrue(local.preservingFieldsUnknownTo(incoming).fullTanksLitres.isEmpty)
    }

    func testAnImplausibleSyncedFigureIsDropped() {
        var incoming = AppSettings()
        incoming.fullTanksLitres = ["F-HVXA": 90, "HB-PFA": -3, "HB-SYI": 99_999]
        XCTAssertEqual(incoming.clampedForIngest().fullTanksLitres, ["F-HVXA": 90])
    }

    func testTheFiguresRoundTrip() throws {
        var settings = AppSettings()
        settings.fullTanksLitres = ["F-HVXA": 90]
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.fullTanksLitres, ["F-HVXA": 90])
    }

    // MARK: - The 45-minute reserve

    /// The editor showed 45 minutes of fuel in the final-reserve field while Required counted a
    /// stored 0 for it: Required read 15 L short of the sum on screen.
    func testTheFinalReserveRequiredCountsIsTheOneOnScreen() {
        var plan = FlightPlan()
        plan.aircraftTypeId = "WT9"
        plan.tripFuel = 34.5
        plan.additionalFuel = 0
        XCTAssertEqual(plan.finalReserveFuel, 15)
        XCTAssertEqual(plan.fuelRequired, 49.5)
        plan.additionalFuel = nil
        XCTAssertEqual(plan.fuelRequired, 49.5)
        plan.additionalFuel = 20
        XCTAssertEqual(plan.fuelRequired, 54.5)
        plan.fuelFlow = 30
        plan.additionalFuel = nil
        XCTAssertEqual(plan.finalReserveFuel, 22.5)
    }
}
