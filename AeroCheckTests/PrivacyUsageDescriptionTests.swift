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

    // MARK: - French purpose strings (S9-34)

    private static let purposeKeys = [
        "NSLocationAlwaysAndWhenInUseUsageDescription",
        "NSLocationWhenInUseUsageDescription",
        "NSMotionUsageDescription",
        "NSPhotoLibraryAddUsageDescription",
    ]

    private func infoPlistStrings(_ localization: String) -> [String: String]? {
        guard let path = Bundle.main.path(forResource: "InfoPlist", ofType: "strings",
                                          inDirectory: nil, forLocalization: localization) else { return nil }
        return NSDictionary(contentsOfFile: path) as? [String: String]
    }

    /// The permission prompts explain background location, motion and photos: a French-speaking
    /// pilot read them in English only.
    func testEveryPurposeStringHasAFrenchTranslation() throws {
        let french = try XCTUnwrap(infoPlistStrings("fr"), "fr.lproj/InfoPlist.strings must ship")
        for key in Self.purposeKeys {
            let english = try usageDescription(key)
            let translated = try XCTUnwrap(french[key], "\(key) has no French translation")
            XCTAssertFalse(translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, key)
            XCTAssertNotEqual(translated, english, "\(key) is still the English text")
        }
    }

    /// English comes from the Info.plist alone. An English copy in the catalog would win over it,
    /// and an edit to the Info.plist would then never reach the prompt.
    func testEnglishPurposeStringsAreTheInfoPlistOnes() throws {
        guard let english = infoPlistStrings("en") else { return }
        for key in Self.purposeKeys {
            guard let value = english[key] else { continue }
            XCTAssertEqual(value, Bundle.main.infoDictionary?[key] as? String,
                           "\(key): InfoPlist.xcstrings and the Info.plist disagree")
        }
    }

    // MARK: - Privacy manifests (S9-32, S9-33)

    private func manifest(at url: URL?) throws -> [String: Any] {
        let url = try XCTUnwrap(url, "privacy manifest missing from the bundle")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    private func collected(_ manifest: [String: Any], _ type: String) -> [String: Any]? {
        (manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]])?
            .first { $0["NSPrivacyCollectedDataType"] as? String == type }
    }

    private func reasons(_ manifest: [String: Any], _ category: String) -> [String] {
        (manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])?
            .first { $0["NSPrivacyAccessedAPIType"] as? String == category }?["NSPrivacyAccessedAPITypeReasons"]
            as? [String] ?? []
    }

    /// The server keeps the entitlement record under the purchase's originalTransactionId: purchase
    /// history linked to the user, and a user ID.
    func testTheAppManifestDeclaresPurchasesAndAUserIDAsLinked() throws {
        let app = try manifest(at: Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))

        let purchases = try XCTUnwrap(collected(app, "NSPrivacyCollectedDataTypePurchaseHistory"))
        XCTAssertEqual(purchases["NSPrivacyCollectedDataTypeLinked"] as? Bool, true)
        let userID = try XCTUnwrap(collected(app, "NSPrivacyCollectedDataTypeUserID"))
        XCTAssertEqual(userID["NSPrivacyCollectedDataTypeLinked"] as? Bool, true)
        XCTAssertEqual(userID["NSPrivacyCollectedDataTypeTracking"] as? Bool, false)
        XCTAssertEqual(userID["NSPrivacyCollectedDataTypePurposes"] as? [String],
                       ["NSPrivacyCollectedDataTypePurposeAppFunctionality"])
        XCTAssertEqual(app["NSPrivacyTracking"] as? Bool, false)
        XCTAssertTrue(reasons(app, "NSPrivacyAccessedAPICategoryUserDefaults").contains("1C8F.1"),
                      "the app writes the App Group defaults the widget reads")
    }

    /// The widget is a binary of its own and reads the App Group defaults, so it needs its own
    /// manifest, in its own bundle.
    func testTheWidgetShipsItsOwnPrivacyManifest() throws {
        let widget = try manifest(at: Bundle.main.builtInPlugInsURL?
            .appendingPathComponent("AeroCheckWidgetExtension.appex/PrivacyInfo.xcprivacy"))

        XCTAssertEqual(reasons(widget, "NSPrivacyAccessedAPICategoryUserDefaults"), ["1C8F.1"])
        XCTAssertEqual(widget["NSPrivacyTracking"] as? Bool, false)
    }
}
