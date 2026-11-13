import XCTest
@testable import AeroCheck

/// The pilot's own figures for an aircraft the app has no data for (6.11.0): a draft becomes data only
/// when nothing is missing, in the manual's own units, and the sheet computes with it as with a file.
/// Invented figures only.
final class MassBalanceOwnFiguresTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_763_000_000)

    /// The invented two-seater of the other suites, as a pilot would type it.
    private func twoSeater() -> MassBalanceOwnDraft {
        var draft = MassBalanceOwnDraft()
        draft.maxTakeoff = 600
        draft.rows = [.init(arm: 3.10, seats: 2)]
        draft.baggage = [.init(arm: 3.80, max: 40)]
        draft.fuelArm = 2.50
        draft.fuelUsable = 90
        draft.corners = [(2.70, 400), (2.70, 540), (2.75, 600), (2.85, 600), (2.85, 460), (2.72, 400)]
            .map { .init(arm: $0.0, mass: $0.1) }
        draft.emptyMass = 330
        draft.emptyMoment = 867.9
        draft.emptyDate = now
        return draft
    }

    func testABlankFormIsMissingEverythingAndIsNoData() {
        let draft = MassBalanceOwnDraft()
        XCTAssertEqual(draft.missing, [.maxTakeoff, .seatArm(row: 1), .fuel, .envelope, .empty])
        XCTAssertNil(draft.data(registration: "T-EST"))
        XCTAssertNil(draft.empty())
        XCTAssertEqual(draft.fuelDensityKgPerLitre, 0.72, "the one figure it starts with, and it shows")
    }

    func testAWholeFormIsTheDataTheSheetComputesWith() throws {
        let draft = twoSeater()
        XCTAssertEqual(draft.missing, [])
        let data = try XCTUnwrap(draft.data(registration: "t-est", updated: now))
        XCTAssertTrue(data.isUsable)
        XCTAssertEqual(data.registration, "T-EST")
        XCTAssertEqual(data.aircraftId, MassBalanceOwnDraft.aircraftId)
        XCTAssertEqual(data.seatStations.first?.seats?.map(\.role), [.pilot, .passenger])
        XCTAssertEqual(data.baggageStations.first?.max, 40)
        XCTAssertEqual(data.usableFuelLitres ?? 0, 90, accuracy: 0.001)
        XCTAssertEqual(data.fuelStation?.density ?? 0, 0.72, accuracy: 0.0001)

        // The same load, worked by hand in the other suites: 460.2 kg at 2.714 m, inside.
        let load = MassBalanceLoad(seats: ["row1seat1": .person(kg: 82), "row1seat2": .empty], baggageKg: ["baggage1": 5],
                                   fuelLitres: 60, isTodays: true)
        let result = MassBalanceCalculator.compute(data: data, empty: draft.empty(), load: load, isConfirmed: true)
        XCTAssertEqual(result.verdict, .insideLimits)
        XCTAssertEqual(result.takeoff?.mass ?? 0, 330 + 82 + 5 + 60 * 0.72, accuracy: 0.001)
        XCTAssertEqual(result.takeoff?.arm ?? 0, 2.7143, accuracy: 0.0005)
    }

    func testFiguresInPoundsInchesAndGallonsKeepTheirUnitsAndTheDensityIsConverted() throws {
        var draft = MassBalanceOwnDraft()
        draft.units = .init(mass: .lb, arm: .inch, fuel: .usGallon)
        draft.maxTakeoff = 2400
        draft.rows = [.init(arm: 80, seats: 2), .init(arm: 118, seats: 2)]
        draft.baggage = [.init(arm: 140, max: 200)]
        draft.fuelArm = 95
        draft.fuelUsable = 50
        draft.corners = [(80, 1200), (80, 2000), (86, 2400), (92, 2400), (92, 1200)].map { .init(arm: $0.0, mass: $0.1) }
        draft.emptyMass = 1500
        draft.emptyMoment = 130_500
        XCTAssertEqual(draft.missing, [])
        let data = try XCTUnwrap(draft.data(registration: "T-EST"))
        // 0.72 kg/L is 6.01 lb per US gallon.
        XCTAssertEqual(data.fuelStation?.density ?? 0, 6.009, accuracy: 0.002)
        XCTAssertEqual(data.usableFuelLitres ?? 0, 189.27, accuracy: 0.01)
        XCTAssertEqual(data.seatStations.map { $0.seats?.count }, [2, 2])
        XCTAssertEqual(MassBalanceWords.seatName(data.seatStations[1].seats![0], in: data), L10n.MassBalance.seatRearLeft)
    }

    func testThePilotCanSitInTheRearOfATandem() throws {
        var draft = twoSeater()
        draft.rows = [.init(arm: 2.9, seats: 1), .init(arm: 3.6, seats: 1)]
        draft.pilotRow = 1
        let data = try XCTUnwrap(draft.data(registration: "T-EST"))
        XCTAssertEqual(data.seatStations.map(\.layout), [.tandem, .tandem])
        XCTAssertEqual(data.seatStations.map { $0.seats?.first?.role }, [.passenger, .pilot])
        XCTAssertTrue(data.isUsable)
    }

    func testAHalfTypedRowIsMissingNotZero() {
        var draft = twoSeater()
        draft.corners.append(.init(arm: 2.80, mass: nil))
        XCTAssertEqual(draft.missing, [.envelope], "a corner with one figure is not a corner, and not ignored")
        XCTAssertNil(draft.data(registration: "T-EST"))

        draft = twoSeater()
        draft.baggage.append(.init(arm: 4.2, max: nil))
        XCTAssertEqual(draft.missing, [.baggage(area: 2)])
        draft.baggage.removeLast()
        draft.rows.append(.init(arm: nil, seats: 2))
        XCTAssertEqual(draft.missing, [.seatArm(row: 2)])
        draft.rows.removeLast()
        draft.fuelDensityKgPerLitre = nil
        XCTAssertEqual(draft.missing, [.fuel])
    }

    /// The slip a handwritten record invites: the moment as its column writes it, divided by 100.
    func testAMomentAHundredTimesTooSmallIsRefusedOnceTheRestIsWhole() {
        var draft = twoSeater()
        draft.emptyMoment = 8.679
        XCTAssertEqual(draft.missing, [.emptyImplausible])
        draft.emptyMoment = 867.9
        XCTAssertEqual(draft.missing, [])
    }

    func testFiguresTypedBeforeComeBackAsTheyWere() throws {
        let draft = twoSeater()
        let data = try XCTUnwrap(draft.data(registration: "T-EST", updated: now))
        var again = MassBalanceOwnDraft(data: data, empty: draft.empty())
        XCTAssertEqual(again.data(registration: "T-EST", updated: now), data)
        XCTAssertEqual(again.empty(), draft.empty())
        XCTAssertEqual(again.fuelDensityKgPerLitre ?? 0, 0.72, accuracy: 0.0005)
        again.pilotRow = 0
        XCTAssertEqual(again.missing, [])
    }

    /// The 5.0.0 calculator's figures give what they say without a guess, and no more.
    func testTheOldCalculatorsFiguresAreTakenOverWhereTheySayWhatTheyAre() {
        let fuel = WeightBalanceStation(name: "Essence", armMeters: 2.5, weightKg: 40)
        let profile = WeightBalanceProfile(
            emptyWeightKg: 330, emptyArmMeters: 2.63, maxTakeoffWeightKg: 600,
            stations: [WeightBalanceStation(name: "Devant", armMeters: 3.1, weightKg: 160), fuel],
            envelope: [EnvelopePoint(armMeters: 2.70, weightKg: 400), EnvelopePoint(armMeters: 2.70, weightKg: 540),
                       EnvelopePoint(armMeters: 2.85, weightKg: 600), EnvelopePoint(armMeters: 2.85, weightKg: 460)],
            fuelStationId: fuel.id)
        let draft = MassBalanceOwnDraft(profile: profile)
        XCTAssertEqual(draft.units, .init(mass: .kg, arm: .m, fuel: .litre))
        XCTAssertEqual(draft.maxTakeoff, 600)
        XCTAssertEqual(draft.enteredCorners.count, 4)
        XCTAssertEqual(draft.emptyMass, 330)
        XCTAssertEqual(draft.emptyMoment ?? 0, 867.9, accuracy: 0.001)
        XCTAssertEqual(draft.fuelArm, 2.5)
        // A station named "Devant" has an arm but no kind: whether it is a seat row is the pilot's to say.
        XCTAssertEqual(draft.missing, [.seatArm(row: 1), .fuel])
        XCTAssertNil(draft.rows.first?.arm)
    }

    func testOwnFiguresAreABasisOfThePilotsAndAskAgainAfterAYear() throws {
        let draft = twoSeater()
        var setup = MassBalanceSetup()
        setup.ownData = try XCTUnwrap(draft.data(registration: "T-EST", updated: now))
        XCTAssertEqual(setup.basis(shipped: nil, now: now)?.unconfirmed, .never)
        setup.ownConfirmedAt = now
        let basis = try XCTUnwrap(setup.basis(shipped: nil, now: now))
        XCTAssertEqual(basis.source, .pilot)
        XCTAssertTrue(basis.isConfirmed)
        XCTAssertEqual(basis.empty?.mass, 330)
        XCTAssertEqual(setup.basis(shipped: nil, now: now.addingTimeInterval(366 * 86_400))?.unconfirmed, .yearPassed)
    }
}
