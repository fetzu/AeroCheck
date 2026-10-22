import Foundation

/// How a filed ATC flight plan is closed where the flight landed (the author's q3, 22 Oct 2026): that country's rule
/// from the briefing registry, the numbers to call (the aerodrome's own where the country has them per aerodrome,
/// Spain's AROs), what a landing at a field with ATS does, the country's own links, and when the reminder comes. A
/// diversion's country after a diversion. Until 6.5.0 it was Switzerland's, Zurich RCC and 0800 437 837, wherever the
/// flight landed. A country the registry has nothing checked for gets the rule that holds everywhere, never another
/// country's number. (6.5.0)
struct CloseOut: Equatable {
    /// The country landed in, ISO-2; nil when the app can't tell.
    var country: String?
    /// The aerodrome landed at.
    var aerodrome: String?
    var phones: [BriefingRegistry.Phone] = []
    var alertMinutes: Int?
    var reportMinutes: Int?
    var atsClose: BriefingRegistry.ATSClose?
    var links: [BriefingRegistry.Link] = []
    /// The aerodrome has a tower in the app's data: for a country where only a controlled aerodrome closes the plan.
    /// Nil when the app can't tell.
    var aerodromeHasTower: Bool?

    static func make(registry: BriefingRegistry?, country: String?, aerodrome: String?,
                     aerodromeHasTower: Bool? = nil) -> CloseOut {
        var closeOut = CloseOut(country: country, aerodrome: aerodrome, aerodromeHasTower: aerodromeHasTower)
        guard let registry, let entry = registry.country(country) else { return closeOut }
        closeOut.phones = registry.closingPhones(country: country, aerodrome: aerodrome)
        closeOut.alertMinutes = entry.closing.alertMinutes
        closeOut.reportMinutes = entry.closing.reportMinutes
        closeOut.atsClose = entry.closing.atsClose
        closeOut.links = entry.closing.links
        return closeOut
    }

    /// The registry has checked something for this country: a number, or a delay.
    var isKnown: Bool { country != nil && (!phones.isEmpty || alertMinutes != nil || reportMinutes != nil) }

    /// The rule in a sentence, the country first. "30 min after your ETA" only where an AIP ties alerting to a delay
    /// (CH, GB, PL, IM); "within 30 min" where it sets only a deadline (SE, EE, LV, RO); elsewhere, that search and
    /// rescue may be started.
    var rule: String {
        guard isKnown, let country else { return L10n.CloseOut.ruleUnknown }
        let name = OpenAIPConfig.countryName(for: country)
        if let alertMinutes { return L10n.CloseOut.ruleAlert(name, minutes: alertMinutes) }
        if let reportMinutes { return L10n.CloseOut.ruleReport(name, minutes: reportMinutes) }
        if let first = phones.first { return L10n.CloseOut.ruleReportTo(name, first.name) }
        return L10n.CloseOut.ruleNoDelay(name)
    }

    /// What a landing at an aerodrome with air traffic services does, by the country's own rule.
    var atsLine: String? {
        switch atsClose {
        case .sera?:
            return L10n.CloseOut.atsSera
        case .controlled?:
            guard let aerodrome, aerodromeHasTower == false else { return L10n.CloseOut.atsControlled }
            return "\(L10n.CloseOut.atsControlled) \(L10n.CloseOut.notControlled(aerodrome))"
        case .atsu?:
            return L10n.CloseOut.atsATSU
        case .report?:
            return L10n.CloseOut.atsReport
        case nil:
            return nil
        }
    }

    /// After a full stop the reminder comes at half the published alerting delay, inside the window with room to
    /// act, or after `NotificationService.landingDelay` (15 min) where none is published, as before.
    var reminderDelay: TimeInterval {
        alertMinutes.map { TimeInterval($0) * 60 / 2 } ?? NotificationService.landingDelay
    }

    /// A number's call: in E.164, so it works from a foreign SIM too.
    static func callURL(_ phone: BriefingRegistry.Phone) -> URL? { URL(string: "tel:\(phone.number)") }
}
