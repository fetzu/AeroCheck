import XCTest
@testable import AeroCheck

/// SA-11: the OpenAIP key must never appear in a tile URL.
///
/// A key in a query string lands in every URL-level log along the path — the device's on-disk
/// `URLCache` entries, any enterprise/MDM TLS-inspecting proxy, and OpenAIP's own access logs.
/// The REST path (`OpenAIPDataService`) always sent it as a header; the tile path did not, which
/// was an internal inconsistency rather than a platform constraint. If the key leaks, an attacker
/// burns the operator's quota until it is throttled and the airspace overlay silently stops
/// rendering for every user.
///
/// (The residual "a client-embedded key is extractable from the binary" half is inherent to
/// calling a keyed third-party API directly from the app — see L5 in the audit. These tests cover
/// the fixable half.)
final class OpenAIPTileAuthTests: XCTestCase {

    func testTileURLCarriesNoQueryParameters() throws {
        let url = try XCTUnwrap(OpenAIPConfig.tileURL(subdomain: "a", z: 10, x: 530, y: 355))

        XCTAssertNil(url.query, "tile URLs must have no query string at all")
        XCTAssertFalse(url.absoluteString.lowercased().contains("apikey"),
                       "no apiKey parameter may appear in a tile URL")
        XCTAssertEqual(url.path, "/api/data/openaip/10/530/355.png")
    }

    func testTileRequestSendsTheKeyAsAHeader() throws {
        let request = try XCTUnwrap(OpenAIPConfig.tileRequest(subdomain: "b", z: 8, x: 1, y: 2))

        XCTAssertEqual(request.value(forHTTPHeaderField: OpenAIPConfig.apiKeyHeader),
                       OpenAIPConfig.apiKey)
        XCTAssertEqual(OpenAIPConfig.apiKeyHeader, "x-openaip-api-key",
                       "must match the header the REST path already uses")
    }

    func testTileRequestURLDoesNotLeakTheKey() throws {
        let request = try XCTUnwrap(OpenAIPConfig.tileRequest(subdomain: "c", z: 12, x: 3, y: 4))
        let urlString = try XCTUnwrap(request.url?.absoluteString)

        XCTAssertNil(request.url?.query)
        // Only meaningful when a key is actually configured (it is absent in a fresh checkout and
        // in CI without the secret), but it is the assertion that matters when one IS present.
        if !OpenAIPConfig.apiKey.isEmpty {
            XCTAssertFalse(urlString.contains(OpenAIPConfig.apiKey),
                           "the key must not appear anywhere in the request URL")
        }
    }

    func testEveryTileSubdomainProducesAKeylessURL() throws {
        for subdomain in OpenAIPConfig.tileSubdomains {
            let url = try XCTUnwrap(OpenAIPConfig.tileURL(subdomain: subdomain, z: 9, x: 5, y: 6))
            XCTAssertNil(url.query, "subdomain \(subdomain) leaked a query string")
        }
    }
}
