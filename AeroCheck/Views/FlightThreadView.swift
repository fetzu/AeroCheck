import SwiftUI
import QuickLook
import CoreLocation

// MARK: - Task presentation
//
// Copy, icons and links for a task key. Kept out of the model on purpose: a persisted thread stores
// only the key, so switching the app to French re-renders an old thread correctly and the wording can
// change without a data migration.

struct ThreadTaskPresentation {
    let title: String
    let hint: String?
    let icon: String

    /// `briefing` gives a country's airspace activity its hint (the DABS by day). (6.5.0)
    static func make(for task: ThreadTask, briefing: ThreadBriefing? = nil) -> ThreadTaskPresentation {
        switch task.key {
        case .routePlanned:
            return .init(title: L10n.Thread.taskRoute, hint: nil, icon: "point.topleft.down.curvedto.point.bottomright.up")
        case .fuelPlanned:
            return .init(title: L10n.Thread.taskFuel, hint: L10n.Thread.hintFuel, icon: "fuelpump")
        case .massAndBalance:
            return .init(title: L10n.Thread.taskMassBalance, hint: L10n.Thread.hintMassBalance, icon: "scalemass")
        case .aircraftReserved:
            return .init(title: L10n.Thread.taskReservation, hint: L10n.Thread.hintReservation, icon: "calendar")
        case .weatherBriefed:
            return .init(title: L10n.Thread.taskWeather, hint: nil, icon: "cloud.sun")
        case .dabsChecked:
            // One per country since 6.5.0, "Airspace activity CH" as decided (q2). The DABS says which day's it opens,
            // or when the flight's day comes out (the author's v65-2).
            let country = task.briefingCountry
            return .init(title: L10n.Thread.taskAirspace(country), hint: briefing?.dayWords(country), icon: "doc.text")
        case .gaforChecked:
            return .init(title: L10n.Thread.taskForecast(task.briefingCountry), hint: nil, icon: "map")
        case .notamChecked:
            return .init(title: L10n.Thread.taskNotam, hint: nil, icon: "exclamationmark.bubble")
        case .flightPlanFiled:
            return .init(title: L10n.Thread.taskFlightPlanFiled, hint: L10n.Thread.hintFlightPlanFiled, icon: "paperplane")
        case .navLogReady:
            return .init(title: L10n.Thread.taskNavLog, hint: L10n.Thread.hintNavLog, icon: "doc.plaintext")
        case .pprObtained:
            return .init(title: L10n.Thread.taskPPR(task.subject ?? ""), hint: L10n.Thread.hintPPR, icon: "phone")
        case .customsNotified:
            // The hint carries the two facts that decide the pilot's afternoon: whether they must
            // land at a customs field, and whether anyone has to be told first. A country nobody has
            // curated says so rather than implying there is nothing to do.
            let hint: String = {
                guard let country = task.subject, let rule = BorderCrossingGuide.rule(for: country) else {
                    return L10n.Border.notCurated
                }
                var parts = ["\(L10n.Border.customsAerodrome): \(rule.customsAerodrome.label)",
                             "\(L10n.Border.priorNotification): \(rule.priorNotification.label)"]
                if let lead = rule.noticeLeadTime {
                    parts.append("\(L10n.Border.noticeLeadTime): \(lead)")
                }
                // The review date is part of the answer, not a footnote. Nothing here refreshes
                // itself, so how recently a human read the source is what tells the pilot whether to
                // trust these four words or go and look.
                parts.append(L10n.Border.reviewed(rule.lastReviewed))
                // The pack's own caveats, which were written and translated and then never shown.
                // `unknownWarning` only when something in this rule actually IS unknown or
                // disputed — a pilot reading "Official sources disagree" needs to be told what to
                // do about it, and the rest of the time it is noise. (review F28)
                if rule.hasOpenQuestion {
                    parts.append(L10n.Border.unknownWarning)
                }
                parts.append(L10n.Border.advisory)
                return parts.joined(separator: " · ")
            }()
            // The country is shown as a NAME, not the raw ISO-3166 code the task carries as its
            // subject — "Border crossing — DE" was never localized in either language, and the app
            // already resolves this twice over. (review, localization 14)
            let country = task.subject.map { OpenAIPConfig.countryName(for: $0) } ?? ""
            return .init(title: L10n.Thread.taskCustoms(country), hint: hint, icon: "globe.europe.africa")
        case .flightPlanClosed:
            // The rule of the country landed in. (6.5.0)
            return .init(title: L10n.Thread.taskFlightPlanClose, hint: briefing?.closeOut?.rule ?? L10n.CloseOut.ruleUnknown,
                         icon: "checkmark.shield")
        case .feesPaid:
            return .init(title: L10n.Thread.taskFees(task.subject ?? ""), hint: nil, icon: "banknote")
        case .logbookEntry:
            return .init(title: L10n.Thread.taskLogbook, hint: nil, icon: "book")
        case .debriefWritten:
            return .init(title: L10n.Thread.taskDebrief, hint: nil, icon: "text.bubble")
        }
    }

    /// External destinations a task offers. Deep links out rather than integrating: skybriefing is
    /// the official Swiss filing channel and DABS is a public no-login PDF, so a link plus a tick
    /// beats an integration that can be switched off upstream.
    /// `tariffURL` is resolved by the caller (which is on the main actor) rather than looked up
    /// here, so this stays a pure presentation helper with no service reach-through.
    /// `touchesSwitzerland` gates the Swiss half of a customs task. It is passed in rather than
    /// assumed: offering "Swiss side" on a Slovakia → Germany flight is the app claiming a country is
    /// involved that is 300 km away.
    /// `chartLink` is the task's aerodrome's official chart, resolved by the caller like the tariff.
    /// (6.2.0)
    /// `briefing` holds the server's registry and the flight's countries: the briefing tasks' links are its official
    /// pages, a chip each, for every country the route touches (weather, NOTAMs), for the task's country (airspace
    /// activity, area forecast) or the departure's (filing). Until 6.5.0 they were skybriefing's and MeteoSwiss's
    /// wherever the flight went. Without a registry they have none.
    static func links(for task: ThreadTask,
                      tariffURL: URL? = nil,
                      chartLink: OfficialChartLink? = nil,
                      touchesSwitzerland: Bool = false,
                      briefing: ThreadBriefing? = nil) -> [ThreadTaskLink] {
        let chart = chartLink.map { [ThreadTaskLink(label: $0.title, url: $0.url)] } ?? []
        switch task.key {
        case .flightPlanFiled:
            return briefing?.links(.filing, in: [briefing?.departureCountry].compactMap { $0 }) ?? []
        case .notamChecked:
            return briefing?.links(.notam, in: briefing?.countries ?? []) ?? []
        case .weatherBriefed:
            return briefing?.links(.weather, in: briefing?.countries ?? []) ?? []
        case .dabsChecked:
            return briefing?.links(.airspace, in: [task.briefingCountry]) ?? []
        case .gaforChecked:
            return briefing?.links(.forecast, in: [task.briefingCountry]) ?? []
        case .flightPlanClosed:
            // The numbers of the country landed in, then its own links (Swiss SAR Alerts, the online arrival report).
            // A `tel:` link is the whole feature here. Until 6.5.0, Skyguide's wherever the flight landed.
            return briefing?.closeOutLinks ?? []
        case .pprObtained:
            // The chart is where the aerodrome's PPR telephone and hours are. (6.2.0)
            return chart
        case .feesPaid:
            // The operator's OWN tariff page, from the server registry. Absent for an aerodrome
            // nobody has verified yet, which is the honest state rather than a guessed link. The
            // field's official chart next to it. (6.2.0)
            return (tariffURL.map { [ThreadTaskLink(label: L10n.Cost.openTariff, url: $0)] } ?? []) + chart
        case .customsNotified:
            // The authority's own page, in its own language, is the source — the app only points at
            // it. The Swiss side applies whichever country is at the other end, but only when the
            // flight actually touches Switzerland.
            var links: [ThreadTaskLink] = []
            if let country = task.subject, let rule = BorderCrossingGuide.rule(for: country) {
                links.append(ThreadTaskLink(label: L10n.Border.openOfficial, url: rule.officialURL))
            }
            if touchesSwitzerland {
                links.append(ThreadTaskLink(label: L10n.Border.swissSide, url: BorderCrossingGuide.switzerland.officialURL))
            }
            return links
        default:
            return []
        }
    }
}

/// One of a task's links: a row that leaves the app (`ThreadLinkRow`), its publisher's name and what the page takes
/// (a free account, paid, authorised users) or that it is a general page, not one for this task. In the weather block,
/// what it is for and, on a route through several countries, whose it is. (6.5.0, q3)
struct ThreadTaskLink: Equatable {
    let label: String
    var detail: String?
    let url: URL
    var country: String?
    var purpose: String?
}

/// What the briefing tasks' links and hints are made from, resolved by the flight's page on the main actor like the
/// tariff: the server's registry, the route's countries (the departure's first), the departure's country, the day of
/// the flight (the DABS by day) and the app's language. (6.5.0)
struct ThreadBriefing {
    var registry: BriefingRegistry?
    var countries: [String] = []
    var departureCountry: String?
    var flightDay: Date?
    var language: String = AppLanguage.current
    var now: Date = Date()
    /// How the plan is closed where the flight lands. (q3)
    var closeOut: CloseOut?

    /// The close-out's numbers, each a call, then the country's links.
    var closeOutLinks: [ThreadTaskLink] {
        guard let closeOut else { return [] }
        let calls = closeOut.phones.compactMap { phone in
            CloseOut.callURL(phone).map { ThreadTaskLink(label: L10n.CloseOut.call(phone.name), detail: phone.number, url: $0) }
        }
        let links = closeOut.links.map {
            ThreadTaskLink(label: $0.displayName(language: language), detail: Self.accessWord($0.access), url: $0.url)
        }
        return calls + links
    }

    /// `category`'s pages for each of `countries`, in their order, a page that two countries share once. A page by day
    /// whose day for the flight isn't out yet is left out: its hint says when it comes (the author's v65-2).
    func links(_ category: BriefingRegistry.Category, in countries: [String]) -> [ThreadTaskLink] {
        guard let registry else { return [] }
        var seen = Set<URL>()
        var links: [ThreadTaskLink] = []
        for code in countries {
            guard let country = registry.country(code) else { continue }
            for link in country.links(category) {
                if let page = link.dayPage(forFlightOn: flightDay, now: now), !page.isOut { continue }
                let url = link.url(forFlightOn: flightDay, now: now)
                guard seen.insert(url).inserted else { continue }
                let words = [Self.accessWord(link.access),
                             country.generic.contains(category.rawValue) ? L10n.Thread.linkGeneral : nil]
                    .compactMap { $0 }
                links.append(ThreadTaskLink(label: link.displayName(language: language),
                                            detail: words.isEmpty ? nil : words.joined(separator: " · "), url: url,
                                            country: self.countries.count > 1 ? code : nil))
            }
        }
        return links
    }

    /// The weather block's pages: each country's weather, then its area forecast, a page once, what it is for beside it
    /// ("Weather · Area forecast" for a page that gives both). (6.5.0, the author's v65-1)
    func weatherLinks() -> [ThreadTaskLink] {
        var links: [ThreadTaskLink] = []
        for code in countries {
            for (category, purpose) in [(BriefingRegistry.Category.weather, L10n.Thread.linkWeather),
                                        (.forecast, L10n.Thread.linkForecast)] {
                for link in self.links(category, in: [code]) {
                    if let index = links.firstIndex(where: { $0.url == link.url }) {
                        if links[index].purpose?.contains(purpose) == false {
                            links[index].purpose = [links[index].purpose, purpose].compactMap { $0 }.joined(separator: " · ")
                        }
                    } else {
                        var link = link
                        link.purpose = purpose
                        links.append(link)
                    }
                }
            }
        }
        return links
    }

    /// What a country's airspace activity by day says (the author's v65-2, 22 Oct 2026): which day's the link opens, or
    /// when the flight's day comes out. The flight's day and the publisher's days in the publisher's clock, the time in
    /// the device's. Nil for a country without a page by day, or a flight already past.
    func dayWords(_ code: String) -> String? {
        guard let link = registry?.country(code)?.airspace.first(where: { $0.byDay != nil }), let byDay = link.byDay,
              let page = link.dayPage(forFlightOn: flightDay, now: now) else { return nil }
        let name = link.displayName(language: language)
        let time = Self.localTime(byDay.from, tz: byDay.tz, now: now)
        switch page {
        case .today: return L10n.Thread.byDayToday(name)
        case .tomorrow: return L10n.Thread.byDayTomorrow(name)
        case .comesOutToday: return L10n.Thread.byDayLaterToday(name, at: time)
        case .comesOut(on: let day):
            // The app's language in the device's region: "Saturday, 24 October" on a Swiss iPad in English.
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: Locale.current.region.map { "\(language)_\($0.identifier)" } ?? language)
            formatter.timeZone = TimeZone(identifier: byDay.tz)
            formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
            return L10n.Thread.byDayLater(name, for: formatter.string(from: flightDay ?? now),
                                          on: formatter.string(from: day), at: time)
        case .past: return nil
        }
    }

    /// What a page takes, in words (q2: on the chip's second line, as on the official-chart button). Open says nothing.
    static func accessWord(_ access: BriefingRegistry.Access?) -> String? {
        switch access {
        case .account: return L10n.Thread.accessAccount
        case .paid: return L10n.Thread.accessPaid
        case .restricted: return L10n.Thread.accessRestricted
        case .open, nil: return nil
        }
    }

    /// The route's countries where operations are prohibited, with the directive that says so (Belarus). (q5)
    var prohibited: [(country: String, directive: BriefingRegistry.Link)] {
        countries.compactMap { code in registry?.country(code)?.prohibited.map { (code, $0) } }
    }

    /// "16:00" in `tz` (the publisher's), today, as the device's clock reads it.
    static func localTime(_ time: String, tz: String, now: Date = Date()) -> String {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        var calendar = Calendar(identifier: .gregorian)
        guard parts.count == 2, let zone = TimeZone(identifier: tz) else { return time }
        calendar.timeZone = zone
        guard let date = calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: now) else { return time }
        return date.formatted(date: .omitted, time: .shortened)
    }

    /// The departure's aerodrome files from a country that wants a plan activated by the pilot when the field has no
    /// ATS (`activation: "no-ats"`), and the field has neither a tower nor an AFIS in the app's data. A field the
    /// data doesn't know says nothing. (q4)
    static func needsActivation(country: BriefingRegistry.Country?, fieldKnown: Bool,
                                frequencyTypes: [String]) -> Bool {
        guard country?.activatesWithoutATS == true, fieldKnown else { return false }
        return !frequencyTypes.contains { AirportDataService.isContactType($0, "TWR") || AirportDataService.isContactType($0, "AFIS") }
    }
}

// MARK: - Flight Thread screen

/// One followed flight, chapter by chapter. The FLY chapter is shown but not interactive — it is the
/// existing 16-phase flight, and this screen deliberately does not try to own it.
struct FlightThreadView: View {
    /// iPhone gets a different header layout — see `header(_:)`. (device pass)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let threadId: UUID
    var onClose: (() -> Void)?
    /// Supplied by whoever presents this screen, because starting a flight runs `FlightLauncher`'s
    /// whole guard sequence and that belongs to the presenter, not here. `Bool` is circuit mode.
    var onStartFlight: ((Bool) -> Void)?
    /// Opens another leg of the same trip in place of this one. Optional: without it the legs are
    /// listed but not tappable. (v5.1)
    var onOpenLeg: ((UUID) -> Void)?

    @EnvironmentObject var threadManager: FlightThreadManager
    @EnvironmentObject var flightPlanManager: FlightPlanManager
    @Environment(AppState.self) private var appState
    @EnvironmentObject var openAIPDataService: OpenAIPDataService
    @EnvironmentObject var airportDataService: AirportDataService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    /// A dry run's: its coach hears the chips, and its card shows over the page. Nil for the app's own. (6.4.0)
    @Environment(\.dryRunSession) private var dryRunSession
    /// The official-chart registry: a PPR or fee task's chart turns up when it arrives. (6.2.0)
    @ObservedObject private var officialCharts = OfficialChartService.shared
    /// The briefing registry: the briefing tasks' links when it arrives. (6.5.0)
    @ObservedObject private var briefingRegistry = BriefingRegistryService.shared
    /// The reports, for the iPhone weather row's verdict ("No SIGMET"). (6.6.0)
    @ObservedObject private var weatherService = PrepareWeatherService.shared

    /// An item of the status line was tapped: the page goes to its block. (6.6.0)
    @State private var scrollToBlock: FlightBlockKind?
    /// Registration whose mass & balance is open, from the PLAN task. (v5.0.0)
    @State private var weightBalanceRegistration: String?
    /// Flight whose cost and logbook line are open, from the CLOSE tasks. (v5.0.0)
    @State private var numbersFlightId: UUID?
    /// Confirmation for the ICAO flight-plan copy, which is otherwise invisible. (v5.0.0)
    @State private var copiedFPL = false
    /// Cancel flight's question is showing. (v6.0 review, B4)
    @State private var confirmingCancel = false
    /// Cancel trip's question is showing. (6.1)
    @State private var confirmingTripCancel = false
    /// The nav log rendered to a file and shown in Quick Look, where it can be read, printed,
    /// marked up, saved or shared. (A bare share sheet offered none of the first three on iPad.)
    /// Staged for this preview only, and removed once it closes. (S9-06)
    @State private var navLogPreview: StagedExport?
    /// Plan open in the map builder, from the route task. (v5.0.0)
    @State private var routeBuilderPlanId: UUID?
    /// Plan open in the details editor, from the fuel task. (v5.0.0)
    @State private var planEditorPlan: FlightPlan?
    /// "Edit route" chosen in the flight sheet: the route editor opens once the sheet has closed.
    /// It used to only close the sheet. (planning proposal A)
    @State private var routeAfterEditorPlanId: UUID?
    /// Plan whose fuel on board is being set, from a tap on the fuel task. (on-device review #4)
    @State private var fuelSheetPlanId: UUID?
    /// "Fuel & times" chosen in the fuel sheet: the nav log sheet opens once that one has closed.
    @State private var openEditorAfterFuel = false
    /// The plan the fuel sheet was last opened for: `fuelSheetPlanId` is already nil in `onDismiss`.
    @State private var lastFuelPlanId: UUID?
    /// Renaming the flight, or its trip. (on-device review #4)
    @State private var renaming: RenameTarget?
    @State private var renameText = ""

    private enum RenameTarget: Equatable { case flight, trip(UUID) }
    /// "Add a stop" sheet. (v5.1)
    @State private var addingStop = false
    /// Chapters and blocks shown open although done, waiting for the day or before the landing: a tap on their line
    /// opens them in place. (6.6.0)
    @State private var unfoldedChapters: Set<ThreadChapter> = []
    @State private var unfoldedBlocks: Set<FlightBlockKind> = []
    /// The iPhone's block whose sheet is open (C), and what a tool tapped in it opens once the sheet has gone: a
    /// second sheet can't open over the first. (6.6.0)
    @State private var openBlock: OpenBlock?
    @State private var afterBlockSheet: (() -> Void)?

    struct OpenBlock: Identifiable { let kind: FlightBlockKind; var id: FlightBlockKind { kind } }
    /// "Start now" pressed on a flight planned for another day: the question before it starts.
    @State private var confirmingEarlyStart = false
    /// The trip's flown legs, shared as one card from beside the leg strip. (6.1)
    @State private var journeyShare: JourneyShareRequest?

    private var thread: FlightThread? { threadManager.thread(withId: threadId) }

    var body: some View {
        ZStack {
            Color.cockpitBackground.ignoresSafeArea()

            if let thread {
                ScrollViewReader { scroller in
                VStack(spacing: 0) {
                    header(thread)
                    // One line in place of the ring, the chapter pills, the state chip and NEXT (round 2). (6.6.0)
                    statusLine(thread)
                    if let trip = threadManager.trip(forThreadId: thread.id) {
                        tripStrip(trip, leg: thread)
                    }
                    Divider().overlay(Color.white.opacity(0.06))
                    ScrollView {
                        VStack(spacing: 12) {
                            // The red card leads: while the plan is open it is the flight plan's block, so CLOSE
                            // doesn't list it a second time.
                            if thread.hasOpenFlightPlanAfterFlight {
                                openFlightPlanCard(thread)
                            }
                            continuationCard(thread)
                            prohibitedCard(thread)
                            chapters(thread)
                            footer(thread)
                                .id(Self.footerId)
                            // A dry run's: room under Finish, so the page can bring it above the coach's card.
                            if dryRunSession != nil {
                                Color.clear.frame(height: DryRunCoachCard.room)
                            }
                        }
                        .padding(usesTwoColumns ? 20 : 14)
                        .frame(maxWidth: usesTwoColumns ? 980 : 760)
                        .frame(maxWidth: .infinity)
                    }
                }
                // A dry run's coach rings a block lower down the page: the page goes to it first. (6.4.0)
                .onDryRunCoachStep(dryRunSession) { step in
                    guard step.screen == .flightPage, let id = Self.scrollTarget(of: step) else { return }
                    withAnimation(.easeInOut(duration: 0.3)) { scroller.scrollTo(id, anchor: UnitPoint(x: 0.5, y: 0.25)) }
                }
                // An item of the status line: its block, its chapter opened. (6.6.0)
                .onChange(of: scrollToBlock) { _, kind in
                    guard let kind else { return }
                    scrollToBlock = nil
                    unfoldedChapters.insert(kind.chapter)
                    unfoldedBlocks.insert(kind)
                    withAnimation(.easeInOut(duration: 0.25)) { scroller.scrollTo(AnyHashable(kind), anchor: .top) }
                }
                }
            } else {
                // The thread was deleted underneath us (another device, or the pilot). Say so rather
                // than showing an empty shell.
                VStack(spacing: 12) {
                    Image(systemName: "questionmark.folder")
                        .scaledFont(size: 32, relativeTo: .largeTitle)
                        .foregroundColor(.dimText)
                    Text(L10n.Thread.noThread)
                        .scaledFont(size: 15, relativeTo: .subheadline)
                        .foregroundColor(.secondaryText)
                    Button(L10n.Button.close) { close() }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
        // Derived bindings rather than `item:` — neither String nor UUID is Identifiable, and a
        // retroactive conformance on a stdlib type is not worth two presentations.
        .sheet(isPresented: Binding(
            get: { weightBalanceRegistration != nil },
            set: { if !$0 { weightBalanceRegistration = nil } }
        )) {
            if let registration = weightBalanceRegistration {
                WeightBalanceView(registration: registration,
                                  onClose: { weightBalanceRegistration = nil })
            }
        }
        .sheet(isPresented: Binding(
            get: { numbersFlightId != nil },
            set: { if !$0 { numbersFlightId = nil } }
        )) {
            if let id = numbersFlightId {
                FlightNumbersView(flightId: id, onClose: { numbersFlightId = nil })
                    .environment(\.dryRunSession, dryRunSession)
                    .dryRunCoachScreen(.numbers)
            }
        }
        .quickLookPreview(.preview($navLogPreview))
        .fullScreenCover(isPresented: Binding(
            get: { routeBuilderPlanId != nil },
            set: { if !$0 { routeBuilderPlanId = nil } }
        )) {
            if let id = routeBuilderPlanId {
                FlightPlanMapBuilderView(planId: id)
            }
        }
        // `onDismiss` rather than relying on the plan-watching onChange alone: the editor flushes
        // its debounced commit in its own `onDisappear`, and the pilot should not have to leave the
        // flight and come back to see the fuel row settle. (device pass)
        .sheet(item: $planEditorPlan, onDismiss: {
            refreshFromPlan()
            // "Edit route" in the flight sheet: the route editor, once the sheet has gone.
            if let id = routeAfterEditorPlanId { routeBuilderPlanId = id }
            routeAfterEditorPlanId = nil
        }) { plan in
            FlightPlanEditorView(flightPlan: plan, onEditRoute: {
                routeAfterEditorPlanId = plan.id
                planEditorPlan = nil
            })
        }
        .sheet(isPresented: Binding(
            get: { fuelSheetPlanId != nil },
            set: { if !$0 { fuelSheetPlanId = nil } }
        ), onDismiss: {
            refreshFromPlan()
            if openEditorAfterFuel, let id = fuelSheetPlanId ?? lastFuelPlanId,
               let plan = flightPlanManager.flightPlans.first(where: { $0.id == id }) {
                planEditorPlan = plan
            }
            openEditorAfterFuel = false
        }) {
            if let id = fuelSheetPlanId {
                FuelOnBoardSheet(planId: id, onOpenFullEditor: {
                    openEditorAfterFuel = true
                    fuelSheetPlanId = nil
                })
                .environment(\.dryRunSession, dryRunSession)
                .dryRunCoachScreen(.fuelSheet)
            }
        }
        .sheet(item: $journeyShare) { request in
            JourneyShareCustomizationView(flights: request.flights, appState: appState,
                                          airports: airportDataService, title: request.title)
        }
        #if DEBUG
        // The dry run's DEBUG autopilot, in place of a tap: the fuel sheet, the logbook line, Finish. (6.4.0)
        .dryRunAutopilotTap { tap in
            guard dryRunSession != nil, let thread else { return }
            switch tap {
            case .open(.fuelSheet): fuelSheetPlanId = thread.flightPlanId
            case .close(.fuelSheet): fuelSheetPlanId = nil
            case .open(.numbers): numbersFlightId = thread.flightId
            case .close(.numbers): numbersFlightId = nil
            case .close(.flightPage): close()
            default: break
            }
        }
        #endif
        // A block of the iPhone's checklist, opened: the iPad's card, under Done. (6.6.0, C)
        .sheet(item: $openBlock, onDismiss: {
            let next = afterBlockSheet
            afterBlockSheet = nil
            next?()
        }) { item in
            if let thread, let block = page(for: thread).block(item.kind) {
                FlightBlockSheet(onDone: { openBlock = nil }) {
                    blockCard(block, thread, foldable: false)
                }
                .environment(\.dryRunSession, dryRunSession)
                .dryRunCoachSheet(of: .flightPage)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $addingStop) {
            AddStopSheet(threadId: threadId) { _ in addingStop = false }
                .environmentObject(threadManager)
                .environmentObject(flightPlanManager)
                .environmentObject(airportDataService)
        }
        .copiedConfirmation(L10n.Nav.icaoFlightPlanCopied, isPresented: $copiedFPL)
        .alert(renaming == .flight ? L10n.FlightNames.renameFlight : L10n.FlightNames.renameTrip,
               isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(L10n.Routes.namePlaceholder, text: $renameText)
            Button(L10n.Button.cancel, role: .cancel) { renaming = nil }
            Button(L10n.Routes.rename) {
                switch renaming {
                case .flight: threadManager.renameFlight(threadId, to: renameText)
                case .trip(let id): threadManager.renameTrip(id, to: renameText)
                case nil: break
                }
                renaming = nil
            }
        } message: {
            Text(renaming == .flight ? L10n.FlightNames.renameFlightMessage : L10n.FlightNames.renameTripMessage)
        }
        // Warm the tariff registry so the fee task can offer the operator's page. Cached for a week
        // and silent on failure — a missing link is a missing convenience, never an error.
        .task { await AirfieldTariffService.shared.refreshIfNeeded() }
        // The aerodromes' types, which a French official chart needs (the chart registry itself is
        // refreshed by the app on launch and on return). (6.2.0)
        .task { await airportDataService.ensureLoaded() }
        // The AUTO rows are a computation over the plan, and the plan is edited from sheets this
        // screen presents. Without this they kept the values they were generated with — a fuel row
        // reading REQ 0 / FOB 0 forever, and never ticking itself once the tanks were entered.
        // `regenerateTasks` preserves everything the pilot has ticked, so this is safe to run often.
        .onAppear { refreshFromPlan() }
        // Every save of the plans, not `.onChange(of:)`: `FlightPlan`'s `==` compares ids only, so an
        // edited plan never counted as a change, and the fuel entered in the details sheet stayed
        // unseen until the page was reopened. The editor also saves after the sheet's `onDismiss`
        // has run, which is why that refresh came too early. (on-device review #1, T-01)
        .onReceive(flightPlanManager.$flightPlans) { _ in refreshFromPlan() }
    }

    private func refreshFromPlan() {
        guard let thread = threadManager.thread(withId: threadId) else { return }
        threadManager.regenerateTasks(threadId: threadId, plan: plan(for: thread))
    }

    // MARK: - Header

    /// The header, which on iPhone could not fit what it was asked to show.
    ///
    /// Back button, route thumbnail, title, subtitle, state chip and readiness ring is roughly 334pt
    /// of fixed furniture on a 390pt screen — so the route label, the one thing the screen is about,
    /// got the ~56pt left over and rendered as "LSGS →…". Shrinking it to fit would have put it near
    /// 6pt. So on compact width the STATE CHIP moves down to the chapter bar, where it sits happily
    /// beside the per-chapter progress and where there is spare room; the title gets that width
    /// back and shows in full. iPad, which has the room, is unchanged. (device pass)
    private var usesCompactHeader: Bool { horizontalSizeClass == .compact }

    private func header(_ thread: FlightThread) -> some View {
        HStack(spacing: usesCompactHeader ? 10 : 14) {
            Button { close() } label: {
                Image(systemName: "chevron.left")
                    .scaledFont(size: 17, weight: .semibold, relativeTo: .body)
                    .foregroundColor(.secondaryText)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.Button.close)

            // The route, as a picture. The header named it and could not show it, which for a
            // flight-planning app is the wrong way round: a shape is recognised faster than
            // "LSZB → LSZQ" is read, and a route that is visibly wrong is caught before departure
            // rather than in the cockpit. Reuses the plan list's cached snapshot component, so this
            // costs one more consumer rather than a second implementation.
            if let plan = plan(for: thread), !plan.waypoints.isEmpty {
                Button { routeBuilderPlanId = plan.id } label: {
                    RouteThumbnail(waypoints: plan.waypoints)
                        .frame(width: usesCompactHeader ? 54 : 68,
                               height: usesCompactHeader ? 38 : 46)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.Thread.editRoute)
                .accessibilityHint(thread.routeLabel)
            }

            // The title opens the flight's own details — the date, the pilot, the fuel. It names the
            // flight, so it is where a pilot reaches when they want to change something about it,
            // and the thumbnail beside it already opens the route. (device pass)
            Button { planEditorPlan = plan(for: thread) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(thread.displayName)
                        .scaledFont(size: 19, weight: .semibold, design: thread.name == nil ? .monospaced : .default,
                                    relativeTo: .title3)
                        .foregroundColor(.primaryText)
                        .lineLimit(1)
                        // A safety net for a long label, not the mechanism — the space comes from
                        // the layout above, so this only ever nudges.
                        .minimumScaleFactor(0.7)
                    Text(subtitle(thread))
                        .scaledFont(size: 12, relativeTo: .caption)
                        .foregroundColor(.dimText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(plan(for: thread) == nil)
            .accessibilityHint(L10n.Nav.flightPlanDetails)

            // A name of the pilot's own, whatever the ends. (on-device review #4)
            Button {
                renameText = thread.name ?? ""
                renaming = .flight
            } label: {
                Image(systemName: "pencil")
                    .scaledFont(size: 15, weight: .semibold, relativeTo: .body)
                    .foregroundColor(.aviationGold)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.FlightNames.renameFlight)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.panelBackground)
    }

    private func subtitle(_ thread: FlightThread) -> String {
        var parts: [String] = []
        // Named: the route's ends move here, so they're never out of sight.
        if thread.name != nil { parts.append(thread.routeLabel) }
        // Where this leg sits comes first: on a trip it is the thing that tells one leg from another,
        // since two legs of the same trip share their aircraft and often their date.
        if let trip = threadManager.trip(forThreadId: thread.id),
           let leg = trip.legNumber(of: thread.id) {
            parts.append(L10n.Flights.legOf(leg, trip.legCount))
        }
        if let departure = thread.scheduledDeparture {
            parts.append(departure.formatted(date: .abbreviated, time: .shortened))
        } else if let plan = plan(for: thread), plan.departureIsEstimate == true,
                  let estimate = plan.plannedDepartureTime {
            // A later leg of a trip: when it leaves depends on when the one before lands. (v5.1)
            parts.append(L10n.Trip.estimated(estimate.formatted(date: .omitted, time: .shortened)))
        }
        if let registration = thread.aircraftRegistration, !registration.isEmpty {
            parts.append(registration)
        }
        return parts.joined(separator: " · ")
    }

    /// A leg's trip tasks as the leg sees them; none for a flight on its own. Counted with its own everywhere on the page:
    /// the ring, the state, the chapters, NEXT and "Everything done" (the author's device check, 23 Oct 2026). (6.5.0)
    private func sharedTasks(of thread: FlightThread) -> [ThreadTask] {
        Trip.sharedTasks(for: thread, in: threadManager.trips)
    }

    /// Fuel on board short of what the flight requires, said on the flight's page and not only in
    /// the fuel sheet, where it was the one place "Short by X L" appeared. (v6.0 review, B3)
    private func fuelWarning(for task: ThreadTask, in thread: FlightThread) -> String? {
        guard task.key == .fuelPlanned, task.state != .notApplicable, let plan = plan(for: thread),
              case .short(let litres) = FuelOnBoardStatus.make(onBoard: plan.fuelOnBoard,
                                                               required: plan.fuelRequired,
                                                               flowLitresPerHour: plan.effectiveFuelFlow)
        else { return nil }
        return L10n.FuelOnBoard.short(String(format: "%.1f", litres))
    }

    // MARK: - The trip, under the status line (6.6.0)

    /// What the trip band held that isn't preparation (round 1 q6 A, round 2): the trip's name, a tap renames it; its
    /// legs, a tap opens one; Share the trip once two are flown; the stop before this leg. The trip's briefing is in
    /// this leg's own blocks, ticked for every leg.
    private func tripStrip(_ trip: Trip, leg: FlightThread) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                renameText = trip.name ?? ""
                renaming = .trip(trip.id)
            } label: {
                HStack(spacing: 5) {
                    Text((trip.name ?? tripLabel(trip)).uppercased())
                        .scaledFont(size: 11, weight: .bold, design: .monospaced, relativeTo: .caption2)
                        .foregroundColor(.aviationGold)
                        .tracking(0.8)
                        .lineLimit(1)
                    Image(systemName: "pencil")
                        .scaledFont(size: 10, weight: .semibold, relativeTo: .caption2)
                        .foregroundColor(.aviationGold)
                }
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.FlightNames.renameTrip)
            .padding(.horizontal, 16)
            legStrip(trip, current: leg)
            stopoverLine(leg, in: trip)
        }
        .padding(.bottom, 4)
        .background(Color.panelBackground)
    }

    /// The trip's legs in order, this one highlighted, flown ones ticked. Tapping another leg opens
    /// it here, so a pilot working through a trip does not have to go back to the list for each.
    private func legStrip(_ trip: Trip, current: FlightThread) -> some View {
        let legs = threadManager.legs(of: trip)
        let flown = flownFlights(of: legs)
        return HStack(spacing: 0) {
            legChips(legs, current: current)
            // Once two legs or more are flown: the trip as one card, the legs flown so far. (6.1)
            if flown.count >= 2 {
                Button {
                    journeyShare = JourneyShareRequest(flights: flown, title: L10n.ShareCard.shareTrip)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.up")
                            .scaledFont(size: 13, weight: .semibold, relativeTo: .caption)
                        Text(L10n.ShareCard.shareTrip)
                            .scaledFont(size: 13, weight: .bold, relativeTo: .caption)
                            .lineLimit(1)
                    }
                    .foregroundColor(.aviationGold)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.aviationGold, lineWidth: 1.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .padding(.trailing, 12)
                .padding(.vertical, 4)
            }
        }
    }

    /// The legs' recorded flights, in the trip's order: a leg is in once END FLIGHT has saved it.
    private func flownFlights(of legs: [FlightThread]) -> [Flight] {
        legs.compactMap { leg in leg.flightId.flatMap { id in appState.flights.first { $0.id == id } } }
    }

    private func legChips(_ legs: [FlightThread], current: FlightThread) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(legs.enumerated()), id: \.element.id) { index, leg in
                    let isCurrent = leg.id == current.id
                    let flown = leg.flightId != nil && (leg.state == .closeOut || leg.state == .done)
                    Button {
                        if !isCurrent { onOpenLeg?(leg.id) }
                    } label: {
                        HStack(spacing: 6) {
                            Text("\(index + 1)")
                                .font(.aero(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(.aviationGold)
                            Text(leg.displayName)
                                .scaledFont(size: 12, design: .monospaced, relativeTo: .caption)
                                .foregroundColor(isCurrent ? .primaryText : .secondaryText)
                                .lineLimit(1)
                            if flown {
                                Image(systemName: "checkmark")
                                    .font(.aero(size: 10, weight: .bold))
                                    .foregroundColor(.aviationGreen)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(isCurrent ? Color.aviationGold.opacity(0.18) : Color.cockpitBackground))
                        .overlay(Capsule().strokeBorder(isCurrent ? Color.aviationGold.opacity(0.6) : Color.clear, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(isCurrent || onOpenLeg == nil)
                    .accessibilityLabel(L10n.Flights.legOf(index + 1, legs.count) + ", " + leg.displayName)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    /// "Cancel whole trip (n legs)", beside "Cancel this leg" at the foot of the page: every leg not
    /// flown yet goes, each as "Cancel this leg" takes one (`FlightCreator.cancelTrip`). Offered while
    /// a leg is left to cancel and none is in the air (`FlightThreadManager.canCancel`), and only when
    /// it takes more than this leg. It sat under the leg strip, where it read as this leg's own
    /// cancel (6.1.0 device check): both now sit at the foot, each naming what it takes, and the one
    /// at the foot that every flight has still takes the one leg. It asks first, naming the legs. (6.1)
    private func tripLegsToCancel(_ thread: FlightThread) -> (trip: Trip, legs: [FlightThread])? {
        guard let trip = threadManager.trip(forThreadId: thread.id),
              FlightThreadManager.canCancel(trip, threads: threadManager.threads, flyingPlanId: flyingPlanId)
        else { return nil }
        let legs = FlightThreadManager.legsToCancel(in: trip, threads: threadManager.threads,
                                                    flyingPlanId: flyingPlanId)
        guard legs.map(\.id) != [thread.id] else { return nil }
        return (trip, legs)
    }

    /// Quiet red text, as the leg's own cancel beside it.
    private func cancelButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) {
            Text(title)
                .scaledFont(size: 13, relativeTo: .footnote)
                .foregroundColor(.aviationRed.opacity(0.9))
                .multilineTextAlignment(.center)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The legs that go, one a line ("Leg 2 · LSGE → LSGN", numbered as the strip numbers them), and
    /// what stays: the legs already flown, with their flights in the logbook.
    private func cancelTripMessage(_ trip: Trip) -> String {
        let legs = threadManager.legs(of: trip)
        let lines = legs.enumerated()
            .filter { !FlightThreadManager.isFlownOrFlying($0.element, flyingPlanId: flyingPlanId) }
            .map { L10n.Trip.cancelConfirmLeg($0.offset + 1, $0.element.displayName) }
            .joined(separator: "\n")
        let keepsFlown = legs.contains { FlightThreadManager.isFlownOrFlying($0, flyingPlanId: flyingPlanId) }
        return L10n.Trip.cancelConfirmMessage(lines, keepsFlown: keepsFlown)
    }

    /// This leg's stop, before it leaves: "Stop at LSGE", the time on the ground and the refuel,
    /// editable until the leg flies, and when the leg leaves as a result. A trip typed in Plan new
    /// flight could not change these after creation. Legs 2 and on; not a leg planned after a
    /// diversion, which has no stop, only a field it landed at. (6.1)
    @ViewBuilder
    private func stopoverLine(_ leg: FlightThread, in trip: Trip) -> some View {
        if let position = trip.legIds.firstIndex(of: leg.id), position > 0,
           let plan = plan(for: leg), let stopover = plan.stopover {
            let ident = plan.waypoints.first?.name ?? ""
            let editable = leg.flightId == nil && (leg.state == .planned || leg.state == .ready)
            VStack(alignment: .leading, spacing: 0) {
                Divider().overlay(Color.white.opacity(0.06))
                SeparateView {
                    StopoverRow(label: L10n.AddStops.stopAt(ident), stopover: stopover, indent: 0,
                                stepperFill: .cockpitBackground,
                                onChange: editable ? { changed in
                                    _ = FlightCreator.setStopover(changed, onLeg: leg.id,
                                                              plans: flightPlanManager, threads: threadManager)
                                } : nil)
                }
                if editable, let caption = stopoverDeparture(plan) {
                    Text(caption)
                        .scaledFont(size: 12, relativeTo: .caption)
                        .foregroundColor(.dimText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 8)
                }
                Divider().overlay(Color.white.opacity(0.06))
            }
            .padding(.horizontal, 14)
        }
    }

    /// When the leg leaves: estimated from the stop, or the time the pilot chose, which a new time on
    /// the ground turns back into an estimate.
    private func stopoverDeparture(_ plan: FlightPlan) -> String? {
        guard let departure = plan.plannedDepartureTime else { return nil }
        let time = departure.formatted(date: .omitted, time: .shortened)
        return plan.departureIsEstimate == true
            ? L10n.AddStops.leavesEstimated(time)
            : L10n.AddStops.leavesChosen(time)
    }

    /// "LSZQ → LFSB → LSGY" from the legs themselves, so it stays right when one is added or removed.
    private func tripLabel(_ trip: Trip) -> String {
        let legs = threadManager.legs(of: trip)
        guard let first = legs.first else { return "" }
        var idents = [first.routeLabel.components(separatedBy: " → ").first ?? ""]
        idents += legs.compactMap { $0.routeLabel.components(separatedBy: " → ").last }
        return idents.filter { !$0.isEmpty }.joined(separator: " → ")
    }

    private func shortTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    private static let footerId = "footer"
    private static let debriefId = "debrief"

    /// Where the page goes for a dry run's step: the block its ring is in, the Fly chapter's START FLIGHT, the
    /// footer's Finish. The status line, where the page's own steps are, never scrolls. (6.4.0, 6.6.0)
    private static func scrollTarget(of step: DryRunCoachStep) -> AnyHashable? {
        switch step.target {
        case .fuelRow?: return AnyHashable(FlightBlockKind.fuel)
        case .notamLink?, .notamTick?: return AnyHashable(FlightBlockKind.notamsAndAirspace)
        case .flightPlanRow?: return AnyHashable(FlightBlockKind.flightPlan)
        case .logbookRow?, .logbookTick?: return AnyHashable(FlightBlockKind.logbook)
        case .debriefField?: return AnyHashable(debriefId)
        case .startFlight?: return AnyHashable(ThreadChapter.fly)
        case .finish?: return AnyHashable(footerId)
        default: return nil
        }
    }

    private func chapterName(_ chapter: ThreadChapter) -> String {
        switch chapter {
        case .plan:    return L10n.Thread.chapterPlan
        case .prepare: return L10n.Thread.chapterPrepare
        case .fly:     return L10n.Thread.chapterFly
        case .close:   return L10n.Thread.chapterClose
        }
    }

    // MARK: - The page as blocks (6.6.0)

    /// The iPad's layout (A, the author's q2): two columns where the width allows (f3 A). The iPhone's (C) is its
    /// checklist with a sheet per block.
    private var usesTwoColumns: Bool { horizontalSizeClass == .regular }

    private func page(for thread: FlightThread) -> FlightPage {
        FlightPage.make(thread: thread, shared: sharedTasks(of: thread), departure: departure(of: thread))
    }

    /// When the flight leaves: its own time, or a later leg's estimate from its stop.
    private func departure(of thread: FlightThread) -> Date? {
        if let departure = thread.scheduledDeparture { return departure }
        guard let plan = plan(for: thread), plan.departureIsEstimate == true else { return nil }
        return plan.plannedDepartureTime
    }

    /// When the ATC flight plan must be filed, from the departure country's lead time in the registry (f7 A).
    private func fileBy(for thread: FlightThread) -> Date? {
        let b = briefing(for: thread)
        let lead = FlightBlockDeadline.leadMinutes(b.registry?.country(b.departureCountry), countries: b.countries,
                                                   departureCountry: b.departureCountry)
        return FlightBlockDeadline.fileBy(departure: departure(of: thread), leadMinutes: lead)
    }

    private func wordsContext(for thread: FlightThread) -> FlightPageWords.Context {
        var context = FlightPageWords.Context()
        context.fileBy = fileBy(for: thread)
        return context
    }

    /// What the flight recorded, for the status line: take-off and landing as the track measured them.
    private func flown(_ thread: FlightThread) -> FlightPage.Flown {
        let landed = thread.landedElsewhere?.landedIdent ?? thread.arrivalIdent
        if thread.state == .flying {
            return .init(takeoff: appState.currentFlight?.lineUpTime, landedIdent: landed)
        }
        guard let id = thread.flightId, let flight = appState.flights.first(where: { $0.id == id }) else {
            return .init(landedIdent: landed)
        }
        return .init(takeoff: flight.lineUpTime ?? flight.startTime, landing: flight.landingTime ?? flight.stopTime,
                     landedIdent: landed)
    }

    /// The flight's status in one place, as Today and Plan › Flights read it (f9 A).
    private func summary(_ thread: FlightThread) -> FlightPageSummary.Summary {
        FlightPageSummary.make(thread, trips: threadManager.trips, plans: flightPlanManager.flightPlans,
                               flights: appState.flights, currentFlight: appState.currentFlight,
                               registry: briefingRegistry.registry)
    }

    private func statusLine(_ thread: FlightThread) -> some View {
        let summary = summary(thread)
        return FlightStatusLine(title: summary.title, detail: summary.detail, items: summary.items,
                                isReady: summary.status.isReady) { scrollToBlock = $0 }
            .padding(.leading, usesCompactHeader ? 16 : 72)
            .padding(.trailing, 16)
            .padding(.bottom, 10)
            .background(Color.panelBackground)
            // The dry run's steps about the page itself point here (the ring, the chapters and NEXT are gone).
            .coachTarget(.chapterBar)
            .coachTarget(.nextCard)
            .coachTarget(.readiness)
    }

    /// A route through a country whose airspace is closed, above the chapters before the flight: red, with the
    /// directive. Nothing is blocked. (6.5.0, q5)
    @ViewBuilder
    private func prohibitedCard(_ thread: FlightThread) -> some View {
        let prohibited = briefing(for: thread).prohibited
        if !prohibited.isEmpty, thread.state == .planned || thread.state == .ready {
            VStack(spacing: 0) {
                ForEach(prohibited, id: \.country) { item in
                    ProhibitedCountryRow(country: item.country, directive: item.directive) { openURL($0) }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    /// The chapters (f1 A): before the flight in their order; after it CLOSE first, then FLY's line, then PLAN and
    /// PREPARE as one line.
    @ViewBuilder
    private func chapters(_ thread: FlightThread) -> some View {
        let page = page(for: thread)
        if thread.state == .closeOut || thread.state == .done {
            chapterView(.close, page: page, thread: thread)
            flyChapter(thread).id(ThreadChapter.fly)
            if unfoldedChapters.contains(.plan) || unfoldedChapters.contains(.prepare) {
                chapterView(.plan, page: page, thread: thread)
                chapterView(.prepare, page: page, thread: thread)
            } else {
                FlightFoldedLine(look: .done, title: L10n.FlightPage.planAndPrepare.uppercased(),
                                 detail: L10n.FlightPage.doneBeforeFlight) {
                    withAnimation(.easeInOut(duration: 0.2)) { unfoldedChapters.formUnion([.plan, .prepare]) }
                }
            }
        } else {
            ForEach(ThreadChapter.allCases) { chapter in
                chapterView(chapter, page: page, thread: thread)
            }
        }
    }

    /// CLOSE without the flight plan's block while the red card is up: the card is that block.
    private func shownBlocks(_ chapter: ThreadChapter, _ page: FlightPage, _ thread: FlightThread) -> [FlightBlock] {
        page.blocks(in: chapter).filter { !($0.kind == .closeFlightPlan && thread.hasOpenFlightPlanAfterFlight) }
    }

    @ViewBuilder
    private func chapterView(_ chapter: ThreadChapter, page: FlightPage, thread: FlightThread) -> some View {
        let shape = page.shape(of: chapter)
        let blocks = shownBlocks(chapter, page, thread)
        if shape == .fly {
            flyChapter(thread).id(ThreadChapter.fly)
        } else if shape == .open || unfoldedChapters.contains(chapter) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 4) {
                    FlightChapterHead(name: chapterName(chapter), count: chapterCount(blocks))
                    if shape != .open {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { _ = unfoldedChapters.remove(chapter) }
                        } label: {
                            Image(systemName: "chevron.up")
                                .scaledFont(size: 13, weight: .semibold, relativeTo: .footnote)
                                .foregroundColor(.dimText)
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.Button.close)
                    }
                }
                if usesChecklist {
                    checklistGroup(chapter, blocks: blocks, thread: thread)
                } else {
                    blockGrid(chapter, blocks: blocks, thread: thread)
                }
            }
            .id(chapter)
        } else if !blocks.isEmpty {
            FlightFoldedLine(look: shape == .done ? .done : .waiting, title: chapterName(chapter).uppercased(),
                             detail: chapterLine(chapter, shape: shape, blocks: blocks, thread: thread)) {
                withAnimation(.easeInOut(duration: 0.2)) { _ = unfoldedChapters.insert(chapter) }
            }
            .id(chapter)
        }
    }

    /// "1 of 5": done against what applies.
    private func chapterCount(_ blocks: [FlightBlock]) -> String? {
        let counted = blocks.filter { $0.state != .notApplicable }
        guard !counted.isEmpty else { return nil }
        return L10n.FlightPage.chapterCount(counted.filter { $0.state == .done }.count, counted.count)
    }

    /// A chapter as one line: what it holds once done; what waits for the day; how CLOSE will go.
    private func chapterLine(_ chapter: ThreadChapter, shape: FlightChapterShape, blocks: [FlightBlock],
                             thread: FlightThread) -> String {
        let context = wordsContext(for: thread)
        switch shape {
        case .waiting:
            let waiting = blocks.filter { $0.state == .pending }.map(\.kind)
            return L10n.FlightPage.onTheDayFor(FlightPageWords.list(waiting, among: waiting, context))
        case .notYet:
            if thread.flightPlanFiledAt != nil { return L10n.FlightPage.afterLanding + ". " + closeOut(for: thread).rule }
            let kinds = blocks.map(\.kind)
            return L10n.FlightPage.afterLanding + ": " + FlightPageWords.list(kinds, among: kinds, context)
        default:
            return blocks.map { block in
                let title = FlightPageWords.title(block.kind)
                guard block.isAuto, let detail = block.tasks.compactMap(\.detail).first(where: { !$0.isEmpty }) else { return title }
                return "\(title) \(detail)"
            }.joined(separator: " · ")
        }
    }

    /// PREPARE and CLOSE in two columns where the width allows (f3 A): what changes by the hour on the left, the
    /// paperwork on the right; CLOSE's blocks on the left, the debrief on the right.
    @ViewBuilder
    private func blockGrid(_ chapter: ThreadChapter, blocks: [FlightBlock], thread: FlightThread) -> some View {
        let debrief = chapter == .close ? thread.flightId : nil
        if usesTwoColumns && (chapter == .prepare || chapter == .close) {
            let left = chapter == .prepare ? blocks.filter(\.kind.isHourly) : blocks
            let right = chapter == .prepare ? blocks.filter { !$0.kind.isHourly } : []
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 10) {
                    ForEach(left) { blockView($0, thread) }
                }
                .frame(maxWidth: .infinity, alignment: .top)
                VStack(spacing: 10) {
                    ForEach(right) { blockView($0, thread) }
                    if let debrief { debriefCard(debrief) }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        } else {
            VStack(spacing: 10) {
                ForEach(blocks) { blockView($0, thread) }
                if let debrief { debriefCard(debrief) }
            }
        }
    }

    private func debriefCard(_ flightId: UUID) -> some View {
        ThreadDebriefField(flightId: flightId)
            .coachTarget(.debriefField)
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
            .id(Self.debriefId)
    }

    /// A block where it stands (round 2): open while there's something to do, one line once done or set aside, a
    /// dotted line while it waits for the day. A tap opens a line in place.
    @ViewBuilder
    private func blockView(_ block: FlightBlock, _ thread: FlightThread) -> some View {
        let open = unfoldedBlocks.contains(block.kind)
        let title = FlightPageWords.title(block.kind)
        let unfold = { withAnimation(.easeInOut(duration: 0.2)) { _ = unfoldedBlocks.insert(block.kind) } }
        Group {
            if block.state == .pending && block.waitsForDay && !open {
                FlightFoldedLine(look: .waiting, title: title, detail: waitingLine(block, thread), action: unfold)
            } else if block.state != .pending && !open {
                FlightFoldedLine(look: block.state == .done ? .done : .notApplicable, title: title,
                                 detail: FlightPageWords.doneWords(block, wordsContext(for: thread)), action: unfold)
            } else {
                blockCard(block, thread, foldable: true)
            }
        }
        .id(AnyHashable(block.kind))
        .coachTarget(ifAny: Self.rowTarget(block.kind))
        .contextMenu {
            if !block.isAuto && block.state != .notApplicable {
                Button(L10n.Thread.markNotApplicable, systemImage: "minus.circle") {
                    threadManager.setBlockState(.notApplicable, block: block, threadId: thread.id)
                }
            }
        }
    }

    /// A block's card: on the iPad where it stands, on the iPhone in its sheet (`foldable` false: Done closes it).
    private func blockCard(_ block: FlightBlock, _ thread: FlightThread, foldable: Bool) -> some View {
        FlightBlockCard(block: block, title: FlightPageWords.title(block.kind), meta: meta(block, thread),
                        notes: notes(block),
                        onTick: { tick(block, thread) },
                        onFold: foldable && (block.state != .pending || block.waitsForDay)
                            ? { withAnimation(.easeInOut(duration: 0.2)) { _ = unfoldedBlocks.remove(block.kind) } } : nil,
                        tickTarget: Self.tickTarget(block.kind),
                        accessory: { accessory(block, thread) },
                        content: { blockBody(block, thread) })
            // The fuel block opens fuel on board from anywhere on it, as its row did. (on-device review #4)
            .modifier(BlockTap(action: block.kind == .fuel ? { openFuel(thread) } : nil))
    }

    // MARK: - The iPhone's checklist (C)

    /// The iPhone's layout (C, the author's q2 note): a checklist, a row per block in its fixed place, ticked where it
    /// stands; the block in a sheet.
    private var usesChecklist: Bool { horizontalSizeClass == .compact }

    @ViewBuilder
    private func checklistGroup(_ chapter: ThreadChapter, blocks: [FlightBlock], thread: FlightThread) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                if index > 0 { Divider().overlay(Color.white.opacity(0.06)).padding(.leading, 64) }
                blockRow(block, thread)
            }
        }
        .padding(.vertical, 2)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
        if chapter == .close, let flightId = thread.flightId { debriefCard(flightId) }
    }

    private func blockRow(_ block: FlightBlock, _ thread: FlightThread) -> some View {
        FlightBlockRow(block: block, title: FlightPageWords.title(block.kind), subtitle: rowSubtitle(block, thread),
                       meta: rowMeta(block, thread),
                       onTick: block.isAuto ? nil : { tick(block, thread) },
                       onOpen: { openRow(block, thread) },
                       tickTarget: Self.tickTarget(block.kind))
            .id(AnyHashable(block.kind))
            // The reports load from the weather's row, the sheet's being closed: its verdict needs them.
            .task(id: block.kind == .weather ? weatherFields(thread).map(\.ident).joined(separator: " ") : "") {
                guard block.kind == .weather else { return }
                let fields = weatherFields(thread)
                guard !fields.isEmpty else { return }
                await weatherService.load(threadId: thread.id, fields: fields, route: weatherRoute(thread))
            }
            // The dry run rings the row of what its sheet holds while the sheet is closed: the NOTAMs' first link,
            // the logbook line's button. (6.4.0's steps, 6.6.0's layout)
            .coachTarget(ifAny: Self.rowTarget(block.kind)
                         ?? (openBlock == nil && block.kind == .notamsAndAirspace ? .notamLink : nil)
                         ?? (block.kind == .logbook ? .logbookRow : nil))
            .contextMenu {
                if !block.isAuto && block.state != .notApplicable {
                    Button(L10n.Thread.markNotApplicable, systemImage: "minus.circle") {
                        threadManager.setBlockState(.notApplicable, block: block, threadId: thread.id)
                    }
                }
            }
    }

    /// The row's word on the right: while open the iPad head's (a deadline, the countries), the weather's verdict;
    /// once done the time it was; waiting, the day.
    private func rowMeta(_ block: FlightBlock, _ thread: FlightThread) -> FlightBlockMeta? {
        switch block.state {
        case .notApplicable:
            return nil
        case .done:
            if block.isAuto { return nil }
            return block.completedAt.map { FlightBlockMeta(text: shortTime($0)) }
        case .pending:
            if block.waitsForDay { return FlightBlockMeta(text: L10n.FlightPage.onTheDayShort) }
            if block.kind == .weather, case .loaded(let weather)? = weatherService.state(for: thread.id),
               let sigmets = weather.sigmets, sigmets.received > 0 {
                return sigmets.hazards.isEmpty ? FlightBlockMeta(text: L10n.FlightPage.noSigmet, tone: .good)
                                               : FlightBlockMeta(text: L10n.FlightPage.sigmet, tone: .caution)
            }
            return meta(block, thread)
        }
    }

    /// Under the row's title: the auto rows' figures, "for the whole trip", a re-check, a fuel warning.
    private func rowSubtitle(_ block: FlightBlock, _ thread: FlightThread) -> String? {
        var words: [String] = []
        if block.isAuto, let detail = block.tasks.compactMap(\.detail).first(where: { !$0.isEmpty }) { words.append(detail) }
        if block.isShared { words.append(L10n.FlightPage.wholeTrip) }
        if let since = block.recheckSince { words.append(L10n.Flights.recheckForThisLeg(shortTime(since))) }
        if let task = block.task, let warning = fuelWarning(for: task, in: thread) { words.append(warning) }
        return words.isEmpty ? nil : words.joined(separator: " · ")
    }

    /// A row's tap: fuel on board and the logbook line open their own sheets, as their rows always did; the rest
    /// open the block.
    private func openRow(_ block: FlightBlock, _ thread: FlightThread) {
        switch block.kind {
        case .fuel where plan(for: thread) != nil: openFuel(thread)
        case .logbook where thread.flightId != nil: numbersFlightId = thread.flightId
        default: openBlock = OpenBlock(kind: block.kind)
        }
    }

    /// A tool tapped in a block: at once on the iPad, once its sheet has closed on the iPhone.
    private func runTool(_ action: @escaping () -> Void) {
        if openBlock != nil {
            afterBlockSheet = action
            openBlock = nil
        } else {
            action()
        }
    }

    /// Where a dry run's coach rings a block, or its tick. (6.4.0, the rows' then)
    private static func rowTarget(_ kind: FlightBlockKind) -> DryRunCoachStep.Target? {
        switch kind {
        case .fuel: return .fuelRow
        case .flightPlan: return .flightPlanRow
        default: return nil
        }
    }

    private static func tickTarget(_ kind: FlightBlockKind) -> DryRunCoachStep.Target? {
        switch kind {
        case .notamsAndAirspace: return .notamTick
        case .logbook: return .logbookTick
        default: return nil
        }
    }

    private func tick(_ block: FlightBlock, _ thread: FlightThread) {
        guard !block.isAuto else { return }
        threadManager.setBlockState(block.state == .done ? .pending : .done, block: block, threadId: thread.id)
    }

    private func openFuel(_ thread: FlightThread) {
        guard let plan = plan(for: thread) else { return }
        lastFuelPlanId = plan.id
        fuelSheetPlanId = plan.id
    }

    /// Why a block waits: the day, and for the NOTAMs what the DABS says about it ("Tomorrow's DABS is out").
    private func waitingLine(_ block: FlightBlock, _ thread: FlightThread) -> String {
        var words = [L10n.FlightPage.onTheDayOfTheFlight + "."]
        if block.kind == .notamsAndAirspace {
            let b = briefing(for: thread)
            words += b.countries.compactMap { b.dayWords($0) }
        }
        return words.joined(separator: " ")
    }

    /// The head's word on the right: a real deadline in amber, the countries, the times the logbook line carries.
    private func meta(_ block: FlightBlock, _ thread: FlightThread) -> FlightBlockMeta? {
        guard block.state == .pending else { return nil }
        switch block.kind {
        case .notamsAndAirspace:
            let countries = thread.countries ?? []
            return countries.count > 1 ? FlightBlockMeta(text: countries.joined(separator: " · ")) : nil
        case .flightPlan:
            if let by = fileBy(for: thread) { return FlightBlockMeta(text: L10n.FlightPage.fileBy(shortTime(by)), tone: .deadline) }
            return FlightBlockMeta(text: L10n.FlightPage.fileBeforeOffBlock)
        case .border(let country):
            return BorderCrossingGuide.rule(for: country)?.noticeLeadTime.map {
                FlightBlockMeta(text: L10n.FlightPage.notice($0), tone: .deadline)
            }
        case .logbook:
            let flown = flown(thread)
            guard let from = flown.takeoff, let to = flown.landing else { return nil }
            return FlightBlockMeta(text: "\(shortTime(from))–\(shortTime(to))")
        default:
            return nil
        }
    }

    /// Under the title: "for the whole trip", and a trip's briefing to check again for this leg.
    private func notes(_ block: FlightBlock) -> [(String, Color)] {
        var notes: [(String, Color)] = []
        if block.isShared { notes.append((L10n.FlightPage.wholeTrip, .dimText)) }
        if let since = block.recheckSince { notes.append((L10n.Flights.recheckForThisLeg(shortTime(since)), .aviationGold)) }
        return notes
    }

    @ViewBuilder
    private func accessory(_ block: FlightBlock, _ thread: FlightThread) -> some View {
        let fields = block.kind == .weather ? weatherFields(thread) : []
        if !fields.isEmpty {
            PrepareWeatherRefresh(threadId: thread.id, fields: fields, route: weatherRoute(thread))
        }
    }

    @ViewBuilder
    private func blockBody(_ block: FlightBlock, _ thread: FlightThread) -> some View {
        switch block.kind {
        case .weather:
            ThreadWeatherBody(threadId: thread.id, fields: weatherFields(thread), route: weatherRoute(thread),
                              links: briefing(for: thread).weatherLinks(), departure: departure(of: thread)) { openURL($0) }
        case .notamsAndAirspace:
            notamsBody(thread)
        default:
            if let task = block.task {
                VStack(alignment: .leading, spacing: 6) {
                    ThreadTaskDetails(task: task, onOpen: { openURL($0) }, tariffURL: tariffURL(for: task),
                                      chartLink: chartLink(for: task),
                                      touchesSwitzerland: thread.countries?.contains("CH") ?? false,
                                      briefing: briefing(for: thread),
                                      caution: task.key == .flightPlanFiled ? activationLine(for: thread) : nil,
                                      toolLabel: toolLabel(for: task, in: thread),
                                      onOpenTool: { runTool { openTool(for: task, in: thread) } },
                                      warning: fuelWarning(for: task, in: thread))
                    if block.kind == .route { routeTools(thread) }
                }
                .padding(.leading, 68)
                .padding(.trailing, 14)
                .padding(.bottom, 8)
            }
        }
    }

    /// The NOTAMs and every country's airspace activity, a row each, in the route's order (the departure's first);
    /// the DABS in words by day above them. One tick in the head for all of it (round 1 q4 A).
    private func notamsBody(_ thread: FlightThread) -> some View {
        let b = briefing(for: thread)
        var links: [ThreadTaskLink] = []
        var seen = Set<URL>()
        for code in b.countries {
            for category in [BriefingRegistry.Category.notam, .airspace] {
                for var link in b.links(category, in: [code]) where seen.insert(link.url).inserted {
                    link.purpose = category == .notam ? "NOTAM" : L10n.FlightPage.purposeAirspace
                    links.append(link)
                }
            }
        }
        let days = b.countries.compactMap { b.dayWords($0) }
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(days, id: \.self) { line in
                Text(line)
                    .scaledFont(size: 12, relativeTo: .caption)
                    .foregroundColor(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) {
                ForEach(links, id: \.url) { link in
                    ThreadLinkRow(link: link) { openURL(link.url) }
                        .coachTarget(ifAny: link.url == links.first?.url ? .notamLink : nil)
                }
            }
        }
        .padding(.leading, 68)
        .padding(.trailing, 14)
        .padding(.bottom, 8)
    }

    /// Add a stop, or join back with the next leg, in the route's block: they change the route, not the preparation.
    /// Both only before either leg has flown. (v5.1; moved here in 6.6.0)
    @ViewBuilder
    private func routeTools(_ thread: FlightThread) -> some View {
        let canAdd = (thread.state == .planned || thread.state == .ready)
            && FlightCreator.canAddStop(to: thread, plans: flightPlanManager)
        let next = threadManager.leg(after: thread.id)
        let canJoin = thread.flightId == nil && next != nil && next?.flightId == nil
        if canAdd || canJoin {
            HStack(spacing: 8) {
                if canAdd { ThreadToolButton(label: L10n.Trip.addStop) { runTool { addingStop = true } } }
                if canJoin {
                    ThreadToolButton(label: L10n.Trip.joinNextLeg) {
                        runTool { FlightCreator.joinWithNextLeg(thread.id, plans: flightPlanManager, threads: threadManager) }
                    }
                }
            }
        }
    }

    /// FLY's card before and during the flight; after it, one line with the flight's times.
    @ViewBuilder
    private func flyChapter(_ thread: FlightThread) -> some View {
        if thread.state == .closeOut || thread.state == .done {
            let flown = flown(thread)
            let times = flown.takeoff.flatMap { from in flown.landing.map { L10n.FlightPage.flown(shortTime(from), shortTime($0)) } }
            FlightFoldedLine(look: .done, title: L10n.Thread.chapterFly.uppercased(),
                             detail: [times, thread.routeLabel].compactMap { $0 }.joined(separator: " · "), chevron: false) {}
                .allowsHitTesting(false)
        } else {
            flyChapterCard(thread)
        }
    }

    /// The route's aerodromes the weather reports are for: before the flight, for a route the app knows, never in a
    /// dry run (its story has no network and its clock isn't today's). (6.5.0, q1)
    private func weatherFields(_ thread: FlightThread) -> [PrepareWeather.Field] {
        guard dryRunSession == nil, thread.state == .planned || thread.state == .ready, let plan = plan(for: thread)
        else { return [] }
        return PrepareWeather.fields(of: plan, airports: airportDataService)
    }

    private func weatherRoute(_ thread: FlightThread) -> [CLLocationCoordinate2D] {
        plan(for: thread)?.waypoints.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) } ?? []
    }

    /// The flight itself. Not a task list — the 16 phases are the app's core and stay exactly where
    /// they are; this card only marks their place in the thread.
    private func flyChapterCard(_ thread: FlightThread) -> some View {
        VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 12) {
            Image(systemName: "airplane")
                .scaledFont(size: 18, relativeTo: .title3)
                .foregroundColor(.altimeterBlue)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.Thread.chapterFly.uppercased())
                    .scaledFont(size: 11, weight: .bold, design: .monospaced, relativeTo: .caption2)
                    .foregroundColor(.altimeterBlue)
                    .tracking(0.8)
                Text(L10n.Thread.chapterFlyDetail)
                    .scaledFont(size: 12, relativeTo: .caption)
                    .foregroundColor(.dimText)
            }
            Spacer()
        }

        // The chapter said what happens next without offering to do it, which made FLY the one
        // chapter you had to leave the flight to act on. The 16 phases still live where they always
        // did — this only starts them. With another flight running, it says why it can't. (6.2.0)
        switch startOffer(thread) {
        case .none:
            EmptyView()
        case .flightInProgress(let registration):
            FlightInProgressNote(registration: registration)
        case .startEarly:
            if let onStartFlight { earlyStart(thread, onStart: onStartFlight) }
        case .start:
            if let onStartFlight, let country = briefing(for: thread).prohibited.first?.country {
                prohibitedStart(country, title: thread.profile == .local ? L10n.Button.circuits : L10n.Button.startFlight) {
                    onStartFlight(thread.profile == .local)
                }
                .coachTarget(.startFlight)
            } else if let onStartFlight {
                Button {
                    onStartFlight(thread.profile == .local)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: thread.profile == .local
                              ? "arrow.triangle.2.circlepath" : "play.fill")
                            .scaledFont(size: 14, weight: .semibold, relativeTo: .subheadline)
                        Text(thread.profile == .local ? L10n.Button.circuits : L10n.Button.startFlight)
                            .scaledFont(size: 14, weight: .bold, relativeTo: .subheadline)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle(color: thread.profile == .local ? .aviationAmber : .aviationGreen))
                .coachTarget(.startFlight)
            }
        }
        }
        .padding(14)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.altimeterBlue.opacity(0.25), lineWidth: 1)
        )
    }

    /// Today's flight, an undated one, or the next leg from a stop: START FLIGHT, the page's main
    /// button. (Plan › Flights opens next week's flights too.)
    private func isDue(_ thread: FlightThread) -> Bool {
        thread.isDueToday() || threadManager.startableFlightToday?.id == thread.id
    }

    /// What FLY's card offers (`ThreadStartOffer`): with another flight running, a note in place of the
    /// button. (6.2.0)
    private func startOffer(_ thread: FlightThread) -> ThreadStartOffer {
        ThreadStartOffer.make(for: thread, canStart: onStartFlight != nil, isDue: isDue(thread),
                              isFlightActive: appState.isFlightActive, runningFlight: appState.currentFlight)
    }

    /// A flight planned for another day starts from its page too: its day and a quieter button, then a
    /// question, so it isn't started by mistake in place of today's. There was no way to start it
    /// before its day. (round 6)
    private func earlyStart(_ thread: FlightThread, onStart: @escaping (Bool) -> Void) -> some View {
        let when = thread.scheduledDeparture.map(Self.departureText) ?? ""
        return VStack(alignment: .leading, spacing: 8) {
            if !when.isEmpty {
                Text(L10n.Thread.plannedFor(when))
                    .scaledFont(size: 13, relativeTo: .footnote)
                    .foregroundColor(.secondaryText)
            }
            if let country = briefing(for: thread).prohibited.first?.country {
                prohibitedStart(country, title: L10n.Thread.startNow) { confirmingEarlyStart = true }
            } else {
                Button { confirmingEarlyStart = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: thread.profile == .local ? "arrow.triangle.2.circlepath" : "play.fill")
                            .scaledFont(size: 14, weight: .semibold, relativeTo: .subheadline)
                        Text(L10n.Thread.startNow)
                            .scaledFont(size: 14, weight: .bold, relativeTo: .subheadline)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle(color: thread.profile == .local ? .aviationAmber : .aviationGreen,
                                                  isLarge: false))
            }
        }
        .confirmationDialog(L10n.Thread.startEarlyTitle, isPresented: $confirmingEarlyStart,
                            titleVisibility: .visible) {
            Button(L10n.Thread.startNow) { onStart(thread.profile == .local) }
            Button(L10n.Button.cancel, role: .cancel) {}
        } message: {
            if !when.isEmpty { Text(L10n.Thread.startEarlyMessage(when)) }
        }
    }

    /// A route through a country where flights are prohibited (Belarus): its line in red over START, red too, which
    /// starts after a one-second hold, as the cockpit's go-around does (the author's v65-13, 23 Oct 2026). (6.5.0)
    private func prohibitedStart(_ country: String, title: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L10n.Thread.prohibitedTitle(OpenAIPConfig.countryName(for: country)), systemImage: "nosign")
                .scaledFont(size: 13, weight: .semibold, relativeTo: .footnote)
                .foregroundColor(.aviationRed)
            HoldToConfirmButton(title: title, systemImage: "play.fill", tint: .aviationRed, action: action)
        }
    }

    /// "Sat 27 Sep, 10:00", in the pilot's locale.
    private static func departureText(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }

    // MARK: - Open flight plan card

    /// The headline: a filed plan that is still open after landing. Red, unmissable, and carrying the
    /// ways to actually close it: since 6.5.0 by the rule of the country landed in, its numbers to call
    /// (each named, in E.164 so they work from a foreign SIM too), what a field with ATS does, and its
    /// own links (q3).
    private func openFlightPlanCard(_ thread: FlightThread) -> some View {
        let closeOut = closeOut(for: thread)
        let links = ThreadBriefing(registry: briefingRegistry.registry, closeOut: closeOut).closeOutLinks
            .filter { $0.url.scheme != "tel" }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .scaledFont(size: 18, relativeTo: .title3)
                    .foregroundColor(.aviationRed)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.Thread.closeFlightPlanTitle)
                        .scaledFont(size: 15, weight: .bold, relativeTo: .subheadline)
                        .foregroundColor(.primaryText)
                    Text(closeOut.rule)
                        .scaledFont(size: 12, relativeTo: .caption)
                        .foregroundColor(.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    // Landed elsewhere: the alerting counts towards the ETA at the PLANNED destination,
                    // so where the aircraft actually is is the thing to say. (v5.1)
                    if let landed = thread.landedElsewhere {
                        Text(L10n.Trip.tellFICLanded(landed.landedIdent, landed.plannedIdent))
                            .scaledFont(size: 13, weight: .semibold, relativeTo: .footnote)
                            .foregroundColor(.primaryText)
                    } else if let skipped = thread.skippedStop, let arrival = thread.arrivalIdent {
                        // Flown on past the stop the plan was filed to (6.6.0, t3 and t6).
                        Text(L10n.Trip.tellFICLanded(arrival, skipped.ident))
                            .scaledFont(size: 13, weight: .semibold, relativeTo: .footnote)
                            .foregroundColor(.primaryText)
                    }
                }
                Spacer()
            }
            // Peers of equal width: calling and marking the plan closed both answer the same urgent question. One row
            // when every label fits whole, else the calls over MARK CLOSED (f8 A: the German "ALS GESCHLOSSEN MAR…" on
            // an iPhone, 24 Oct 2026); the words are never cut. (device pass; 6.6.0)
            let phones = closeOut.phones.prefix(2).filter { CloseOut.callURL($0) != nil }
            CloseOutButtons(calls: phones.count, call: { index, whole in
                let phone = phones[phones.startIndex + index]
                Button {
                    if let url = CloseOut.callURL(phone) { openURL(url) }
                } label: {
                    VStack(spacing: 1) {
                        CloseOutLabel(text: L10n.CloseOut.call(phone.name), whole: whole)
                        Text(phone.number)
                            .scaledFont(size: 11, design: .monospaced, relativeTo: .caption2)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .opacity(0.85)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle(color: .aviationRed, isLarge: false))
                .accessibilityLabel(L10n.CloseOut.call(phone.name))
                .accessibilityValue(phone.number)
            }, mark: { whole in
                Button {
                    threadManager.markFlightPlanClosed(threadId: thread.id)
                } label: {
                    CloseOutLabel(text: L10n.Thread.markFlightPlanClosed, whole: whole)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle(isLarge: false))
            })
            if let atsLine = closeOut.atsLine {
                Text(atsLine)
                    .scaledFont(size: 12, relativeTo: .caption)
                    .foregroundColor(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Rows, as everywhere on the page (q3). (6.5.0)
            if !links.isEmpty {
                VStack(spacing: 0) {
                    ForEach(links, id: \.url) { link in
                        ThreadLinkRow(link: link) { openURL(link.url) }
                    }
                }
            }
        }
        .padding(14)
        .background(Color.aviationRed.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.aviationRed.opacity(0.6), lineWidth: 1.5)
        )
    }

    // MARK: - Continue after landing elsewhere (v5.1)

    /// "Landed at LSZE — planned LSZQ": offer the rest of the route as the next leg. An offer, never
    /// automatic: the pilot may stay the night, or take the train home.
    @ViewBuilder
    private func continuationCard(_ thread: FlightThread) -> some View {
        if let landed = thread.landedElsewhere, !landed.offerDismissed, !landed.continued {
            LandedElsewhereOffer(
                landed: landed,
                laterLegs: FlightCreator.laterLegs(after: thread.id, threads: threadManager)
                    .map { L10n.Trip.cancelConfirmLeg($0.number, $0.leg.displayName) },
                onContinue: {
                    if let leg = FlightCreator.continueAfterDiversion(from: thread.id, plans: flightPlanManager,
                                                                     threads: threadManager, airports: airportDataService) {
                        onOpenLeg?(leg.id)
                    }
                },
                onFinish: { cancelling in
                    FlightCreator.finishHere(thread.id, cancellingLaterLegs: cancelling, plans: flightPlanManager,
                                             threads: threadManager, logbookPlanIds: logbookPlanIds)
                },
                skip: FlightCreator.skippableLegs(afterLanding: thread.id, threads: threadManager, plans: flightPlanManager)
                    .map { ($0.number, $0.stop) },
                onSkip: {
                    FlightCreator.skipStop(afterLanding: thread.id, plans: flightPlanManager, threads: threadManager,
                                           logbookPlanIds: logbookPlanIds)
                })
        }
        // A skipped leg's plan still filed: the reminder until Done. (6.6.0, t6)
        if let plans = thread.skippedStop?.filedPlanToCancel {
            SkippedPlanReminder(plans: plans) {
                threadManager.recordSkippedStop(thread.skippedStop.map { SkippedStop(ident: $0.ident) }, threadId: thread.id)
            }
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private func footer(_ thread: FlightThread) -> some View {
        VStack(spacing: 10) {
            if thread.state == .closeOut {
                Button(L10n.Thread.finishThread) {
                    threadManager.finishThread(threadId: thread.id)
                    close()
                }
                .buttonStyle(PrimaryButtonStyle(color: .aviationGreen))
                .coachTarget(.finish)
                .frame(maxWidth: .infinity)
            }
            // Asks first: the page, its tasks and the route copied for it go for good, and one tap
            // did it, the only delete on the ground screens without a question. (v6.0 review, B4)
            // A leg of a trip says it is the leg, beside the whole trip's cancel. (6.1.0)
            let inTrip = threadManager.trip(forThreadId: thread.id) != nil
            let legTitle = inTrip ? L10n.Trip.cancelThisLeg : L10n.Thread.deleteThread
            let tripCancel = tripLegsToCancel(thread)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 28) { cancelButtons(thread, legTitle: legTitle, trip: tripCancel) }
                VStack(spacing: 0) { cancelButtons(thread, legTitle: legTitle, trip: tripCancel) }
            }
            .confirmationDialog(L10n.Thread.cancelConfirmTitle, isPresented: $confirmingCancel,
                                titleVisibility: .visible) {
                Button(legTitle, role: .destructive) { cancelFlight(thread) }
                Button(L10n.Thread.keepFlight, role: .cancel) { }
            } message: {
                Text(L10n.Thread.cancelConfirmMessage)
            }
            .background {
                // On a view of its own: two dialogs on one view, and only one of them presents.
                Color.clear
                    .confirmationDialog(L10n.Trip.cancelConfirmTitle, isPresented: $confirmingTripCancel,
                                        titleVisibility: .visible) {
                        if let tripCancel {
                            Button(L10n.Trip.cancelTrip, role: .destructive) { cancelTrip(tripCancel.trip.id, from: thread) }
                        }
                        Button(L10n.Trip.keepTrip, role: .cancel) { }
                    } message: {
                        if let tripCancel { Text(cancelTripMessage(tripCancel.trip)) }
                    }
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func cancelButtons(_ thread: FlightThread, legTitle: String,
                               trip: (trip: Trip, legs: [FlightThread])?) -> some View {
        cancelButton(legTitle) { confirmingCancel = true }
        if let trip {
            cancelButton(L10n.Trip.cancelWholeTrip(legs: trip.legs.count)) { confirmingTripCancel = true }
        }
    }

    private func cancelFlight(_ thread: FlightThread) {
        FlightCreator.cancelLeg(thread.id, plans: flightPlanManager, threads: threadManager,
                                logbookPlanIds: logbookPlanIds)
        close()
    }

    /// Every leg not flown yet, each as `cancelFlight` takes one. The page closes when this leg went
    /// with them; on a leg that flew, it stays, without the legs that are gone. (6.1)
    private func cancelTrip(_ tripId: UUID, from leg: FlightThread) {
        let removed = FlightCreator.cancelTrip(tripId, plans: flightPlanManager, threads: threadManager,
                                               logbookPlanIds: logbookPlanIds, flyingPlanId: flyingPlanId)
        if removed.contains(leg.id) { close() }
    }

    /// The plans the logbook's flights point at: a cancel never deletes one.
    private var logbookPlanIds: Set<UUID> { Set(appState.flights.compactMap(\.flightPlanId)) }

    /// The plan of the flight under way, if any: its leg is never cancelled.
    private var flyingPlanId: UUID? {
        appState.isFlightActive ? appState.currentFlight?.flightPlanId : nil
    }

    // MARK: - Actions

    /// The official chart of a PPR or fee task's aerodrome, when its country publishes one. (6.2.0)
    private func chartLink(for task: ThreadTask) -> OfficialChartLink? {
        guard task.key == .pprObtained || task.key == .feesPaid, let icao = task.subject else { return nil }
        return officialCharts.link(for: icao, type: airportDataService.findAirport(byIdent: icao)?.type)
    }

    /// The briefing tasks' registry and the flight's countries. The route's countries list the departure's first
    /// since 6.5.0; an older thread's alphabetical list is right again at its next regeneration. (6.5.0)
    private func briefing(for thread: FlightThread) -> ThreadBriefing {
        let countries = thread.countries ?? []
        return ThreadBriefing(registry: briefingRegistry.registry, countries: countries,
                              departureCountry: FlightThreadManager.departureCountry(of: plan(for: thread)) ?? countries.first,
                              flightDay: thread.scheduledDeparture,
                              closeOut: thread.flightPlanFiledAt == nil ? nil : closeOut(for: thread))
    }

    /// How this flight's plan is closed, the field's tower known from the app's data. (6.5.0)
    private func closeOut(for thread: FlightThread) -> CloseOut {
        threadManager.closeOut(for: thread) { ident in
            guard airportDataService.findAirport(byIdent: ident) != nil else { return nil }
            return airportDataService.getFrequencies(for: ident).contains { AirportDataService.isContactType($0.type, "TWR") }
        }
    }

    /// "ESKT has no ATS: activate the plan yourself after take-off, by radio or phone.", where the departure's
    /// country asks for it and its field has no tower and no AFIS in the app's data. (6.5.0, q4)
    private func activationLine(for thread: FlightThread) -> String? {
        guard let first = plan(for: thread)?.waypoints.first else { return nil }
        let ident = first.name.trimmingCharacters(in: .whitespaces).uppercased()
        let briefing = briefing(for: thread)
        let known = airportDataService.findAirport(byIdent: ident) != nil
        guard ThreadBriefing.needsActivation(country: briefing.registry?.country(briefing.departureCountry), fieldKnown: known,
                                             frequencyTypes: airportDataService.getFrequencies(for: ident).map(\.type))
        else { return nil }
        return L10n.Thread.activateWithoutATS(ident)
    }

    /// The operator's tariff page for a fee task, when the registry has a verified one.
    private func tariffURL(for task: ThreadTask) -> URL? {
        guard task.key == .feesPaid, let icao = task.subject,
              let tariff = AirfieldTariffService.shared.tariff(for: icao),
              tariff.publishesTariff else { return nil }
        return tariff.destination
    }

    /// The in-app tool a task can open, when there is one. Nil leaves the row as a plain check.
    private func toolLabel(for task: ThreadTask, in thread: FlightThread) -> String? {
        switch task.key {
        case .flightPlanFiled:
            // Only with a real route behind it. skybriefing's form is filled in by hand, so what this
            // saves is retyping the route and identification — not the filing itself.
            guard let plan = plan(for: thread), plan.waypoints.count >= 2 else { return nil }
            return L10n.Nav.copyICAOFlightPlan
        case .massAndBalance:
            return thread.aircraftRegistration?.isEmpty == false ? L10n.WeightBalance.title : nil
        case .routePlanned:
            // The route is the one thing this screen could describe but not open, which left the
            // app's most-used editor unreachable from the flight it belongs to.
            return plan(for: thread) != nil ? L10n.Thread.editRoute : nil
        case .fuelPlanned:
            // Fuel on board, in its own sheet: the number this task is about, with Full tanks. The
            // nav log sheet ("Fuel & times") is a link inside it. (on-device review #4, point 3)
            return plan(for: thread) != nil ? L10n.FuelOnBoard.title : nil
        case .navLogReady:
            // The nav log is the one artefact this task is about, so the task should hand it over
            // rather than send the pilot to the plan editor to find the same export.
            guard let plan = plan(for: thread), plan.waypoints.count >= 2 else { return nil }
            return L10n.Thread.exportNavLog
        case .feesPaid:
            // Only once there is a flight to compute from — before that there are no hours to bill.
            return thread.flightId != nil ? L10n.Cost.title : nil
        case .logbookEntry:
            // Same sheet as the fee task, but labelled for what this row is about: a pilot ticking
            // "logbook entry" is looking for the line, not the cost.
            return thread.flightId != nil ? L10n.Logbook.title : nil
        default:
            return nil
        }
    }

    /// The plan this thread follows, if it still exists. A thread outlives the plan it came from, so
    /// this is deliberately optional rather than force-unwrapped anywhere.
    private func plan(for thread: FlightThread) -> FlightPlan? {
        guard let planId = thread.flightPlanId else { return nil }
        return flightPlanManager.flightPlans.first { $0.id == planId }
    }

    private func openTool(for task: ThreadTask, in thread: FlightThread) {
        switch task.key {
        case .flightPlanFiled:
            guard let plan = plan(for: thread) else { return }
            UIPasteboard.general.string = plan.toICAOFlightPlan()
            copiedFPL = true
        case .massAndBalance:
            weightBalanceRegistration = thread.aircraftRegistration
        case .routePlanned:
            guard let plan = plan(for: thread) else { return }
            routeBuilderPlanId = plan.id
        case .fuelPlanned:
            guard let plan = plan(for: thread) else { return }
            lastFuelPlanId = plan.id
            fuelSheetPlanId = plan.id
        case .navLogReady:
            guard let plan = plan(for: thread) else { return }
            Task {
                let radio = await RouteRadioPlanner.plan(for: plan, openAIP: openAIPDataService,
                                                         airports: airportDataService)
                guard let data = FlightPlanExportService.exportToPDF(plan, radio: radio) else { return }
                let name = "\(thread.routeLabel.replacingOccurrences(of: " ", with: ""))_NavLog.pdf"
                    .replacingOccurrences(of: "/", with: "-")
                navLogPreview = try? StagedExport(data: data, filename: name)
            }
        case .feesPaid, .logbookEntry:
            numbersFlightId = thread.flightId
        default:
            break
        }
    }

    private func toggle(_ task: ThreadTask, in thread: FlightThread) {
        // Auto tasks are computed, not ticked.
        guard task.kind != .auto else { return }
        let newState: ThreadTaskState = (task.state == .done) ? .pending : .done
        threadManager.setTaskState(newState, taskId: task.id, threadId: thread.id)
    }

    private func setState(_ state: ThreadTaskState, _ task: ThreadTask, in thread: FlightThread) {
        threadManager.setTaskState(state, taskId: task.id, threadId: thread.id)
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }
}

// MARK: - Flight in progress (6.2.0)

/// In FLY's card, where START FLIGHT or "Start now" would be while another flight is running: which
/// flight, and what to do. Not a button: that flight ends with END FLIGHT, in the Cockpit, and its
/// sequence (the track times, the logbook line, the ATC flight plan to close) is never run from here.
/// The rest of the page stays open, to read.
private struct FlightInProgressNote: View {
    let registration: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "airplane.circle")
                .scaledFont(size: 18, weight: .semibold, relativeTo: .title3)
                .foregroundColor(.aviationAmber)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(registration.map { L10n.Thread.flightInProgress(aircraft: $0) } ?? L10n.Thread.flightInProgress)
                    .scaledFont(size: 14, weight: .bold, relativeTo: .subheadline)
                    .foregroundColor(.primaryText)
                Text(L10n.Thread.endBeforeStarting)
                    .scaledFont(size: 13, relativeTo: .footnote)
                    .foregroundColor(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.aviationAmber.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.aviationAmber.opacity(0.4), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("thread.flightInProgress")
    }
}

// MARK: - A prohibited country (6.5.0)

/// At the top of Prepare when the route touches a country whose airspace is closed (the registry's `prohibited`:
/// Belarus, EASA SD-2021-02): red, with the directive. Not a task, so nothing to tick and nothing stored; it goes
/// when the route does. Nothing is blocked. (q5)
private struct ProhibitedCountryRow: View {
    let country: String
    let directive: BriefingRegistry.Link
    let onOpen: (URL) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "nosign")
                .scaledFont(size: 18, weight: .semibold, relativeTo: .body)
                .foregroundColor(.aviationRed)
                .frame(width: 44, height: 22, alignment: .leading)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.Thread.prohibitedTitle(OpenAIPConfig.countryName(for: country)))
                    .scaledFont(size: 14, weight: .semibold, relativeTo: .subheadline)
                    .foregroundColor(.aviationRed)
                Text(L10n.Thread.prohibitedHint)
                    .scaledFont(size: 12, relativeTo: .caption)
                    .foregroundColor(.dimText)
                    .fixedSize(horizontal: false, vertical: true)
                // A row, as every link on the page. (6.5.0, q3)
                ThreadLinkRow(link: ThreadTaskLink(label: directive.displayName(), url: directive.url)) {
                    onOpen(directive.url)
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color.aviationRed.opacity(0.08))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("thread.prohibited.\(country)")
    }
}

// MARK: - A block's body

/// What a block of one task shows under its head (6.6.0): the task's detail or hint, a caution, the pilot's note, a
/// warning, then the in-app tool as a gold button and the links as rows. The tick and the title are the block's head;
/// until 6.6.0 this was a row of its own with them (`ThreadTaskRow`).
struct ThreadTaskDetails: View {
    let task: ThreadTask
    let onOpen: (URL) -> Void
    /// Operator tariff page for a fee task, resolved by the parent view. (v5.0.0)
    var tariffURL: URL?
    /// The official chart of a PPR or fee task's aerodrome, resolved by the parent view. (6.2.0)
    var chartLink: OfficialChartLink?
    /// Whether this flight actually touches Switzerland, which gates the Swiss customs link.
    var touchesSwitzerland: Bool = false
    /// The registry and the flight's countries, for the briefing tasks' links and hints. (6.5.0)
    var briefing: ThreadBriefing?
    /// A line in amber under the hint: on Flight plan filed, a plan to activate after take-off. (6.5.0, q4)
    var caution: String?
    /// Label for an in-app tool this task can open (mass & balance, cost & logbook).
    var toolLabel: String?
    var onOpenTool: (() -> Void)?
    /// A caution in amber: fuel on board short of the required fuel. (v6.0 review, B3)
    var warning: String?

    private var presentation: ThreadTaskPresentation { .make(for: task, briefing: briefing) }
    private var links: [ThreadTaskLink] {
        ThreadTaskPresentation.links(for: task, tariffURL: tariffURL, chartLink: chartLink,
                                     touchesSwitzerland: touchesSwitzerland, briefing: briefing)
    }

    /// The border's facts one a line, as the author's round 2 drew them; they were joined by dots.
    private var lines: [String] {
        if let detail = task.detail, !detail.isEmpty { return [detail] }
        guard let hint = presentation.hint else { return [] }
        return task.key == .customsNotified ? hint.components(separatedBy: " · ") : [hint]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .scaledFont(size: 13, design: task.detail?.isEmpty == false ? .monospaced : .default, relativeTo: .footnote)
                    .foregroundColor(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let caution, task.state != .notApplicable {
                Text(caution)
                    .scaledFont(size: 13, relativeTo: .footnote)
                    .foregroundColor(.aviationAmber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note = task.note, !note.isEmpty {
                Text(note)
                    .scaledFont(size: 12, relativeTo: .caption)
                    .foregroundColor(.aviationGold)
            }
            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .scaledFont(size: 13, weight: .semibold, relativeTo: .caption)
                    .foregroundColor(.aviationAmber)
                    .padding(.top, 2)
            }
            if (!links.isEmpty || toolLabel != nil) && task.state != .notApplicable {
                VStack(alignment: .leading, spacing: 4) {
                    if let toolLabel, let onOpenTool {
                        // Gold rather than blue: this one stays inside the app, where the blue rows all leave it.
                        ThreadToolButton(label: toolLabel, action: onOpenTool)
                            // The logbook line's button: the line opens from it (r6-13). (6.4.0)
                            .coachTarget(ifAny: task.key == .logbookEntry ? .logbookRow : nil)
                    }
                    if !links.isEmpty {
                        VStack(spacing: 0) {
                            // By address: two publishers can share a name, never a page. (6.5.0)
                            ForEach(links, id: \.url) { link in
                                ThreadLinkRow(link: link) { onOpen(link.url) }
                            }
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A tap anywhere on a view, for the one block that opens something from all of it (fuel on board); nothing for the
/// others, whose taps stay their buttons'.
struct BlockTap: ViewModifier {
    let action: (() -> Void)?

    func body(content: Content) -> some View {
        if let action {
            content
                .contentShape(Rectangle())
                .onTapGesture { action() }
                .accessibilityAction { action() }
        } else {
            content
        }
    }
}

/// A link that leaves the app, as a row (the author's q3, 22 Oct 2026): the publisher in blue, what the page is for and
/// its country under it, what it takes on the right, an arrow out (a phone for a call). Badges are information; a link is
/// a row, as wide as its column, at least 44 pt tall. (6.5.0)
struct ThreadLinkRow: View {
    let link: ThreadTaskLink
    let action: () -> Void

    private var under: String? {
        let words = [link.purpose, link.country.map { OpenAIPConfig.countryName(for: $0) }].compactMap { $0 }
        return words.isEmpty ? nil : words.joined(separator: " · ")
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(link.label)
                        .scaledFont(size: 14, weight: .semibold, relativeTo: .subheadline)
                        .foregroundColor(.altimeterBlue)
                        .multilineTextAlignment(.leading)
                    if let under {
                        Text(under)
                            .scaledFont(size: 12, relativeTo: .caption)
                            .foregroundColor(.dimText)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 8)
                if let detail = link.detail {
                    Text(detail)
                        .scaledFont(size: 11, design: link.url.scheme == "tel" ? .monospaced : .default, relativeTo: .caption2)
                        .foregroundColor(.secondaryText)
                        .multilineTextAlignment(.trailing)
                }
                Image(systemName: link.url.scheme == "tel" ? "phone.fill" : "arrow.up.right")
                    .scaledFont(size: 12, weight: .semibold, relativeTo: .caption)
                    .foregroundColor(.altimeterBlue)
            }
            .padding(.vertical, 7)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
        }
        .accessibilityLabel([link.label, under, link.detail].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(.isLink)
    }
}

/// An in-app tool a task opens (the fuel on board, mass and balance, the nav log), in gold: it stays in the app. A button,
/// not a chip. (6.5.0, q3)
struct ThreadToolButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .scaledFont(size: 13, weight: .semibold, relativeTo: .footnote)
                .foregroundColor(.aviationGold)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.aviationGold.opacity(0.5), lineWidth: 1))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The debrief, in the CLOSE chapter: a word on what went well and what to change, if the pilot wants one.
/// It is the flight's notes, the logbook's NOTES: written here or there, it is the same text. Optional, so
/// never a task and never counted. (6.4.0, the author's dry run checks, st-18)
struct ThreadDebriefField: View {
    let flightId: UUID
    @Environment(AppState.self) private var appState

    private var flight: Flight? { appState.flights.first { $0.id == flightId } }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "text.bubble")
                .scaledFont(size: 16, relativeTo: .body)
                .foregroundColor(.secondaryText)
                .frame(width: 22)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(L10n.Thread.taskDebrief)
                        .scaledFont(size: 15, weight: .semibold, relativeTo: .subheadline)
                        .foregroundColor(.primaryText)
                    Text(L10n.Thread.debriefOptional)
                        .scaledFont(size: 12, relativeTo: .caption)
                        .foregroundColor(.dimText)
                }
                TextField(L10n.Thread.debriefPlaceholder, text: Binding(
                    get: { flight?.notes ?? "" },
                    set: { notes in if let flight { appState.updateFlightNotes(flight, notes: notes) } }
                ), axis: .vertical)
                    .lineLimit(2...8)
                    .scaledFont(size: 15, relativeTo: .body)
                    .foregroundColor(.primaryText)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.panelBackground))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .opacity(flight == nil ? 0.5 : 1)
        .disabled(flight == nil)
    }
}
