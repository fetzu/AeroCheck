import Foundation

// MARK: - The flight's page in words (6.6.0)

/// What the flight's page and Today say, from `FlightPage`'s facts: the status line under the title, each block's
/// name in it and in its head. Pure, so the page, Today and the tests read the same words (f9 A).
enum FlightPageWords {

    /// What makes the words: the flight plan's deadline and the borders' countries need more than the blocks know.
    struct Context {
        var now: Date = Date()
        var calendar: Calendar = .current
        var locale: Locale = .current
        /// When the ATC flight plan must be filed, from the departure country's lead time.
        var fileBy: Date?
        /// A border's country by its code, as the app names it ("Germany").
        var countryName: (String) -> String = { OpenAIPConfig.countryName(for: $0) }
    }

    /// The status line's two lines: when (or where), then what's left.
    static func status(_ status: FlightPageStatus, _ c: Context = Context()) -> (title: String, detail: String) {
        switch status {
        case let .before(departure, now, onTheDay):
            let when = departureWords(departure, c)
            if now.isEmpty && onTheDay.isEmpty { return (L10n.FlightPage.ready(when), "") }
            if onTheDay.isEmpty {
                return (when, L10n.FlightPage.left(now.count, list(now, among: now, c)))
            }
            let later = list(onTheDay, among: now + onTheDay, c)
            if now.isEmpty { return (when, L10n.FlightPage.onTheDay(later)) }
            return (when, L10n.FlightPage.now(list(now, among: now + onTheDay, c)) + " "
                    + L10n.FlightPage.moreOnTheDay(onTheDay.count, later))
        case let .flying(since):
            return (since.map { L10n.FlightPage.flyingSince(time($0, c)) } ?? L10n.FlightPage.flying,
                    L10n.FlightPage.inTheCockpit)
        case let .landed(at, landingTime, left):
            let title: String
            switch (at, landingTime) {
            case let (ident?, t?): title = L10n.FlightPage.landedAt(ident, time(t, c))
            case let (ident?, nil): title = L10n.FlightPage.landedIn(ident)
            default: title = L10n.FlightPage.landed
            }
            return (title, left.isEmpty ? L10n.FlightPage.nothingLeft : L10n.FlightPage.left(left.count, list(left, among: left, c)))
        case let .closed(takeoff, landing):
            guard let takeoff, let landing else { return (L10n.FlightPage.closed, L10n.FlightPage.nothingLeft) }
            let day = takeoff.formatted(.dateTime.day().month(.abbreviated).locale(c.locale))
            return (L10n.FlightPage.flownFromTo(day, time(takeoff, c), time(landing, c)), L10n.FlightPage.nothingLeft)
        }
    }

    /// "Departure in 1 h 50" on the day (until it's due), "Today at 14:30" once due, "Tomorrow at 14:30", "Saturday at
    /// 14:30" within the week, "Sat 7 Nov at 14:30" beyond.
    static func departureWords(_ departure: Date?, _ c: Context) -> String {
        guard let departure else { return L10n.FlightPage.undated }
        let clock = time(departure, c)
        let today = c.calendar.startOfDay(for: c.now)
        let day = c.calendar.startOfDay(for: departure)
        let days = c.calendar.dateComponents([.day], from: today, to: day).day ?? 0
        switch days {
        case 0:
            let minutes = Int(departure.timeIntervalSince(c.now) / 60)
            if minutes < 0 { return L10n.FlightPage.todayAt(clock) }
            if minutes < 1 { return L10n.FlightPage.departureNow }
            return L10n.FlightPage.departureIn(duration(minutes))
        case 1:
            return L10n.FlightPage.tomorrowAt(clock)
        case 2...6:
            return L10n.FlightPage.dayAt(capitalised(departure.formatted(.dateTime.weekday(.wide).locale(c.locale)), c), clock)
        default:
            let date = departure.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(c.locale))
            return L10n.FlightPage.dayAt(capitalised(date, c), clock)
        }
    }

    /// "1h50", "35 min": as ROUTE writes an hour or more (6.3.0, "1h05"), never "1:50", which reads as minutes.
    static func duration(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : String(format: "%dh%02d", minutes / 60, minutes % 60)
    }

    /// The blocks, as the status line names them, in their order: "weather, NOTAMs and airspace, the flight plan by
    /// 13:30, the border". Two borders are named by their countries. `among` is every block the line lists, for that.
    static func list(_ kinds: [FlightBlockKind], among: [FlightBlockKind], _ c: Context) -> String {
        let borders = among.filter { if case .border = $0 { return true } else { return false } }.count
        return kinds.map { item($0, borders: borders, c) }.joined(separator: ", ")
    }

    static func item(_ kind: FlightBlockKind, borders: Int = 1, _ c: Context = Context()) -> String {
        switch kind {
        case .route: return L10n.FlightPage.itemRoute
        case .fuel: return L10n.FlightPage.itemFuel
        case .massAndBalance: return L10n.FlightPage.itemMassBalance
        case .aircraftReserved: return L10n.FlightPage.itemReservation
        case .weather: return L10n.FlightPage.itemWeather
        case .notamsAndAirspace: return L10n.FlightPage.itemNotams
        case .flightPlan: return c.fileBy.map { L10n.FlightPage.itemFlightPlanBy(time($0, c)) } ?? L10n.FlightPage.itemFlightPlan
        case .border(let country): return borders > 1 ? L10n.FlightPage.itemBorderNamed(c.countryName(country)) : L10n.FlightPage.itemBorder
        case .ppr(let ident): return L10n.FlightPage.itemPPR(ident)
        case .navLog: return L10n.FlightPage.itemNavLog
        case .closeFlightPlan: return L10n.FlightPage.itemCloseFlightPlan
        case .fees: return L10n.FlightPage.itemFees
        case .logbook: return L10n.FlightPage.itemLogbook
        }
    }

    /// A block's head.
    static func title(_ kind: FlightBlockKind, _ c: Context = Context()) -> String {
        switch kind {
        case .route: return L10n.FlightPage.blockRoute
        case .fuel: return L10n.FlightPage.blockFuel
        case .massAndBalance: return L10n.Thread.taskMassBalance
        case .aircraftReserved: return L10n.Thread.taskReservation
        case .weather: return L10n.PrepareWeather.title
        case .notamsAndAirspace: return L10n.FlightPage.blockNotams
        case .flightPlan: return L10n.FlightPage.blockFlightPlan
        case .border(let country): return L10n.Thread.taskCustoms(c.countryName(country))
        case .ppr(let ident): return L10n.Thread.taskPPR(ident)
        case .navLog: return L10n.FlightPage.blockNavLog
        case .closeFlightPlan: return L10n.Thread.taskFlightPlanClose
        case .fees(let ident): return L10n.FlightPage.blockFees(ident)
        case .logbook: return L10n.FlightPage.blockLogbook
        }
    }

    /// What a done block's folded line says: when it was done, in the block's own verb.
    static func doneWords(_ block: FlightBlock, _ c: Context = Context()) -> String {
        if block.state == .notApplicable { return L10n.FlightPage.notApplicable }
        if block.isAuto, let detail = block.tasks.compactMap(\.detail).first(where: { !$0.isEmpty }) { return detail }
        guard let at = block.completedAt else { return "" }
        let t = time(at, c)
        switch block.kind {
        case .weather: return L10n.Thread.weatherBriefedAt(t)
        case .notamsAndAirspace: return L10n.FlightPage.checkedAt(t)
        case .flightPlan: return L10n.FlightPage.filedAt(t)
        case .closeFlightPlan: return L10n.FlightPage.closedAt(t)
        default: return L10n.FlightPage.doneAt(t)
        }
    }

    static func time(_ date: Date, _ c: Context) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: c.locale, calendar: c.calendar,
                                        timeZone: c.calendar.timeZone))
    }

    private static func capitalised(_ text: String, _ c: Context) -> String {
        text.prefix(1).uppercased(with: c.locale) + text.dropFirst()
    }
}

// MARK: - One flight's status, wherever it shows (6.6.0, f9 A)

/// A flight's blocks and its status line, from what the app holds: the flight page's line under the title, Today's
/// cards and Plan › Flights read the same words and the same counts in blocks.
@MainActor
enum FlightPageSummary {
    struct Summary {
        let page: FlightPage
        let status: FlightPageStatus
        let title: String
        let detail: String
        /// The blocks the detail names, with their words there, for the page's taps.
        let items: [(kind: FlightBlockKind, words: String)]
        let context: FlightPageWords.Context
        let departure: Date?

        /// What's left, in blocks, for a question or a count.
        var left: Int {
            switch status {
            case let .before(_, now, day): return now.count + day.count
            case let .landed(_, _, left): return left.count
            default: return 0
            }
        }
    }

    static func make(_ thread: FlightThread, trips: [Trip], plans: [FlightPlan], flights: [Flight],
                     currentFlight: Flight?, registry: BriefingRegistry?, now: Date = Date()) -> Summary {
        let plan = thread.flightPlanId.flatMap { id in plans.first { $0.id == id } }
        let departure = thread.scheduledDeparture ?? (plan?.departureIsEstimate == true ? plan?.plannedDepartureTime : nil)
        let page = FlightPage.make(thread: thread, shared: Trip.sharedTasks(for: thread, in: trips), departure: departure,
                                   now: now)
        let countries = thread.countries ?? []
        let departureCountry = FlightThreadManager.departureCountry(of: plan) ?? countries.first
        let lead = FlightBlockDeadline.leadMinutes(registry?.country(departureCountry), countries: countries,
                                                   departureCountry: departureCountry)
        var context = FlightPageWords.Context()
        context.now = now
        context.fileBy = FlightBlockDeadline.fileBy(departure: departure, leadMinutes: lead)

        let landed = thread.landedElsewhere?.landedIdent ?? thread.arrivalIdent
        var flown = FlightPage.Flown(landedIdent: landed)
        if thread.state == .flying {
            flown.takeoff = currentFlight?.lineUpTime
        } else if let id = thread.flightId, let flight = flights.first(where: { $0.id == id }) {
            flown.takeoff = flight.lineUpTime ?? flight.startTime
            flown.landing = flight.landingTime ?? flight.stopTime
        }
        let status = page.status(flown: flown, departure: departure)
        let words = FlightPageWords.status(status, context)
        let kinds: [FlightBlockKind] = {
            switch status {
            case let .before(_, now, day): return now + day
            case let .landed(_, _, left): return left
            default: return []
            }
        }()
        let borders = kinds.filter { if case .border = $0 { return true } else { return false } }.count
        return Summary(page: page, status: status, title: words.title, detail: words.detail,
                       items: kinds.map { ($0, FlightPageWords.item($0, borders: borders, context)) },
                       context: context, departure: departure)
    }
}
