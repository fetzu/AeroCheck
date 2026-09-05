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
    /// Two authoritative sources say different things, and which one is enforced is not established.
    ///
    /// Distinct from `unknown` on purpose: "nobody has checked" and "the country contradicts itself"
    /// call for the same caution but not the same expectation. Germany is the live case — the
    /// Generalzolldirektion told the pilot associations in 2022 that a private aircraft carrying only
    /// duty-free personal effects no longer has to route through a customs airport, while the AIP and
    /// the customs administration's own web pages still state the obligation unchanged. A pilot who
    /// knows to expect the inconsistency asks their destination; one told merely "unverified" may
    /// assume the app is simply behind.
    case disputed

    var label: String {
        switch self {
        case .required:    return L10n.Border.required
        case .conditional: return L10n.Border.conditional
        case .notRequired: return L10n.Border.notRequired
        case .unknown:     return L10n.Border.unknown
        case .disputed:    return L10n.Border.disputed
        }
    }

    /// Whether this should read as a warning rather than a fact. Everything except an established
    /// "no" qualifies.
    var isDemanding: Bool { self != .notRequired }
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

    /// Whether this rule has something a human still needs to settle — either nobody has established
    /// the answer, or the country's own sources disagree about it.
    var hasOpenQuestion: Bool {
        [customsAerodrome, priorNotification].contains { $0 == .unknown || $0 == .disputed }
    }
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
    ///
    /// Liechtenstein is absent and should stay absent: it is in a customs union with Switzerland, so
    /// there is no formality to describe, and it has no aerodrome to fly to. It is also not in the
    /// bundled boundary asset, so the route calculator never raises it as a crossed country.
    static let rules: [String: BorderCrossingRule] = [
        "FR": BorderCrossingRule(
            country: "FR",
            countryName: "France",
            customsAerodrome: .conditional,
            // The préavis in art. 5 of the arrêté du 24 octobre 2017 attaches to a "vol
            // extra-Schengen", which art. 1(9) defines as a flight to or from a state outside the
            // Schengen area. Switzerland is inside it, so a Swiss flight is not caught — the goods
            // side still is, Switzerland being outside the EU customs union, but the arrêté sets no
            // préavis for that. Hence "not required" for notification and "conditional" for the
            // aerodrome. Stale AIP entries at some fields still show a préavis, which is exactly why
            // the link goes to the text that governs.
            priorNotification: .notRequired,
            noticeLeadTime: nil,
            officialURL: URL(string: "https://legifrance.gouv.fr/affichTexte.do?cidTexte=LEGITEXT000035872319")!,
            lastReviewed: "2026-09-05"
        ),
        "DE": BorderCrossingRule(
            country: "DE",
            countryName: "Germany",
            // Germany contradicts itself, so the app must not pick a side. The Generalzolldirektion
            // told the pilot associations in March 2022 that an aircraft entering under Art. 141(1)(d)
            // UCC-DA is declared by the act of crossing the border and no longer has to route through
            // a Zollflugplatz — but that covers the AIRCRAFT, not the goods aboard, and both the AIP
            // (GEN 1.3) and zoll.de still publish the obligation unchanged.
            customsAerodrome: .disputed,
            // Genuinely conditional, on a fact the pilot can look up: Germany sorts airfields into
            // customs airports, "besondere Landeplätze" (which must pre-notify customs themselves, so
            // the pilot has to tell them first) and everything else (no notification). Bremgarten,
            // the nearest such field to the border, asks two hours.
            //
            // The link therefore goes to the CLASSIFICATION list rather than to the rule: which of
            // the three categories the destination falls into is the single fact that settles both
            // questions, and it is the one the app cannot answer.
            priorNotification: .conditional,
            noticeLeadTime: "≥ 2 h",
            officialURL: URL(string: "https://www.zoll.de/DE/Fachthemen/Zoelle/Erfassung-Warenverkehr/Befoerderungspflicht/Zollstrassenzwang/liste_andere_verkehrsrechtlich_zugelassene_flugplaetze.html")!,
            lastReviewed: "2026-09-05"
        ),
        "AT": BorderCrossingRule(
            country: "AT",
            countryName: "Austria",
            // Two layers that must both be satisfied. Customs law (§ 31 ZollR-DG) allows only a
            // Zollflugplatz; aviation law (F-GÜV 2013 § 2) additionally opens 26 named airfields to
            // non-EU border crossings — which catches Switzerland, since the trigger is EU membership
            // and not Schengen.
            customsAerodrome: .conditional,
            // § 3 F-GÜV: the pilot notifies the AIRFIELD, which forwards to ATS, border police and
            // customs. Statutory floor is one hour before an outbound departure; individual fields
            // impose more (Hohenems-Dornbirn asks 90 minutes each way plus a phone confirmation),
            // which is why this is a floor rather than a range.
            priorNotification: .required,
            noticeLeadTime: "≥ 1 h",
            officialURL: URL(string: "https://www.ris.bka.gv.at/GeltendeFassung.wxe?Abfrage=Bundesnormen&Gesetzesnummer=20008651")!,
            lastReviewed: "2026-09-05"
        ),
        "IT": BorderCrossingRule(
            country: "IT",
            countryName: "Italy",
            // Absolute, and recently re-enacted: arts. 800/805 Codice della Navigazione key the
            // obligation to the EU CUSTOMS territory, which Switzerland is outside. The old exemption
            // letting intra-EU flights use non-customs fields was repealed in 2006 and never covered
            // Switzerland anyway. Landing elsewhere is "eccezionale", chargeable and needs prior
            // authorisation from the local customs office, and aviosuperfici are intra-EU only.
            customsAerodrome: .required,
            // Required, but the lead time is set per airport rather than nationally: the values that
            // could be verified run from 90 minutes (Roma Urbe) to 12 hours (Milano Bresso, whose
            // longer window is specifically the non-EU-Schengen case Switzerland falls into).
            //
            // The destination's own figure lives in AIP Italia AD 2 and its Regolamento di Scalo,
            // neither of which can be linked here — ENAV puts the AIP behind an account. The link
            // goes to the customs authority instead, and the range is what warns the pilot that
            // "notify in advance" can mean the night before.
            priorNotification: .required,
            noticeLeadTime: "1.5–12 h",
            officialURL: URL(string: "https://www.adm.gov.it/portale/en/dogane")!,
            lastReviewed: "2026-09-05"
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
