import Foundation

/// Estimates how much storage a per-country data download will take, before the user commits to it.
///
/// The trip banner used to offer "Download data for this trip" with no indication of cost, and the
/// cost is not uniform: navaids and reporting points really are tiny, but obstacles are not — Germany
/// alone carries ~30 000 of them, and France, Germany and Italy together are around 46 000 records
/// against 350 navaids. A pilot in a clubhouse on a phone hotspot deserves to know which of those two
/// downloads they are about to start.
///
/// The number quoted is **on-disk size after parsing**, not wire bytes, for two reasons: it is the
/// figure the same Data & Storage screen already shows for every layer, so the estimate and the result
/// are directly comparable; and wire bytes would be misleading anyway, since responses are
/// transfer-compressed.
///
/// Counts come from the provider (`totalCount` on a `limit=1` query — four small requests per
/// country); bytes come from multiplying those by measured per-record constants. That makes it an
/// estimate, and it is labelled as one. The VFR procedures are the exception: their `index.json` says
/// exactly what each country's file weighs, and the file is stored as published. (6.2.0)
enum TripDataSizeEstimator {

    /// The per-country layers a trip prefetch downloads (`DataSetProvider.tripLayer`), with the
    /// core-API collection each OpenAIP one maps to.
    ///
    /// The OpenAIP *airport* layer is deliberately absent, matching the prefetch itself: it ships with
    /// the full Navigation & Maps country bundle, not this lightweight route top-up.
    enum Layer: String, CaseIterable {
        case airspace, navaids, obstacles, reportingPoints
        /// open flightmaps circuits and VFR routes, sized from `index.json`. (6.2.0)
        case vfrProcedures

        /// The OpenAIP core-API collection; nil for a layer that isn't OpenAIP's.
        var apiPath: String? {
            switch self {
            case .airspace: return "airspaces"
            case .navaids: return "navaids"
            case .obstacles: return "obstacles"
            case .reportingPoints: return "reporting-points"
            case .vfrProcedures: return nil
            }
        }

        /// Bytes one record occupies on disk once parsed and re-encoded.
        ///
        /// Measured 2026-08-02 from a device holding AT/CH/DE/FR/IT: airspace 11 735 879 B / 4 454
        /// records, navaids 93 260 / 375, obstacles 6 490 668 / 47 778, reporting points 293 245 /
        /// 1 810. Airspace is the loosest fit by far — a record is a polygon, and per-country averages
        /// ran from 1 078 B (Switzerland) to 3 906 B (Italy) — so treat its share as an order of
        /// magnitude, not a promise. Re-measure if the stored models change shape.
        var bytesPerRecord: Int64 {
            switch self {
            case .airspace: return 2_600
            case .navaids: return 250
            case .obstacles: return 136
            case .reportingPoints: return 162
            case .vfrProcedures: return 0   // sized from the index, never counted
            }
        }
    }

    /// A published file's size and what it holds, from the open flightmaps index.
    typealias PublishedSize = (bytes: Int64, procedures: Int)

    struct Estimate: Equatable {
        /// Estimated bytes added on disk across every requested layer/country.
        let bytes: Int64
        /// Record count per layer, for a breakdown ("29 841 obstacles" explains a big number better
        /// than the number does).
        let recordsByLayer: [String: Int]
        /// True when at least one count could not be fetched, so the total is a floor rather than an
        /// estimate. Never silently present a partial sum as complete.
        let isPartial: Bool

        var isEmpty: Bool { bytes == 0 && recordsByLayer.isEmpty }
    }

    /// Ask the provider how many records each layer holds for each country, and convert to bytes.
    ///
    /// `countriesByLayer` is per-layer because coverage is per-layer: a device can hold Swiss airspace
    /// and no Swiss obstacles, and quoting the size of data it already has would overstate the cost.
    ///
    /// `vfrSize` gives a country's VFR-procedure file from the index (the shared service's by default).
    @MainActor
    static func estimate(countriesByLayer: [Layer: [String]],
                         vfrSize: ((String) async -> PublishedSize?)? = nil) async -> Estimate {
        let vfrSize = vfrSize ?? { await OFMDataService.shared.publishedSize(for: $0) }
        var bytes: Int64 = 0
        var records: [String: Int] = [:]
        var partial = false

        for layer in Layer.allCases {
            guard let countries = countriesByLayer[layer], !countries.isEmpty else { continue }
            for country in countries {
                if layer == .vfrProcedures {
                    guard let size = await vfrSize(country) else { partial = true; continue }
                    records[layer.rawValue, default: 0] += size.procedures
                    bytes += size.bytes
                    continue
                }
                guard let count = await recordCount(layer: layer, country: country) else {
                    partial = true
                    continue
                }
                records[layer.rawValue, default: 0] += count
                bytes += Int64(count) * layer.bytesPerRecord
            }
        }
        return Estimate(bytes: bytes, recordsByLayer: records, isPartial: partial)
    }

    /// `totalCount` for one layer/country. nil on any failure — the caller marks the estimate partial
    /// rather than treating a network error as "zero records", which would advertise a free download.
    private static func recordCount(layer: Layer, country: String) async -> Int? {
        guard let apiPath = layer.apiPath else { return nil }
        let urlString = "\(OpenAIPConfig.coreAPIBaseURL)/\(apiPath)?country=\(country)&limit=1"
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(OpenAIPConfig.apiKey, forHTTPHeaderField: OpenAIPConfig.apiKeyHeader)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await ExternalRequest.data(for: request)
            guard response.statusCode == 200,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let total = object["totalCount"] as? Int else { return nil }
            return total
        } catch {
            AppLog.openAIP.debugLine("Size estimate failed for \(layer.rawValue)/\(country): \(error)")
            return nil
        }
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter
    }()

    /// `"≈ 12 MB"`, or `"≥ 12 MB"` when a count was unavailable and the total is only a floor.
    static func displayString(_ estimate: Estimate) -> String? {
        guard estimate.bytes > 0 else { return nil }
        let size = byteFormatter.string(fromByteCount: estimate.bytes)
        return estimate.isPartial ? "≥ \(size)" : "≈ \(size)"
    }
}
