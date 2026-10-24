import Foundation

// MARK: - A report in words (6.6.0)

/// The weather block's decoded line (the author's q5 B and f6 A): each report's fields, from the proxy, in words in the
/// app's language and in the report's own units: "Wind 240° 8 kt · 10 km or more · few clouds at 4500 ft · 14 °C, dew
/// point 5 · QNH 1022". Nil when there is nothing to say: the raw report then shows alone. A weather group the words
/// don't know reads as its code (-DRSN), never as a guess. Pure, for the tests.
enum WeatherWords {

    // MARK: METAR

    static func metar(_ d: DecodedMetar) -> String? {
        var parts = conditions(d.conditions)
        parts += d.rvr.map(rvr)
        if let t = d.temperatureC {
            parts.append(d.dewpointC.map { L10n.Weather.temperatureDewpoint(number(t), number($0)) } ?? L10n.Weather.temperature(number(t)))
        }
        if let q = d.qnh {
            parts.append(d.qnhUnit == "inHg" ? L10n.Weather.altimeter(String(format: "%.2f", q)) : L10n.Weather.qnh(number(q)))
        }
        if !d.recentWeather.isEmpty {
            parts.append(L10n.Weather.recent(d.recentWeather.map { weather($0) }.joined(separator: ", ")))
        }
        if !d.windShear.isEmpty {
            parts.append(L10n.Weather.windShear(d.windShear.map { $0 == "ALL" ? L10n.Weather.allRunways : $0 }
                .joined(separator: ", ")))
        }
        if d.nosig { parts.append(L10n.Weather.nosig) }
        guard !parts.isEmpty else { return nil }
        let trends = d.trends.compactMap(trend)
        return ([parts.joined(separator: " · ")] + trends).joined(separator: ". ")
    }

    private static func trend(_ t: DecodedMetar.Trend) -> String? {
        let words = conditions(t.conditions)
        guard !words.isEmpty else { return nil }
        let times = [t.from.map { L10n.Weather.trendFrom(clock($0)) }, t.until.map { L10n.Weather.trendUntil(clock($0)) },
                     t.at.map { L10n.Weather.trendAt(clock($0)) }].compactMap { $0 }
        let head = t.change == "TEMPO" ? L10n.Weather.temporarily : L10n.Weather.becoming
        return ([head] + times).joined(separator: " ") + ": " + words.joined(separator: " · ")
    }

    /// "1130" as "11:30 UTC".
    private static func clock(_ hhmm: String) -> String {
        guard hhmm.count == 4 else { return hhmm }
        return L10n.Weather.utc("\(hhmm.prefix(2)):\(hhmm.suffix(2))")
    }

    // MARK: TAF

    /// The forecast's periods that matter for a flight leaving at `departure` (nil: now): every one still running at
    /// `now` and starting before `departure` plus four hours, a line each: "Until 18 UTC: wind 240° 10 kt · 10 km or
    /// more", "14–18 UTC, at times: 4000 m · rain showers · broken at 2500 ft".
    static func taf(_ d: DecodedTaf, now: Date = Date(), departure: Date? = nil) -> [String] {
        let horizon = (departure ?? now).addingTimeInterval(4 * 3600)
        return d.periods.filter { $0.to > now && $0.from < horizon }.compactMap { period in
            let words = conditions(period.conditions)
            guard !words.isEmpty else { return nil }
            return head(period, now: now) + ": " + words.joined(separator: " · ")
        }
    }

    private static func head(_ p: DecodedTaf.Period, now: Date) -> String {
        // A range names UTC once: "14–18 UTC".
        let from = hour(p.from, now: now, utc: p.change == "base" || p.change == "FM"), to = hour(p.to, now: now)
        switch p.change {
        case "base": return L10n.Weather.until(to)
        case "FM": return L10n.Weather.from(from)
        case "BECMG": return L10n.Weather.becomingBetween(from, to)
        case "TEMPO": return L10n.Weather.atTimesBetween(from, to)
        case "INTER": return L10n.Weather.atIntervalsBetween(from, to)
        default:
            let chance = p.probability ?? 30
            return p.tempo ? L10n.Weather.chanceAtTimes(from, to, chance) : L10n.Weather.chance(from, to, chance)
        }
    }

    /// "18 UTC"; another UTC day than now's says its day: "Sun 03 UTC". Without `utc`, the bare hour of a range's start.
    private static func hour(_ date: Date, now: Date, utc: Bool = true) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let hh = String(format: "%02d", calendar.component(.hour, from: date))
        var text = hh
        if !calendar.isDate(date, inSameDayAs: now) {
            let day = date.formatted(Date.FormatStyle(locale: Locale(identifier: AppLanguage.current), timeZone: calendar.timeZone)
                .weekday(.abbreviated))
            text = "\(day) \(hh)"
        }
        return utc ? L10n.Weather.utc(text) : text
    }

    // MARK: Groups

    static func conditions(_ c: DecodedConditions) -> [String] {
        var parts: [String] = []
        if let w = c.wind { parts.append(wind(w)) }
        if c.cavok {
            parts.append("CAVOK")
        } else if let v = c.visibility {
            parts.append(visibility(v) + (c.minimumVisibility.map { " (" + minimum($0) + ")" } ?? ""))
        }
        parts += c.weather.map { weather($0) }
        if c.noSignificantWeather { parts.append(L10n.Weather.nsw) }
        if !c.clouds.isEmpty {
            parts.append(c.clouds.map(cloud).joined(separator: ", "))
        } else if let n = c.noCloud {
            parts.append(noCloud(n))
        }
        return parts
    }

    static func wind(_ w: DecodedWind) -> String {
        if w.calm { return L10n.Weather.calm }
        let unit = w.unit == "mps" ? "m/s" : w.unit == "kmh" ? "km/h" : "kt"
        let speed = w.speed.map { (w.speedAbove ? L10n.Weather.moreThan("\($0)") : "\($0)") + " " + unit } ?? "–"
        var text = w.variable || w.dirDeg == nil ? L10n.Weather.windVariable(speed)
                                                 : L10n.Weather.wind(String(format: "%03d", w.dirDeg ?? 0), speed)
        if let g = w.gust { text += ", " + L10n.Weather.gusts("\(g) \(unit)") }
        if let from = w.varFromDeg, let to = w.varToDeg { text += ", " + String(format: "%03d–%03d°", from, to) }
        return text
    }

    static func visibility(_ v: DecodedVisibility) -> String {
        let figure: String
        if v.unit == "SM" {
            figure = statuteMiles(v.value) + " SM"
        } else if v.value >= 5000 {
            figure = "\(Int(v.value / 1000)) km"
        } else {
            figure = "\(Int(v.value)) m"
        }
        switch v.qualifier {
        case "atLeast": return L10n.Weather.orMore(figure)
        case "moreThan": return L10n.Weather.moreThan(figure)
        case "lessThan": return L10n.Weather.lessThan(figure)
        default: return figure
        }
    }

    /// 0.25 as "1/4", 1.5 as "1 1/2", 6 as "6".
    private static func statuteMiles(_ value: Double) -> String {
        let whole = Int(value)
        let rest = value - Double(whole)
        let fractions: [(Double, String)] = [(1.0 / 16, "1/16"), (1.0 / 8, "1/8"), (3.0 / 16, "3/16"), (0.25, "1/4"),
                                            (5.0 / 16, "5/16"), (3.0 / 8, "3/8"), (0.5, "1/2"), (5.0 / 8, "5/8"),
                                            (0.75, "3/4"), (7.0 / 8, "7/8")]
        guard rest > 0.01, let f = fractions.min(by: { abs($0.0 - rest) < abs($1.0 - rest) }) else { return "\(whole)" }
        return whole == 0 ? f.1 : "\(whole) \(f.1)"
    }

    private static func minimum(_ m: DecodedMinimumVisibility) -> String {
        let figure = "\(m.value) m"
        return m.direction.map { L10n.Weather.minimumToward(figure, $0) } ?? L10n.Weather.minimum(figure)
    }

    private static func rvr(_ r: DecodedRVR) -> String {
        let unit = r.unit == "ft" ? "ft" : "m"
        func qualified(_ value: Int, _ q: String?) -> String {
            let figure = "\(value) \(unit)"
            return q == "moreThan" ? L10n.Weather.moreThan(figure) : q == "lessThan" ? L10n.Weather.lessThan(figure) : figure
        }
        var text = qualified(r.value, r.qualifier)
        if let max = r.maxValue { text += "–" + qualified(max, r.maxQualifier) }
        switch r.trend {
        case "up": text += ", " + L10n.Weather.rising
        case "down": text += ", " + L10n.Weather.falling
        default: break
        }
        return L10n.Weather.rvr(r.runway, text)
    }

    /// A weather group's words, from the phrase table: "-SHRA" is "light rain showers". A group not in the table
    /// reads as its code.
    static func weather(_ g: DecodedWeatherGroup) -> String {
        let prefix = g.intensity == "light" ? "-" : g.intensity == "heavy" ? "+" : g.intensity == "vicinity" ? "VC" : ""
        let code = prefix + (g.descriptor ?? "") + g.phenomena.joined()
        return phrase(code) ?? code
    }

    private static func cloud(_ c: DecodedCloud) -> String {
        let height = c.baseFt.map { "\($0) ft" }
        var text: String
        switch c.cover {
        case "FEW": text = height.map(L10n.Weather.fewAt) ?? L10n.Weather.few
        case "SCT": text = height.map(L10n.Weather.scatteredAt) ?? L10n.Weather.scattered
        case "BKN": text = height.map(L10n.Weather.brokenAt) ?? L10n.Weather.broken
        case "OVC": text = height.map(L10n.Weather.overcastAt) ?? L10n.Weather.overcast
        case "VV": text = height.map(L10n.Weather.verticalVisibility) ?? L10n.Weather.skyObscured
        default: text = height.map(L10n.Weather.cloudAt) ?? L10n.Weather.cloud
        }
        if let type = c.type { text += " (\(type))" }
        return text
    }

    private static func noCloud(_ code: String) -> String {
        switch code {
        case "NSC": return L10n.Weather.nsc
        case "NCD": return L10n.Weather.ncd
        case "SKC": return L10n.Weather.skc
        default: return L10n.Weather.clr
        }
    }

    /// "14", "-2", "0.5": a figure as the report gives it, never grouped by region.
    private static func number(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value))" : String(format: "%.1f", value)
    }

    // MARK: The phrase table

    /// The weather groups the app has words for, as the weather services write them (`CLAUDE/terminology/
    /// weather-decode.md`): the phenomena alone and with their intensity, and the usual combinations.
    static let phraseCodes: Set<String> = [
        "-DZ", "DZ", "+DZ", "-RA", "RA", "+RA", "-SN", "SN", "+SN", "-RADZ", "RADZ", "-RASN", "RASN", "-SG", "SG",
        "IC", "-PL", "PL", "GR", "GS", "UP", "BR", "FG", "FU", "VA", "DU", "SA", "HZ", "PO", "SQ", "FC", "SS", "DS",
        "-SHRA", "SHRA", "+SHRA", "-SHSN", "SHSN", "+SHSN", "-SHRASN", "SHRASN", "SHGS", "SHGR", "-SHGS",
        "TS", "-TSRA", "TSRA", "+TSRA", "TSGR", "TSGS", "VCTS", "VCSH", "VCFG",
        "BCFG", "MIFG", "PRFG", "FZFG", "-FZRA", "FZRA", "-FZDZ", "FZDZ", "BLSN", "DRSN", "BLSA", "BLDU",
    ]

    private static func phrase(_ code: String) -> String? {
        guard phraseCodes.contains(code) else { return nil }
        // "+" and "-" would make the catalog's generated symbols collide: "heavy_RA", "light_RA".
        let key = "wx.phrase." + code.replacingOccurrences(of: "-", with: "light_").replacingOccurrences(of: "+", with: "heavy_")
        let value = Bundle.main.localizedString(forKey: key, value: nil, table: nil)
        return value == key ? nil : value
    }
}
