import XCTest
@testable import AeroCheck

/// Tests identity-log redaction (SEC-19), GPX import XML hardening (SEC-20), the numbers a GPX file
/// may carry (S9-10), and the flight-archive (ZIP) budgets (SA-24, S9-29).
@MainActor
final class GPXImportHygieneTests: XCTestCase {

    private func sampleFlight() -> Flight {
        Flight(gpsTrack: [
            GPSPoint(latitude: 47.0, longitude: 8.0, altitude: 500, timestamp: Date(timeIntervalSince1970: 0)),
            GPSPoint(latitude: 47.1, longitude: 8.1, altitude: 600, timestamp: Date(timeIntervalSince1970: 60)),
        ])
    }

    // MARK: - SEC-19: identity redaction

    func testRedactedIdentifierKeepsOnlyAShortSuffix() {
        XCTAssertEqual(SubscriptionManager.redactedIdentifier("ABCDEFGH1234"), "****1234")
        XCTAssertEqual(SubscriptionManager.redactedIdentifier("xy"), "****")
        XCTAssertFalse(
            SubscriptionManager.redactedIdentifier("sensitive-user-id-9999").contains("sensitive"),
            "The full identifier must never appear in the redacted form"
        )
    }

    // MARK: - SEC-20: GPX XML hardening

    func testValidGPXStillImportsAfterHardening() {
        let gpx = sampleFlight().toGPX()
        let parsed = GPXParser(data: Data(gpx.utf8)).parse()
        XCTAssertEqual(parsed?.gpsTrack.count, 2, "A valid GPX still imports after the XXE hardening")
    }

    func testUserStringsWithXMLCharactersStillExportAndImport() {
        // PR-18: a flight named "Touch & Go" (or with < > " ' or "]]>" in notes) previously
        // interpolated raw into the GPX, producing malformed XML that XMLParser aborts on.
        var flight = sampleFlight()
        flight.name = "Touch & Go <test> \"q\" 'a'"
        flight.airplane = "WT9 & Friends <X>"
        flight.notes = "note with ]]> and <tag> & ampersand"
        let gpx = flight.toGPX()
        let parsed = GPXParser(data: Data(gpx.utf8)).parse()
        XCTAssertEqual(parsed?.gpsTrack.count, 2,
                       "GPX with XML-special characters in name/airplane/notes must still be well-formed and import")
    }

    func testExternalEntityDoctypeDoesNotBreakOrInjectIntoImport() {
        // Inject a DOCTYPE declaring an external entity into otherwise-valid GPX.
        let withDoctype = sampleFlight().toGPX().replacingOccurrences(
            of: #"<?xml version="1.0" encoding="UTF-8"?>"#,
            with: #"<?xml version="1.0" encoding="UTF-8"?>"# + "\n"
                + #"<!DOCTYPE gpx [<!ENTITY xxe SYSTEM "file:///etc/hostname">]>"#
        )
        let parsed = GPXParser(data: Data(withDoctype.utf8)).parse()
        // External entities are not resolved; the two valid track points still parse and nothing
        // external is fetched/injected.
        XCTAssertEqual(parsed?.gpsTrack.count, 2)
    }

    // MARK: - S9-10: engine hours

    /// `Double(_:)` reads "nan", "inf" and "1e300" as numbers, and the Logbook then trapped on them.
    func testAnEngineHourReadingMustBeOneAMeterCanShow() {
        for text in ["nan", "inf", "-inf", "1e300", "-3", "100000.1", "", "12:30"] {
            XCTAssertNil(GPXParser.engineHourReading(text), "\(text) is not a reading")
        }
        XCTAssertEqual(GPXParser.engineHourReading("1234.50"), 1234.5)
        XCTAssertEqual(GPXParser.engineHourReading("0"), 0)
    }

    func testNonFiniteEngineHoursInAGPXAreDroppedAndRealOnesKept() throws {
        var flight = sampleFlight()
        flight.engineHourStart = .nan
        flight.engineHourEnd = .infinity
        let poisoned = flight.toGPX()
        XCTAssertTrue(poisoned.contains("<pc:engineHourStart>nan</pc:engineHourStart>"), "precondition")
        XCTAssertTrue(poisoned.contains("<pc:engineHourEnd>inf</pc:engineHourEnd>"), "precondition")

        let parsed = try XCTUnwrap(GPXParser(data: Data(poisoned.utf8)).parse())
        XCTAssertNil(parsed.engineHourStart)
        XCTAssertNil(parsed.engineHourEnd)
        XCTAssertNil(parsed.engineHoursFlownFormatted)

        flight.engineHourStart = 1234.5
        flight.engineHourEnd = 1235.75
        let imported = try XCTUnwrap(Flight.fromGPX(Data(flight.toGPX().utf8)))
        XCTAssertEqual(imported.engineHourStart, 1234.5)
        XCTAssertEqual(imported.engineHourEnd, 1235.75)
        XCTAssertEqual(imported.engineHoursFlownFormatted, "1.25 / 1:15")
    }

    // MARK: - SA-24 / S9-29: flight archive (ZIP) budgets

    /// One local file entry laid out as a ZIP writer lays it out; the reader needs nothing more.
    private func zipEntry(_ name: String, payload: Data, method: UInt16, declaredSize: Int) -> Data {
        var entry = Data([0x50, 0x4B, 0x03, 0x04, 0x14, 0x00, 0x00, 0x00]) // signature, version, flags
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { entry.append(contentsOf: $0) }
        }
        let nameData = Data(name.utf8)
        append(method)
        append(UInt16(0)); append(UInt16(0))            // time, date
        append(UInt32(0))                               // CRC: the reader does not check it
        append(UInt32(payload.count)); append(UInt32(declaredSize))
        append(UInt16(nameData.count)); append(UInt16(0))
        entry.append(nameData)
        entry.append(payload)
        return entry
    }

    private func deflated(_ data: Data) throws -> Data {
        try (data as NSData).compressed(using: .zlib) as Data
    }

    func testADeflatedFlightInAnArchiveInflatesToItsDeclaredSize() throws {
        let json = try XCTUnwrap(sampleFlight().toJSON())
        let archive = zipEntry("flight.json", payload: try deflated(json), method: 8, declaredSize: json.count)

        let entries = try FlightLogView.extractZipEntries(from: archive)

        XCTAssertEqual(entries.map(\.filename), ["flight.json"])
        XCTAssertEqual(entries.first?.data, json)
    }

    func testAnArchiveTheAppWroteStillImports() throws {
        let archive = try XCTUnwrap(FlightLogView.buildExportAllZip(flights: [sampleFlight(), sampleFlight()], type: .json))
        let entries = try FlightLogView.extractZipEntries(from: archive)
        XCTAssertEqual(entries.count, 2)
        XCTAssertNotNil(Flight.fromJSONOptional(try XCTUnwrap(entries.first?.data)))
    }

    /// The bomb: 64 MB of zeros deflate to about 64 KB, under a header that says 1 KB. Inflated whole
    /// and measured afterwards, as it was, the entry took its full size in memory first (and a 32 MB
    /// archive, 32 GB). It is abandoned now within one buffer of its declared size.
    func testAnEntryThatOutgrowsItsDeclaredSizeIsStoppedEarly() throws {
        let bomb = try deflated(Data(count: 64 * 1024 * 1024))
        let archive = zipEntry("flight.json", payload: bomb, method: 8, declaredSize: 1024)

        XCTAssertThrowsError(try FlightLogView.extractZipEntries(from: archive)) { error in
            XCTAssertEqual(error as? FlightLogView.ZipImportError, .sizeMismatch)
        }
        XCTAssertThrowsError(try FlightLogView.inflate(bomb, limit: 1024)) { error in
            let produced = (error as? FlightLogView.InflateLimitExceeded)?.producedBytes ?? .max
            XCTAssertLessThanOrEqual(produced, 1024 + 64 * 1024, "stopped one buffer past the limit, not at 64 MB")
        }
    }

    /// A declared size of 0 skipped the size check altogether.
    func testADeclaredSizeOfZeroNoLongerWavesAnEntryThrough() throws {
        let json = try XCTUnwrap(sampleFlight().toJSON())
        let archive = zipEntry("flight.json", payload: try deflated(json), method: 8, declaredSize: 0)

        XCTAssertThrowsError(try FlightLogView.extractZipEntries(from: archive)) { error in
            XCTAssertEqual(error as? FlightLogView.ZipImportError, .sizeMismatch)
        }
    }

    func testATruncatedDeflateStreamIsRefused() throws {
        let json = try XCTUnwrap(sampleFlight().toJSON())
        let stream = try deflated(json)
        XCTAssertThrowsError(try FlightLogView.inflate(stream.prefix(stream.count / 2), limit: json.count))
        XCTAssertThrowsError(try FlightLogView.inflate(Data(), limit: json.count))
    }
}
