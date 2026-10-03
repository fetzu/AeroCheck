import XCTest
import MapKit
@testable import AeroCheck

/// The open flightmaps VFR data (6.2.0): the published files' decoding, the download (index first, only
/// what changed, checksums, size and host limits, prune with the union), freshness by AIRAC cycle, the
/// queries the map will use, and the Data & Storage row. Fixtures are cut from the real AIRAC 2610 files
/// (CH and DE, © open flightmaps association); the services run in temporary directories and never
/// touch the network.
@MainActor
final class VFRDataTests: XCTestCase {

    // MARK: - Fixtures (AIRAC 2610, cut small)

    /// Switzerland: LSZQ's circuit and two arrival sectors, LSGC, a heavy circuit (LSGR), a glider
    /// circuit (LSZB), LSZH's helicopter arrival and departure (one OFM id for both), and four
    /// procedures no build can use: an unknown kind, a line with one usable point, no aerodrome, an
    /// unknown category. ARR SEKTOR WEST carries a bad position and a two-point area, both dropped alone.
    private func swissFile(airac: String = "2610", validFrom: String = "2026-10-01", validTo: String = "2026-10-29") -> Data {
        Data("""
        { "v": 1, "source": "open flightmaps", "attribution": "© open flightmaps association (openflightmaps.org)",
          "region": "LSAS", "country": "CH", "airac": "\(airac)", "validFrom": "\(validFrom)", "validTo": "\(validTo)",
          "ofmCreated": "2026-09-26T01:19:31Z",
          "procedures": [
            {"id": "f2fbd4ca-1edb-354d-414d-28863037c1ea", "ad": "LSZQ", "kind": "circuit", "name": "TC", "use": "fw", "cat": null, "alt": 2900,
             "line": [[7.03373, 47.39356], [7.05466, 47.39851], [7.05579, 47.4001], [7.04636, 47.41809], [7.044, 47.41884], [6.98485, 47.40447], [6.98375, 47.40284], [6.99369, 47.38507], [6.99602, 47.38434], [7.02427, 47.39125]]},
            {"id": "b14a1c24-a583-8fc1-252c-8324d6d5b6f8", "ad": "LSZQ", "kind": "arr", "name": "ARR SECTOR EAST", "use": "fw", "cat": null,
             "line": [[7.10158, 47.38718], [7.07828, 47.39336], [7.05721, 47.39871], [7.05612, 47.39946], [7.04636, 47.41809]],
             "areas": [{"kind": "corridor", "poly": [[7.10449, 47.39655], [7.07946, 47.39518], [7.07946, 47.39206], [7.09685, 47.38044]]}]},
            {"id": "2a11d4aa-2772-c870-cc07-25ca6cf4d54f", "ad": "LSZQ", "kind": "arr", "name": "ARR SEKTOR WEST", "use": "fw", "cat": null,
             "line": [[6.94334, 47.37823], [6.97003, 47.38313], [6.98894, "x"], [6.99462, 47.384], [7.02427, 47.39125]],
             "areas": [{"kind": "corridor", "poly": [[6.94328, 47.38543], [6.96472, 47.38543], [6.96731, 47.37839], [6.94718, 47.37312]]},
                       {"kind": "corridor", "poly": [[6.9, 47.3], [6.91, 47.31]]}]},
            {"id": "056601d3-f3ea-67f6-534c-098907b797d6", "ad": "LSGC", "kind": "circuit", "name": "TFC", "use": "fw", "cat": null, "alt": 4200,
             "line": [[6.79802, 47.08639], [6.81304, 47.09377], [6.81589, 47.09345], [6.82779, 47.08222], [6.789, 47.06145], [6.77229, 47.07204], [6.78776, 47.08136]]},
            {"id": "fe731546-989c-258b-218b-dba8b8aa3ff4", "ad": "LSGR", "kind": "circuit", "name": "TC MULTI", "use": "fw", "cat": "heavy", "alt": 3500,
             "line": [[7.68155, 46.61693], [7.69123, 46.65887], [7.67561, 46.65771], [7.65353, 46.60322], [7.67584, 46.61202]]},
            {"id": "f4efc4c8-2db7-5a53-e5a8-0c5663e38b10", "ad": "LSZB", "kind": "circuit", "name": "TFC GLIDER 14R/32L", "use": "fw", "cat": "glider",
             "line": [[7.5, 46.90971], [7.50953, 46.90084], [7.50167, 46.89622], [7.47911, 46.91448], [7.49447, 46.9142]]},
            {"id": "557a727b-340a-606f-81e2-1624fc612d7c", "ad": "LSZH", "kind": "arr", "name": "ECHO (REGA)", "use": "heli", "cat": "heli",
             "line": [[8.79, 47.53194], [8.70191, 47.52419], [8.63683, 47.50422], [8.57094, 47.45781]]},
            {"id": "557a727b-340a-606f-81e2-1624fc612d7c", "ad": "LSZH", "kind": "dep", "name": "ECHO (REGA)", "use": "heli", "cat": "heli",
             "line": [[8.57093, 47.45775], [8.63686, 47.50423], [8.79, 47.53194]]},
            {"id": "broken-kind", "ad": "LSZH", "kind": "transit", "name": "TRANSIT", "use": "fw", "cat": null, "line": [[8.5, 47.4], [8.6, 47.5]]},
            {"id": "broken-line", "ad": "LSZQ", "kind": "circuit", "name": "TC", "use": "fw", "cat": null, "line": [[7.0, 47.4], [7.1, 95.0]]},
            {"id": "broken-ad", "kind": "circuit", "name": "TC", "use": "fw", "cat": null, "line": [[7.0, 47.4], [7.1, 47.5]]},
            {"id": "broken-cat", "ad": "LSZQ", "kind": "circuit", "name": "BALLOON", "use": "fw", "cat": "balloon", "line": [[7.0, 47.4], [7.1, 47.5]]}
          ],
          "points": [
            {"id": "9861b91d-aef5-0a47-aa21-ecaca301a8be", "name": "CHABREY", "kind": "rp", "lat": 46.93028, "lon": 6.99917, "inOpenAIP": true},
            {"id": "d9ba5787-c040-996c-7acf-a7303dbf53df", "name": "MURTEN", "kind": "rp", "lat": 46.91191, "lon": 7.1446, "inOpenAIP": true},
            {"id": "d14d63e6-8d9c-36a9-b4c2-74dc662015db", "name": "E", "kind": "mrp", "ad": "LSGG", "lat": 46.34722, "lon": 6.36306, "inOpenAIP": true},
            {"id": "broken-position", "name": "NOWHERE", "kind": "rp", "lat": 200, "lon": 7.0, "inOpenAIP": false},
            {"id": "broken-kind", "name": "BALLOON", "kind": "balloon", "lat": 46.9, "lon": 7.0, "inOpenAIP": false}
          ],
          "runways": { "LSGC": ["05/23"], "LSZQ": ["07/25"], "LSGG": ["05/23", "05L/23R"], "BROKEN": 42 }
        }
        """.utf8)
    }

    /// Germany: a circuit for gliders and ultralights (EDBGH) and two arrivals of Friedrichshafen.
    private func germanFile(airac: String = "2610", validFrom: String = "2026-10-01", validTo: String = "2026-10-29") -> Data {
        Data("""
        { "v": 1, "source": "open flightmaps", "region": "ED", "country": "DE",
          "airac": "\(airac)", "validFrom": "\(validFrom)", "validTo": "\(validTo)",
          "procedures": [
            {"id": "98e5878d-b6af-a8b5-77e7-b806f639db63", "ad": "EDBGH", "kind": "circuit", "name": "UL+GLIDER", "use": "fw", "cat": "glider+ul", "alt": 2000,
             "line": [[11.03626, 48.69021], [11.03772, 48.6892], [11.03769, 48.6887], [11.03424, 48.68655], [11.0335, 48.68657], [11.02526, 48.69231]]},
            {"id": "b4359996-8241-5fd0-4d38-64dc7fd57981", "ad": "EDNY", "kind": "arr", "name": "NOVEMBER-HN", "use": "fw", "cat": null,
             "line": [[9.42335, 47.71759], [9.495, 47.68472]]},
            {"id": "f1753026-6057-77aa-2e2d-9038fb240d0a", "ad": "EDNY", "kind": "arr", "name": "OSCAR-24", "use": "fw", "cat": null,
             "line": [[9.56014, 47.74626], [9.56036, 47.73362], [9.56543, 47.72509], [9.56553, 47.71658]]}
          ],
          "points": [{"id": "3bd52a06-457a-e7a7-bde3-4fb2970be29d", "name": "HN", "kind": "enr", "ad": "EDNY", "lat": 47.68472, "lon": 9.495, "inOpenAIP": false}],
          "runways": { "EDNY": ["06/24"] }
        }
        """.utf8)
    }

    /// aerocheck.app as the tests serve it: `index.json` and the country files, by file name.
    @MainActor
    final class FakeVFRServer {
        private(set) var files: [String: Data] = [:]
        var failing: Set<String> = []
        private(set) var requests: [String] = []

        /// Publish country files with an index whose checksums match them, unless `checksums` says
        /// otherwise for a country.
        func publish(_ countries: [String: Data], airac: String = "2610", validTo: String = "2026-10-29",
                     checksums: [String: String] = [:], urls: [String: String] = [:]) {
            var regions: [String] = []
            for (country, data) in countries.sorted(by: { $0.key < $1.key }) {
                let name = "\(country.lowercased()).json"
                files[name] = data
                let sha = checksums[country] ?? OFMDataService.sha256(of: data)
                let url = urls[country] ?? "https://aerocheck.app/data/ofm/v1/\(name)"
                regions.append("""
                "\(country)": {"airac": "\(airac)", "validFrom": "2026-10-01", "validTo": "\(validTo)", "url": "\(url)",
                  "sha256": "\(sha)", "bytes": \(data.count), "sourceEtag": "\\"x\\"", "procedures": 3, "points": 1, "flags": []}
                """)
            }
            files["index.json"] = Data("""
            { "v": 1, "generated": "2026-10-02T00:15:33Z", "regions": { \(regions.joined(separator: ",")) },
              "attribution": "© open flightmaps association (openflightmaps.org)",
              "reportForm": {"url": "https://docs.google.com/forms/d/e/x/viewform", "field": "entry.1"},
              "reportMail": "info@openflightmaps.org" }
            """.utf8)
        }

        func fetch(_ url: URL) throws -> Data {
            requests.append(url.lastPathComponent)
            if failing.contains(url.lastPathComponent) { throw URLError(.notConnectedToInternet) }
            guard let data = files[url.lastPathComponent] else { throw OFMDataError.http(404) }
            return data
        }
    }

    private func utc(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    private func region(lat: Double, lon: Double, span: Double = 0.1) -> MKCoordinateRegion {
        MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                           span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span))
    }

    private func service(_ server: FakeVFRServer, root: URL? = nil, now: @escaping () -> Date = Date.init) -> OFMDataService {
        makeTestOFMService(root: root, now: now) { url in try server.fetch(url) }
    }

    private func directory(of root: URL) -> URL {
        root.appendingPathComponent(OFMDataService.directoryName, isDirectory: true)
    }

    // MARK: - Decoding

    func testTheRegionFileDecodesAndDropsOnlyWhatIsBroken() throws {
        let file = try JSONDecoder().decode(OFMRegionFile.self, from: swissFile())
        XCTAssertEqual(file.country, "CH")
        XCTAssertEqual(file.region, "LSAS")
        XCTAssertEqual(file.airac, "2610")
        XCTAssertEqual(file.validFrom, utc("2026-10-01T00:00:00Z"))
        XCTAssertEqual(file.validTo, utc("2026-10-29T00:00:00Z"))
        XCTAssertEqual(file.procedures.count, 8)
        XCTAssertEqual(file.droppedProcedures, 4, "unknown kind, one usable point, no aerodrome, unknown category")

        let circuit = try XCTUnwrap(file.procedures.first { $0.aerodrome == "LSZQ" && $0.kind == .circuit })
        XCTAssertEqual(circuit.name, "TC")
        XCTAssertEqual(circuit.altitudeFt, 2900)
        XCTAssertEqual(circuit.categories, [.powered])
        XCTAssertEqual(circuit.usage, .fixedWing)
        XCTAssertEqual(circuit.line.count, 10)
        XCTAssertEqual(circuit.line.first, VFRCoordinate(latitude: 47.39356, longitude: 7.03373), "[lon, lat] pairs")
        XCTAssertFalse(circuit.isApproximate)
        XCTAssertEqual(circuit.ofmId, "f2fbd4ca-1edb-354d-414d-28863037c1ea")

        let east = try XCTUnwrap(file.procedures.first { $0.name == "ARR SECTOR EAST" })
        XCTAssertEqual(east.kind, .arrival)
        XCTAssertNil(east.altitudeFt, "no altitude: see chart")
        XCTAssertEqual(east.areas.map(\.kind), [.corridor])
        XCTAssertEqual(east.areas.first?.polygon.count, 4)
        XCTAssertEqual(east.bounds.maxLongitude, 7.10449, accuracy: 1e-9, "the box reaches the sector")

        let west = try XCTUnwrap(file.procedures.first { $0.name == "ARR SEKTOR WEST" })
        XCTAssertEqual(west.line.count, 4, "the bad position goes, the line stays")
        XCTAssertEqual(west.areas.count, 1, "the two-point area goes, the corridor stays")

        XCTAssertEqual(file.procedures.first { $0.aerodrome == "LSGR" }?.categories, [.heavy])
        XCTAssertEqual(file.procedures.first { $0.aerodrome == "LSZB" }?.categories, [.glider])

        // One OFM id for the arrival and the departure: two procedures, two ids.
        let echo = file.procedures.filter { $0.ofmId == "557a727b-340a-606f-81e2-1624fc612d7c" }
        XCTAssertEqual(echo.map(\.kind), [.arrival, .departure])
        XCTAssertEqual(echo.map(\.categories), [[.helicopter], [.helicopter]])
        XCTAssertEqual(Set(file.procedures.map(\.id)).count, file.procedures.count, "ids are unique")
        XCTAssertEqual(echo.first?.id, "CH:arr:557a727b-340a-606f-81e2-1624fc612d7c")

        XCTAssertEqual(file.points.map(\.name), ["CHABREY", "MURTEN", "E"])
        let e = try XCTUnwrap(file.points.last)
        XCTAssertEqual(e.kind, .compulsory)
        XCTAssertEqual(e.aerodrome, "LSGG")
        XCTAssertTrue(e.inOpenAIP)
        XCTAssertNil(file.points.first?.aerodrome)

        XCTAssertEqual(file.runways["LSGC"], ["05/23"], "LSGC is 05/23")
        XCTAssertEqual(file.runways["LSGG"], ["05/23", "05L/23R"])
        XCTAssertNil(file.runways["BROKEN"])
    }

    /// Two circuits of one field with one OFM id (LOXN, EDVIN in 2610) keep apart, the same way on
    /// every download of the file.
    func testRepeatedOFMIdsGetStableDistinctIds() throws {
        let json = """
        { "country": "AT", "airac": "2610", "validFrom": "2026-10-01", "validTo": "2026-10-29", "procedures": [
          {"id": "1924fcfa", "ad": "LOXN", "kind": "circuit", "name": "14R/32L", "line": [[16.22166, 47.83513], [16.23, 47.84]]},
          {"id": "1924fcfa", "ad": "LOXN", "kind": "circuit", "name": "14R/32L", "line": [[16.22334, 47.83615], [16.23, 47.84]]} ] }
        """
        let file = try JSONDecoder().decode(OFMRegionFile.self, from: Data(json.utf8))
        XCTAssertEqual(file.procedures.map(\.id), ["AT:circuit:1924fcfa", "AT:circuit:1924fcfa#2"])
        XCTAssertTrue(file.points.isEmpty)
        XCTAssertTrue(file.runways.isEmpty)
    }

    func testAFileWithoutCycleOrInAnotherSchemaIsRefused() {
        let decoder = JSONDecoder()
        let noValidity = #"{ "country": "CH", "airac": "2610", "validFrom": "2026-10-01", "procedures": [] }"#
        let otherSchema = #"{ "v": 2, "country": "CH", "airac": "2610", "validFrom": "2026-10-01", "validTo": "2026-10-29" }"#
        let backwards = #"{ "country": "CH", "airac": "2610", "validFrom": "2026-10-29", "validTo": "2026-10-01" }"#
        let badCycle = #"{ "country": "CH", "airac": "26X0", "validFrom": "2026-10-01", "validTo": "2026-10-29" }"#
        for json in [noValidity, otherSchema, backwards, badCycle] {
            XCTAssertThrowsError(try decoder.decode(OFMRegionFile.self, from: Data(json.utf8)), json)
        }
    }

    func testTheIndexDecodesLossily() throws {
        let server = FakeVFRServer()
        server.publish(["CH": swissFile(), "DE": germanFile()])
        var json = String(decoding: try XCTUnwrap(server.files["index.json"]), as: UTF8.self)
        // A broken entry (checksum not hex) and a lower-case country code.
        let lowerCase = #""at": {"airac": "2610", "url": "at.json", "sha256": "\#(String(repeating: "B", count: 64))"}, "#
        json = json.replacingOccurrences(of: #""regions": { "#,
                                         with: #""regions": { "XX": {"airac": "2610", "url": "xx.json", "sha256": "nope"}, "# + lowerCase)
        let index = try JSONDecoder().decode(OFMIndex.self, from: Data(json.utf8))
        XCTAssertEqual(index.countries, ["AT", "CH", "DE"])
        XCTAssertEqual(index.regions["AT"]?.sha256, String(repeating: "b", count: 64), "lower-cased")
        XCTAssertNil(index.regions["AT"]?.bytes)
        let ch = try XCTUnwrap(index.regions["CH"])
        XCTAssertEqual(ch.airac, "2610")
        XCTAssertEqual(ch.validTo, utc("2026-10-29T00:00:00Z"))
        XCTAssertEqual(ch.sha256, OFMDataService.sha256(of: swissFile()))
        XCTAssertEqual(ch.bytes, Int64(swissFile().count))
        XCTAssertEqual(ch.procedures, 3)
        XCTAssertEqual(index.reportForm?.url.absoluteString, "https://docs.google.com/forms/d/e/x/viewform")
        XCTAssertEqual(index.reportForm?.field, "entry.1")
        XCTAssertEqual(index.reportMail, "info@openflightmaps.org")
        XCTAssertEqual(index.attribution, "© open flightmaps association (openflightmaps.org)")
    }

    func testCategoriesAndAltitudes() {
        XCTAssertEqual(VFRProcedure.categories(from: nil, usage: .fixedWing), [.powered])
        XCTAssertEqual(VFRProcedure.categories(from: nil, usage: .helicopter), [.helicopter])
        XCTAssertEqual(VFRProcedure.categories(from: "glider+ul", usage: .fixedWing), [.glider, .ultralight])
        XCTAssertEqual(VFRProcedure.categories(from: "gyro", usage: nil), [.gyro])
        XCTAssertNil(VFRProcedure.categories(from: "balloon", usage: .fixedWing))
        XCTAssertNil(VFRProcedure.categories(from: "glider+balloon", usage: .fixedWing))
        XCTAssertNil(VFRProcedure.categories(from: "powered", usage: .fixedWing), "not a published token")
        XCTAssertEqual(VFRProcedure.plausibleAltitude(2899.6), 2900)
        XCTAssertNil(VFRProcedure.plausibleAltitude(0))
        XCTAssertNil(VFRProcedure.plausibleAltitude(.nan))
        XCTAssertNil(VFRProcedure.plausibleAltitude(40_000))
        XCTAssertTrue(OFMSchema.isCycle("2701", newerThan: "2613"))
        XCTAssertFalse(OFMSchema.isCycle("2610", newerThan: "2610"))
        XCTAssertNil(OFMSchema.day("2026-02-31"))
    }

    // MARK: - Configuration

    func testTheFilesComeFromAerocheckAppOnly() throws {
        let base = OFMConfig.defaultBaseURL
        XCTAssertEqual(OFMConfig.indexURL(base: base).absoluteString, "https://aerocheck.app/data/ofm/v1/index.json")
        XCTAssertEqual(OFMConfig.fileURL(published: "https://aerocheck.app/data/ofm/v1/ch.json", base: base)?.absoluteString,
                       "https://aerocheck.app/data/ofm/v1/ch.json")
        XCTAssertEqual(OFMConfig.fileURL(published: "de.json", base: base)?.absoluteString,
                       "https://aerocheck.app/data/ofm/v1/de.json", "relative to the index")
        XCTAssertEqual(OFMConfig.allowedHosts(override: nil), ["aerocheck.app"])
        XCTAssertEqual(OFMConfig.maxFileBytes, 4 * 1024 * 1024)
        XCTAssertEqual(OFMConfig.region(forCountry: "ch"), "LSAS")
        XCTAssertEqual(OFMConfig.country(forRegion: "LKAA"), "CZ")

        // Another base (a DEBUG override): its host joins the list and the files come from it.
        let other = try XCTUnwrap(URL(string: "https://raw.githubusercontent.com/fetzu/AeroCheck/website/public/data/ofm/v1/"))
        XCTAssertEqual(OFMConfig.allowedHosts(override: other), ["aerocheck.app", "raw.githubusercontent.com"])
        XCTAssertEqual(OFMConfig.fileURL(published: "https://aerocheck.app/data/ofm/v1/ch.json", base: other)?.absoluteString,
                       "https://raw.githubusercontent.com/fetzu/AeroCheck/website/public/data/ofm/v1/ch.json")
        #if DEBUG
        XCTAssertNil(OFMConfig.debugBaseURL(from: "http://example.com/v1/"), "HTTPS only")
        XCTAssertEqual(OFMConfig.debugBaseURL(from: "https://example.com/v1")?.absoluteString, "https://example.com/v1/")
        #endif
    }

    // MARK: - Download

    func testADownloadReadsTheIndexThenOnlyWhatChanged() async throws {
        let root = makeTestDirectory()
        let server = FakeVFRServer()
        server.publish(["CH": swissFile(), "DE": germanFile()])
        let ofm = service(server, root: root)
        XCTAssertFalse(ofm.isDataAvailable)
        XCTAssertEqual(ofm.supportedCountries, ["AT", "CH", "CZ", "DE"], "the known four before an index")

        await ofm.downloadData(for: ["FR", "DE", "CH"])
        XCTAssertEqual(server.requests, ["index.json", "ch.json", "de.json"], "nothing asked for FR")
        XCTAssertEqual(ofm.downloadedCountries, ["CH", "DE"])
        XCTAssertEqual(ofm.supportedCountries, ["CH", "DE"], "the index's countries")
        XCTAssertEqual(ofm.cycles["CH"]?.airac, "2610")
        XCTAssertEqual(ofm.failedCountries, [])
        XCTAssertNotNil(ofm.lastUpdated)
        let stored = try Data(contentsOf: directory(of: root).appendingPathComponent("ofm_CH.json"))
        XCTAssertEqual(stored, swissFile(), "stored byte for byte as published")
        let excluded = try directory(of: root).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        XCTAssertEqual(excluded, true)

        // Nothing changed: the index only.
        await ofm.downloadData(for: ["CH", "DE"])
        XCTAssertEqual(server.requests.suffix(1), ["index.json"])

        // A new Swiss cycle: Switzerland only.
        server.publish(["CH": swissFile(airac: "2611", validFrom: "2026-10-29", validTo: "2026-11-26"), "DE": germanFile()],
                       airac: "2611", validTo: "2026-11-26")
        await ofm.downloadData(for: ["CH", "DE"])
        XCTAssertEqual(server.requests.suffix(2), ["index.json", "ch.json"])
        XCTAssertEqual(ofm.cycles["CH"]?.airac, "2611")
        XCTAssertEqual(ofm.cycles["DE"]?.airac, "2610")

        // A relaunch finds it all again.
        let relaunched = service(server, root: root)
        XCTAssertEqual(relaunched.downloadedCountries, ["CH", "DE"])
        XCTAssertEqual(relaunched.cycles["CH"]?.airac, "2611")
        XCTAssertEqual(relaunched.index?.countries, ["CH", "DE"])
        XCTAssertFalse(relaunched.isLoaded, "decoded on demand only")
    }

    func testAChecksumMismatchIsRefusedAndTheOldFileKept() async throws {
        let root = makeTestDirectory()
        let server = FakeVFRServer()
        server.publish(["CH": swissFile()], checksums: ["CH": String(repeating: "0", count: 64)])
        let ofm = service(server, root: root)
        await ofm.downloadData(for: ["CH"])
        XCTAssertEqual(ofm.failedCountries, ["CH"])
        XCTAssertEqual(ofm.downloadedCountries, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory(of: root).appendingPathComponent("ofm_CH.json").path))

        server.publish(["CH": swissFile()])
        await ofm.downloadData(for: ["CH"])
        XCTAssertEqual(ofm.downloadedCountries, ["CH"])

        // The next cycle arrives altered on the way: refused, 2610 stays.
        server.publish(["CH": swissFile(airac: "2611", validFrom: "2026-10-29", validTo: "2026-11-26")], airac: "2611",
                       checksums: ["CH": String(repeating: "a", count: 64)])
        await ofm.downloadData(for: ["CH"])
        XCTAssertEqual(ofm.failedCountries, ["CH"])
        XCTAssertEqual(ofm.cycles["CH"]?.airac, "2610")
        let stored = try Data(contentsOf: directory(of: root).appendingPathComponent("ofm_CH.json"))
        XCTAssertEqual(stored, swissFile())
    }

    /// The file a mismatching cache claims to have is checked on disk too: a damaged file is fetched again.
    func testADamagedFileOnDiskIsFetchedAgain() async throws {
        let root = makeTestDirectory()
        let server = FakeVFRServer()
        server.publish(["CH": swissFile()])
        let ofm = service(server, root: root)
        await ofm.downloadData(for: ["CH"])
        try Data("{}".utf8).write(to: directory(of: root).appendingPathComponent("ofm_CH.json"))
        await ofm.downloadData(for: ["CH"])
        XCTAssertEqual(server.requests, ["index.json", "ch.json", "index.json", "ch.json"])
        XCTAssertEqual(try Data(contentsOf: directory(of: root).appendingPathComponent("ofm_CH.json")), swissFile())
    }

    func testAFileOffTheAllowListOrTooLargeIsRefused() async throws {
        let server = FakeVFRServer()
        let big = Data(count: OFMConfig.maxFileBytes + 1)
        server.publish(["CH": swissFile(), "DE": big], urls: ["CH": "https://example.com/ch.json"])
        let ofm = service(server)
        await ofm.downloadData(for: ["CH", "DE"])
        XCTAssertEqual(server.requests, ["index.json", "de.json"], "example.com is never asked")
        XCTAssertEqual(ofm.failedCountries, ["CH", "DE"])
        XCTAssertEqual(ofm.downloadedCountries, [])
    }

    /// Like the OpenAIP layers: a download keeps exactly the countries it was given (callers pass the
    /// union), a trip adds to them, and a country that fails keeps its file.
    func testPruneOnlyWithTheUnion() async throws {
        let root = makeTestDirectory()
        let server = FakeVFRServer()
        server.publish(["CH": swissFile(), "DE": germanFile()])
        let ofm = service(server, root: root)
        await ofm.downloadData(for: ["CH", "DE"])

        // The trip top-up passes a country: the provider adds it to what is there.
        await OFMProceduresProvider(service: ofm).prefetch(countries: ["AT"])
        XCTAssertEqual(ofm.downloadedCountries, ["CH", "DE"], "AT isn't published; nothing pruned")

        // An empty selection is not "remove everything".
        await ofm.downloadData(for: [])
        XCTAssertEqual(ofm.downloadedCountries, ["CH", "DE"])

        // A new German cycle that can't be fetched: the 2610 file stays (an unchanged one isn't even asked for).
        server.publish(["CH": swissFile(), "DE": germanFile(airac: "2611", validFrom: "2026-10-29", validTo: "2026-11-26")])
        server.failing = ["de.json"]
        await ofm.downloadData(for: ["CH", "DE"])
        XCTAssertEqual(ofm.failedCountries, ["DE"])
        XCTAssertEqual(ofm.downloadedCountries, ["CH", "DE"])
        XCTAssertEqual(ofm.cycles["DE"]?.airac, "2610")

        // Germany deselected: pruned, file and all.
        server.failing = []
        await ofm.downloadData(for: ["CH"])
        XCTAssertEqual(ofm.downloadedCountries, ["CH"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory(of: root).appendingPathComponent("ofm_DE.json").path))
    }

    // MARK: - Freshness by cycle

    /// 2610 runs from Thursday 1 October to Wednesday 28 October 2026; 2611 is effective on Thursday 29
    /// October at 00:00 UTC.
    func testFreshnessAtTheCycleBoundaries() {
        let validTo = utc("2026-10-29T00:00:00Z")
        XCTAssertEqual(OFMSchema.utcCalendar.component(.weekday, from: validTo), 5, "a Thursday")
        XCTAssertEqual(OFMCycleFreshness.freshness(validTo: validTo, now: utc("2026-10-01T00:00:00Z")), .fresh)
        XCTAssertEqual(OFMCycleFreshness.freshness(validTo: validTo, now: utc("2026-10-28T23:59:59Z")), .fresh)
        XCTAssertEqual(OFMCycleFreshness.freshness(validTo: validTo, now: utc("2026-10-29T00:00:00Z")), .aging)
        XCTAssertEqual(OFMCycleFreshness.freshness(validTo: validTo, now: utc("2026-11-25T23:59:59Z")), .aging)
        XCTAssertEqual(OFMCycleFreshness.freshness(validTo: validTo, now: utc("2026-11-26T00:00:00Z")), .stale)
        XCTAssertEqual(OFMCycleFreshness.freshness(validTo: nil, now: validTo), .missing)
    }

    /// The row: fresh with its cycle and validity, aging with "not published yet" or the newer cycle,
    /// the oldest country deciding, a line per cycle when they differ.
    func testTheRowShowsTheCycle() async throws {
        var clock = utc("2026-10-02T08:00:00Z")
        let server = FakeVFRServer()
        server.publish(["CH": swissFile(), "DE": germanFile()])
        let ofm = service(server) { clock }
        let provider = OFMProceduresProvider(service: ofm)
        XCTAssertEqual(provider.makeDataSet(now: clock).freshness, .missing)
        XCTAssertNil(provider.makeDataSet(now: clock).cycleDetail)

        await ofm.downloadData(for: ["CH", "DE"])
        var row = provider.makeDataSet(now: clock)
        XCTAssertEqual(row.id, "ofm.procedures")
        XCTAssertEqual(row.displayName, L10n.DataStorage.vfrProceduresName)
        XCTAssertEqual(row.detail, L10n.DataStorage.vfrProceduresDetail)
        XCTAssertEqual(row.attribution, L10n.DataStorage.vfrProceduresAttribution)
        XCTAssertEqual(row.urgency, .primary)
        XCTAssertEqual(row.refreshPolicy, .smallSilentJSON)
        XCTAssertEqual(row.coverage, ["CH", "DE"])
        XCTAssertTrue(row.isDownloaded)
        XCTAssertEqual(row.freshness, .fresh)
        let range = OFMDataService.validityRange(.init(airac: "2610", validFrom: utc("2026-10-01T00:00:00Z"),
                                                       validTo: utc("2026-10-29T00:00:00Z")))
        XCTAssertEqual(row.cycleDetail, L10n.DataStorage.vfrCycleValid("2610", range))
        XCTAssertTrue(range.contains("28"), "the last day is the 28th: \(range)")

        clock = utc("2026-10-29T01:00:00Z")
        row = provider.makeDataSet(now: clock)
        XCTAssertEqual(row.freshness, .aging)
        XCTAssertEqual(row.cycleDetail, L10n.DataStorage.vfrCycleNotPublished("2610"))

        // 2611 is out for Switzerland only: CH moves on, Germany (still 2610) decides the row.
        server.publish(["CH": swissFile(airac: "2611", validFrom: "2026-10-29", validTo: "2026-11-26")],
                       airac: "2611", validTo: "2026-11-26")
        await ofm.downloadData(for: ["CH", "DE"])
        row = provider.makeDataSet(now: clock)
        XCTAssertEqual(row.freshness, .aging)
        XCTAssertEqual(row.cycleDetail?.components(separatedBy: "\n"), [
            "CH · " + L10n.DataStorage.vfrCycleValid("2611", OFMDataService.validityRange(
                .init(airac: "2611", validFrom: utc("2026-10-29T00:00:00Z"), validTo: utc("2026-11-26T00:00:00Z")))),
            "DE · " + L10n.DataStorage.vfrCycleNotPublished("2610"),
        ])

        clock = utc("2026-11-26T00:00:00Z")
        XCTAssertEqual(provider.makeDataSet(now: clock).freshness, .stale)

        // A newer cycle in the index that this device doesn't have yet.
        let lines = OFMDataService.cycleLines(
            cycles: ["CH": .init(airac: "2610", validFrom: utc("2026-10-01T00:00:00Z"), validTo: utc("2026-10-29T00:00:00Z"))],
            published: ["CH": "2611"], now: utc("2026-10-30T00:00:00Z"))
        XCTAssertEqual(lines, [L10n.DataStorage.vfrCycleAvailable("2610", "2611")])
    }

    /// Aging is enough for the foreground refresh to fetch a new cycle, at most hourly while OFM
    /// hasn't published it.
    func testTheForegroundRefreshFetchesANewCycleOnceAging() async throws {
        var clock = utc("2026-10-20T08:00:00Z")
        let server = FakeVFRServer()
        server.publish(["CH": swissFile()])
        let ofm = service(server) { clock }
        await ofm.downloadData(for: ["CH"])
        let wifi = NetworkConditions(isConnected: true, isWiFi: true, isExpensive: false, isConstrained: false)
        let manager = DataStatusManager(providers: [OFMProceduresProvider(service: ofm)],
                                        networkMonitor: NetworkMonitor(stub: wifi), now: { clock },
                                        userDefaults: makeTestDefaults())

        // Fresh: nothing to do.
        await manager.autoRefreshIfNeeded(cellularUpdatesEnabled: true)
        XCTAssertEqual(server.requests, ["index.json", "ch.json"])

        // The cycle ended, OFM is late: the index is read, nothing else.
        clock = utc("2026-10-29T00:30:00Z")
        await manager.autoRefreshIfNeeded(cellularUpdatesEnabled: true)
        XCTAssertEqual(server.requests.count, 3)
        XCTAssertEqual(server.requests.last, "index.json")
        XCTAssertEqual(manager.dataSets.first?.freshness, .aging)
        XCTAssertEqual(manager.dataSets.first?.refreshWhenAging, false, "asked less than an hour ago")

        // Ten minutes later: not again.
        clock = utc("2026-10-29T00:40:00Z")
        await manager.autoRefreshIfNeeded(cellularUpdatesEnabled: true)
        XCTAssertEqual(server.requests.count, 3)

        // 2611 is published; an hour after the last check the refresh fetches it.
        server.publish(["CH": swissFile(airac: "2611", validFrom: "2026-10-29", validTo: "2026-11-26")],
                       airac: "2611", validTo: "2026-11-26")
        clock = utc("2026-10-29T05:30:00Z")
        await manager.autoRefreshIfNeeded(cellularUpdatesEnabled: true)
        XCTAssertEqual(server.requests.suffix(2), ["index.json", "ch.json"])
        XCTAssertEqual(manager.dataSets.first?.freshness, .fresh)
        XCTAssertEqual(ofm.cycles["CH"]?.airac, "2611")

        // The flag alone moves nothing for a dataset that doesn't set it (the OpenAIP layers).
        let plain = DataStatusManagerTests.FakeProvider(DataSet(
            id: "plain", displayName: "plain", detail: "", urgency: .primary, provenance: .community,
            refreshPolicy: .smallSilentJSON, lastUpdated: nil, freshness: .aging, sizeOnDisk: nil,
            coverage: [], isDownloaded: true))
        let other = DataStatusManager(providers: [plain], networkMonitor: NetworkMonitor(stub: wifi),
                                      userDefaults: makeTestDefaults())
        await other.autoRefreshIfNeeded(cellularUpdatesEnabled: true)
        XCTAssertEqual(plain.refreshCount, 0)
    }

    // MARK: - Queries

    func testQueriesByRegionAerodromeAndCategory() async throws {
        let server = FakeVFRServer()
        server.publish(["CH": swissFile(), "DE": germanFile()])
        let ofm = service(server)
        await ofm.downloadData(for: ["CH", "DE"])
        XCTAssertTrue(ofm.procedures(in: region(lat: 47.39, lon: 7.03)).isEmpty, "nothing before ensureLoaded")

        await ofm.ensureLoaded()
        XCTAssertTrue(ofm.isLoaded)
        let lszq = region(lat: 47.395, lon: 7.03)
        XCTAssertEqual(ofm.procedures(in: lszq).map(\.name), ["TC", "ARR SECTOR EAST", "ARR SEKTOR WEST"])
        XCTAssertEqual(ofm.procedures(in: lszq, kinds: [.circuit]).map(\.name), ["TC"])
        XCTAssertEqual(ofm.procedures(in: lszq, kinds: [.departure]), [])
        // Only the sector reaches this far east of the field.
        XCTAssertEqual(ofm.procedures(in: region(lat: 47.39, lon: 7.103, span: 0.004)).map(\.name), ["ARR SECTOR EAST"])

        let lsgr = region(lat: 46.63, lon: 7.67)
        XCTAssertEqual(ofm.procedures(in: lsgr, categories: [.powered]), [], "the heavy circuit isn't the plain one")
        XCTAssertEqual(ofm.procedures(in: lsgr, categories: [.powered, .heavy]).map(\.name), ["TC MULTI"])
        XCTAssertEqual(ofm.procedures(in: region(lat: 48.69, lon: 11.03), categories: [.ultralight]).map(\.aerodrome), ["EDBGH"])
        XCTAssertEqual(ofm.procedures(in: region(lat: 47.5, lon: 8.65, span: 0.4), categories: [.helicopter]).map(\.kind),
                       [.arrival, .departure])
        // Across several 1° cells: all of Switzerland and Friedrichshafen, not EDBGH (11°E).
        XCTAssertEqual(ofm.procedures(in: region(lat: 46.8, lon: 8.2, span: 3.0)).count, 10)
        XCTAssertEqual(ofm.procedures(in: region(lat: 40, lon: -3)), [])

        XCTAssertEqual(ofm.procedures(forAerodrome: "lszq").map(\.kind), [.circuit, .arrival, .arrival])
        XCTAssertEqual(ofm.procedures(forAerodrome: "EDNY").map(\.name), ["NOVEMBER-HN", "OSCAR-24"])
        XCTAssertEqual(ofm.procedures(forAerodrome: "LFSB"), [])

        XCTAssertEqual(ofm.points(in: region(lat: 46.92, lon: 7.07, span: 0.2)).map(\.name), ["CHABREY", "MURTEN"])
        XCTAssertEqual(ofm.points(in: region(lat: 47.68, lon: 9.5)).map(\.name), ["HN"])
        XCTAssertEqual(ofm.runwayDesignators(forAerodrome: "LSGC"), ["05/23"])
        XCTAssertEqual(ofm.runwayDesignators(forAerodrome: "EDNY"), ["06/24"])
        XCTAssertEqual(ofm.runwayDesignators(forAerodrome: "LFSB"), [])
        XCTAssertEqual(ofm.region(forCountry: "DE"), "ED")

        // A download replaces what is loaded.
        let revision = ofm.revision
        server.publish(["CH": swissFile()])
        await ofm.downloadData(for: ["CH"])
        XCTAssertGreaterThan(ofm.revision, revision)
        XCTAssertEqual(ofm.procedures(forAerodrome: "EDNY"), [], "Germany was deselected")
        XCTAssertEqual(ofm.procedures(forAerodrome: "LSZQ").count, 3)
    }

    // MARK: - Data & Storage

    func testRemoveAllTakesTheProceduresAway() async throws {
        let root = makeTestDirectory()
        let server = FakeVFRServer()
        server.publish(["CH": swissFile()])
        let ofm = service(server, root: root)
        await ofm.downloadData(for: ["CH"])
        await ofm.ensureLoaded()
        let manager = DataStatusManager(providers: [OFMProceduresProvider(service: ofm)],
                                        networkMonitor: NetworkMonitor(stub: .disconnected), userDefaults: makeTestDefaults())
        XCTAssertTrue(try XCTUnwrap(manager.dataSets.first).isDownloaded)

        manager.removeAll()
        let row = try XCTUnwrap(manager.dataSets.first)
        XCTAssertEqual(row.freshness, .missing)
        XCTAssertFalse(row.isDownloaded)
        XCTAssertNil(row.cycleDetail)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory(of: root).path))
        XCTAssertEqual(ofm.procedures(forAerodrome: "LSZQ"), [])
        XCTAssertEqual(ofm.points(in: region(lat: 46.92, lon: 7.07, span: 0.2)), [])
        XCTAssertNil(ofm.index)
    }

    /// The row's error line (PR #253's pattern): the countries that kept their old data, until an update
    /// completes. An unreachable index fails every requested country OFM covers.
    func testAFailedUpdateShowsUnderTheRowUntilOneCompletes() async throws {
        let server = FakeVFRServer()
        server.publish(["CH": swissFile()])
        server.failing = ["index.json"]
        let ofm = service(server)
        let provider = OFMProceduresProvider(service: ofm, offlineCountries: { ["CH", "FR"] })
        let manager = DataStatusManager(providers: [provider], networkMonitor: NetworkMonitor(stub: .disconnected),
                                        userDefaults: makeTestDefaults())

        // Never downloaded: Refresh takes the offline countries.
        await manager.refresh(try XCTUnwrap(manager.dataSets.first))
        XCTAssertEqual(manager.dataSets.first?.updateFailure?.countries, ["CH"], "FR isn't covered: no failure")
        XCTAssertTrue(L10n.DataStorage.updateFailed(["CH"]).contains("CH"))

        server.failing = []
        await manager.refresh(try XCTUnwrap(manager.dataSets.first))
        XCTAssertNil(manager.dataSets.first?.updateFailure)
        XCTAssertEqual(manager.dataSets.first?.coverage, ["CH"])
    }

    func testTheNewStringsHaveTheirFrench() throws {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "fr", ofType: "lproj"))
        let french = try XCTUnwrap(Bundle(path: path))
        let missing = "\u{1}missing"
        let expected = [
            "VFR procedures (open flightmaps)": "Procédures VFR (open flightmaps)",
            "© open flightmaps association · not for primary navigation":
                "© open flightmaps association · non destiné à la navigation primaire",
            "AIRAC %@ · valid %@": "AIRAC %@ · en vigueur %@",
            "AIRAC %@ · a newer cycle isn't published yet": "AIRAC %@ · le cycle suivant n’est pas encore publié",
            "AIRAC %@ · AIRAC %@ is available": "AIRAC %@ · AIRAC %@ disponible",
            "VFR procedures": "procédures VFR",
            "VFR procedures (open flightmaps): %@": "Procédures VFR (open flightmaps) : %@",
            // About › Data sources (6.2.0 docs)
            "Traffic circuits, VFR routes & reporting points · © open flightmaps association · indicative, not for primary navigation":
                "Tours de piste, routes VFR et points de report · © open flightmaps association · indicatif, non destiné à la navigation primaire",
        ]
        for (key, value) in expected {
            XCTAssertEqual(french.localizedString(forKey: key, value: missing, table: nil), value, key)
        }
        XCTAssertNotEqual(french.localizedString(forKey: "open flightmaps · traffic circuits, VFR arrival & departure routes, sectors",
                                                 value: missing, table: nil), missing)
        XCTAssertEqual(L10n.DataStorage.vfrCycleNotPublished("2610"), "AIRAC 2610 · a newer cycle isn't published yet")
    }

    // MARK: - Trip prefetch

    /// The trip layers are one list (the four OpenAIP layers and the VFR procedures), shared by Data &
    /// Storage and the route builder; a country open flightmaps doesn't publish is no gap for it.
    func testTheTripLayerList() async throws {
        let server = FakeVFRServer()
        server.publish(["CH": swissFile(), "DE": germanFile()])
        let ofm = service(server)
        await ofm.downloadData(for: ["CH"])

        let airspace = OpenAIPDataService()
        airspace.downloadedCountries = ["CH", "DE", "FR"]
        let providers = DataStatusManager.tripProviders(
            airspace: airspace, navaids: OpenAIPNavaidDataService(), obstacles: OpenAIPObstacleDataService(),
            reportingPoints: OpenAIPReportingPointDataService(), vfrProcedures: ofm)
        XCTAssertEqual(providers.map { $0.id }, ["openaip.airspace", "openaip.navaids", "openaip.obstacles",
                                                 "openaip.reportingpoints", "ofm.procedures"])
        XCTAssertEqual(providers.compactMap { $0.tripLayer }, TripDataSizeEstimator.Layer.allCases)

        let vfr = Array(providers.suffix(1))
        XCTAssertEqual(DataStatusManager.tripGaps(providers: vfr, routeCountries: ["CH", "FR", "DE"]),
                       [.vfrProcedures: ["DE"]], "FR isn't published, CH is on disk")
        XCTAssertEqual(DataStatusManager.tripCountriesNeedingData(providers: vfr, routeCountries: ["CH", "FR", "DE"]), ["DE"])
        // The OFM provider alone: the others here sit on the app's real OpenAIP caches.
        let manager = DataStatusManager(providers: vfr, networkMonitor: NetworkMonitor(stub: .disconnected),
                                        userDefaults: makeTestDefaults())
        XCTAssertEqual(manager.tripCountriesNeedingData(routeCountries: ["CH", "FR", "DE"]), ["DE"])
        XCTAssertEqual(manager.tripCountriesNeedingDataByLayer(routeCountries: ["CH", "FR", "DE"]), [.vfrProcedures: ["DE"]])

        // The estimate takes the VFR size from the index, exactly.
        let estimate = await TripDataSizeEstimator.estimate(countriesByLayer: [.vfrProcedures: ["DE"]]) {
            await ofm.publishedSize(for: $0)
        }
        XCTAssertEqual(estimate.bytes, Int64(germanFile().count))
        XCTAssertEqual(estimate.recordsByLayer, ["vfrProcedures": 3])
        XCTAssertFalse(estimate.isPartial)
        XCTAssertEqual(L10n.DataStorage.layerName(.vfrProcedures), String(localized: "VFR procedures"))
        let unknown = await TripDataSizeEstimator.estimate(countriesByLayer: [.vfrProcedures: ["IT"]]) { _ in nil }
        XCTAssertTrue(unknown.isPartial)

        // The prefetch adds Germany to Switzerland.
        await manager.prefetchTripData(countries: ["DE"])
        XCTAssertEqual(ofm.downloadedCountries, ["CH", "DE"])
        XCTAssertEqual(manager.tripCountriesNeedingData(routeCountries: ["CH", "FR", "DE"]), [])
    }
}
