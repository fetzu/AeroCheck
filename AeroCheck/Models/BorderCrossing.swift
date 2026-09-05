import Foundation

// MARK: - Border crossing (v5.0.0)
//
// What a private VFR flight has to do at a border, per country.
//
// This holds STRUCTURED FACTS and a link, never paragraphs of regulatory prose — the same rule the
// airfield tariff registry follows, and for the same reasons. Customs requirements change, differ by
// direction and by aircraft registration, and are published by each national authority in its own
// language. Restating them in the app would create a second source of truth that goes stale quietly
// and cannot be translated without risking a mistranslated obligation. Four checkable facts plus the
// authority's own page is both more honest and more useful.
//
// Switzerland is the anchor: in Schengen (so immigration checks are largely gone) but OUTSIDE the EU
// customs union, which is exactly why customs formalities survive a flight that feels domestic.

/// How firmly something is required. Rendered through `L10n`, so the pack stays localizable without
/// translating regulatory text.
enum BorderRequirement: String, Codable, Sendable {
    case required
    /// Required unless specific conditions are met (the Swiss category-D case, for instance).
    case conditional
    case notRequired
    /// Not established from an authoritative source. Never rendered as "no" — an unknown obligation
    /// is not an absent one.
    case unknown

    var label: String {
        switch self {
        case .required:    return L10n.Border.required
        case .conditional: return L10n.Border.conditional
        case .notRequired: return L10n.Border.notRequired
        case .unknown:     return L10n.Border.unknown
        }
    }

    /// Whether this should read as a warning rather than a fact.
    var isDemanding: Bool { self == .required || self == .conditional || self == .unknown }
}

/// One country's rules for a private GA flight crossing to or from Switzerland.
struct BorderCrossingRule: Equatable, Sendable {
    let country: String
    let countryName: String
    /// Must the flight land at a designated customs / entry aerodrome?
    let customsAerodrome: BorderRequirement
    /// Must the authorities be told in advance?
    let priorNotification: BorderRequirement
    /// How far ahead, when notification is required. Free text because the real answers are ranges
    /// ("2-48 h") rather than numbers.
    let noticeLeadTime: String?
    /// The single page a pilot should open to check the current rules themselves.
    let officialURL: URL
    /// When a human last read that page. Shown, because a rule nobody has re-checked in two years
    /// should be treated differently from one checked last month.
    let lastReviewed: String

    var hasOpenQuestion: Bool { customsAerodrome == .unknown || priorNotification == .unknown }
}

enum BorderCrossingGuide {

    /// The Swiss side of any border crossing, which applies whichever country is at the other end.
    ///
    /// Category A-C aerodromes are the customs fields; category D ("authorized traffic") is usable
    /// only under conditions. Those conditions are exactly the kind of thing that must not be
    /// paraphrased in an app, so the link goes to the authority.
    static let switzerland = BorderCrossingRule(
        country: "CH",
        countryName: "Switzerland",
        customsAerodrome: .conditional,
        priorNotification: .conditional,
        noticeLeadTime: nil,
        officialURL: URL(string: "https://www.bazg.admin.ch/en/cross-border-flights-and-customs-regulations")!,
        lastReviewed: "2026-09-01"
    )

    /// Curated per-country rules. A country that is absent is NOT "nothing to do" — the task falls
    /// back to a generic prompt telling the pilot to check, which is the honest state for a country
    /// nobody has verified.
    static let rules: [String: BorderCrossingRule] = [
        "FR": BorderCrossingRule(
            country: "FR",
            countryName: "France",
            customsAerodrome: .conditional,
            // French customs confirmed the préavis requirement is gone for flights from Switzerland;
            // the flight plan itself serves as the notification. Stale AIP entries still say
            // otherwise at some fields, which is why the link matters.
            priorNotification: .notRequired,
            noticeLeadTime: nil,
            officialURL: URL(string: "https://www.douane.gouv.fr/demarche/aviation-generale")!,
            lastReviewed: "2026-09-01"
        ),
        "GB": BorderCrossingRule(
            country: "GB",
            countryName: "United Kingdom",
            customsAerodrome: .conditional,
            priorNotification: .required,
            noticeLeadTime: "2–48 h",
            officialURL: URL(string: "https://www.gov.uk/government/publications/general-aviation-operators-and-pilots-notification-of-flights")!,
            lastReviewed: "2026-09-01"
        ),
    ]

    static func rule(for country: String) -> BorderCrossingRule? {
        rules[country.trimmingCharacters(in: .whitespaces).uppercased()]
    }

    /// Countries with a curated rule, for tests and for the settings-style listing.
    static var curatedCountries: [String] { rules.keys.sorted() }
}
