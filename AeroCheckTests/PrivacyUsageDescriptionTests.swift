import CoreMotion
import XCTest
@testable import AeroCheck

/// Locks the TCC usage descriptions the app's Info.plist must declare.
///
/// A privacy-protected API called from a bundle that does not declare its usage-description key
/// does not return an error — iOS **terminates the process**, uncatchably. `CompanionServiceContractTests`
/// guards the same class of Info.plist-induced crash for Wi-Fi Aware; this file guards the TCC keys.
///
/// The regression that produced it: 4.4.0 added `BarometricAltitudeService` (CoreMotion `CMAltimeter`),
/// which `LocationManager.beginTrackingNow()` starts alongside GPS — i.e. on the first tap of
/// START FLIGHT — without `NSMotionUsageDescription` ever being added. Every barometer-equipped
/// device crashed there, 100% of the time. Nothing caught it before release because the simulator has
/// no barometer: `CMAltimeter.isRelativeAltitudeAvailable()` is false, so `start()` returns early and
/// the protected call is never reached in the simulator or in this suite.
@MainActor
final class PrivacyUsageDescriptionTests: XCTestCase {

    private func usageDescription(_ key: String) throws -> String {
        let value = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: key) as? String,
            "Info.plist must declare \(key) — iOS terminates the process when the matching API is used without it")
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// CoreMotion (`CMAltimeter`) — started by `LocationManager` on every flight start.
    func testMotionUsageDescriptionIsDeclared() throws {
        XCTAssertFalse(try usageDescription("NSMotionUsageDescription").isEmpty,
                       "NSMotionUsageDescription must be non-empty — CMAltimeter crashes the app on flight start without it")
    }

    /// CoreLocation — the GPS track is the app's core function.
    func testLocationUsageDescriptionsAreDeclared() throws {
        XCTAssertFalse(try usageDescription("NSLocationWhenInUseUsageDescription").isEmpty)
        XCTAssertFalse(try usageDescription("NSLocationAlwaysAndWhenInUseUsageDescription").isEmpty)
    }

    /// Photos — flight-log share cards are saved to the library.
    func testPhotoLibraryAddUsageDescriptionIsDeclared() throws {
        XCTAssertFalse(try usageDescription("NSPhotoLibraryAddUsageDescription").isEmpty)
    }

    /// The service's own guard must agree with the bundle, so the "degrade to GPS-only" fallback
    /// can never silently disable the barometer on a correctly-configured build.
    func testBarometerServiceAgreesTheBundlePermitsCoreMotion() {
        XCTAssertTrue(BarometricAltitudeService.isPermittedByBundle,
                      "BarometricAltitudeService must see the declared NSMotionUsageDescription")
    }

    /// Documents why this suite cannot exercise the crash itself: the simulator has no barometer.
    func testSimulatorHasNoBarometerSoTheProtectedCallIsUnreachableHere() {
        XCTAssertEqual(BarometricAltitudeService.isAvailable,
                       CMAltimeter.isRelativeAltitudeAvailable(),
                       "availability must track the sensor, which is absent on the simulator")
    }
}
