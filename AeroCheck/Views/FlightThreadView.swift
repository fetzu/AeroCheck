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

    /// The chapter whose chip was tapped: the page goes to it.
    @State private var scrollToChapter: ThreadChapter?
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
    /// Chapters whose ticked tasks are unfolded. Folded by default: the page leads with what is left.
    /// (v6.0 · D3)
    @State private var unfoldedDone: Set<ThreadChapter> = []
    /// "Start now" pressed on a flight planned for another day: the question before it starts.
    @State private var confirmingEarlyStart = false
    /// The trip's flown legs, shared as one card from beside the leg strip. (6.1)
    @State private var journeyShare: JourneyShareRequest?
    /// The NEXT card's weather line was tapped: the page goes to the weather block. (6.5.0)
    @State private var scrollToWeather = false

    private var thread: FlightThread? { threadManager.thread(withId: threadId) }

    var body: some View {
        ZStack {
            Color.cockpitBackground.ignoresSafeArea()

            if let thread {
                ScrollViewReader { scroller in
                VStack(spacing: 0) {
                    header(thread)
                    chapterBar(thread)
                        .coachTarget(.chapterBar)
                    Divider().overlay(Color.white.opacity(0.06))
                    ScrollView {
                        VStack(spacing: 16) {
                            // The red card leads, and the NEXT card under it moves on to the task
                            // after: both used to say "close the flight plan", NEXT first, so the
                            // safety headline was the second card on the page.
                            if thread.hasOpenFlightPlanAfterFlight {
                                openFlightPlanCard(thread)
                            }
                            nextTaskCard(thread)
                                .coachTarget(.nextCard)
                            if let trip = threadManager.trip(forThreadId: thread.id) {
                                tripBand(trip, leg: thread)
                            }
                            stopActions(thread)
                            continuationCard(thread)
                            ForEach(ThreadChapter.allCases) { chapter in
                                if chapter == .prepare { weatherBlock(thread) }
                                chapterSection(thread, chapter: chapter)
                                    .id(chapter)
                            }
                            footer(thread)
                                .id(Self.footerId)
                            // A dry run's: room under Finish, so the page can bring it above the coach's card.
                            if dryRunSession != nil {
                                Color.clear.frame(height: DryRunCoachCard.room)
                            }
                        }
                        .padding(20)
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity)
                    }
                }
                // A chapter's chip takes the page to that chapter, its ticked tasks unfolded when nothing in it is
                // open. It used to set a state nothing read: a tap did nothing. (6.4.0)
                // A dry run's coach rings a row lower down the page: the page goes to it first. (6.4.0)
                .onDryRunCoachStep(dryRunSession) { step in
                    guard step.screen == .flightPage, let id = Self.scrollTarget(of: step, in: thread) else { return }
                    withAnimation(.easeInOut(duration: 0.3)) { scroller.scrollTo(id, anchor: UnitPoint(x: 0.5, y: 0.25)) }
                }
                .onChange(of: scrollToWeather) { _, go in
                    guard go else { return }
                    scrollToWeather = false
                    withAnimation(.easeInOut(duration: 0.25)) { scroller.scrollTo(Self.weatherId, anchor: .top) }
                }
                .onChange(of: scrollToChapter) { _, chapter in
                    guard let chapter else { return }
                    scrollToChapter = nil
                    if thread.tasks(in: chapter).allSatisfy({ $0.state != .pending }) { unfoldedDone.insert(chapter) }
                    withAnimation(.easeInOut(duration: 0.25)) { scroller.scrollTo(chapter, anchor: .top) }
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

            if !usesCompactHeader { stateChip(thread) }
            VStack(spacing: 3) {
                readinessRing(thread)
                    .coachTarget(.readiness)
                // The ring in words, where there is room for them: "3 of 4 done". (v6.0 · D3)
                if !usesCompactHeader {
                    Text(readinessCaption(thread))
                        .scaledFont(size: 11, relativeTo: .caption2)
                        .foregroundColor(.secondaryText)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
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

    private func stateChip(_ thread: FlightThread) -> some View {
        let (label, color): (String, Color) = {
            switch thread.state {
            case .planned:  return (L10n.Thread.statePlanned, .aviationGold)
            case .ready:    return (L10n.Thread.stateReady, .aviationGreen)
            case .flying:   return (L10n.Thread.stateFlying, .altimeterBlue)
            case .closeOut: return (L10n.Thread.stateCloseOut, .aviationAmber)
            case .done:     return (L10n.Thread.stateDone, .secondaryText)
            }
        }()
        return Text(label)
            .scaledFont(size: 10, weight: .bold, design: .monospaced, relativeTo: .caption2)
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .overlay(Capsule().strokeBorder(color.opacity(0.55), lineWidth: 1))
    }

    private func readinessCaption(_ thread: FlightThread) -> String {
        if thread.state == .closeOut || thread.state == .done {
            let p = thread.closeOutProgress
            return L10n.Thread.closedProgress(p.done, p.total)
        }
        let p = thread.preFlightProgress
        return L10n.Thread.readiness(p.done, p.total)
    }

    // MARK: - Next task (v6.0 · D3)

    /// The one thing to do next, big and on top, so the page opens on it: the same task Today
    /// advertises as "Next". Fifteen rows of equal weight left the pilot to find it. The list below
    /// still has it, in its chapter. While the red open-plan card is up, that card is the next task
    /// and this one shows the task after it.
    @ViewBuilder
    private func nextTaskCard(_ thread: FlightThread) -> some View {
        if thread.state != .flying {
            if let task = thread.nextTaskBesideOpenFlightPlan {
                VStack(alignment: .leading, spacing: 0) {
                    Text(L10n.Thread.nextUp.uppercased())
                        .scaledFont(size: 12, weight: .bold, design: .monospaced, relativeTo: .caption)
                        .foregroundColor(.aviationGold)
                        .tracking(0.8)
                        .padding(.horizontal, 14)
                        .padding(.top, 12)
                    if task.key.isWeatherBlock {
                        nextWeatherRow(thread)
                    } else {
                        taskRow(task, in: thread, prominent: true)
                    }
                }
                .background(Color.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.aviationGold.opacity(0.6), lineWidth: 1.5)
                )
            } else if thread.state == .planned || thread.state == .ready {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .scaledFont(size: 20, relativeTo: .title3)
                        .foregroundColor(.aviationGreen)
                    Text(L10n.Thread.allDone)
                        .scaledFont(size: 17, weight: .semibold, relativeTo: .headline)
                        .foregroundColor(.primaryText)
                    Spacer(minLength: 0)
                }
                .padding(14)
                .background(Color.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.aviationGreen.opacity(0.5), lineWidth: 1)
                )
            }
        }
    }

    /// NEXT is the weather: its tick (the block's) and a line that takes the page to the block, where the reports and the
    /// links are. The block's tasks in one row, not the first of them alone. (6.5.0, the author's v65-1)
    private func nextWeatherRow(_ thread: FlightThread) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button { threadManager.setWeatherState(.done, threadId: thread.id) } label: {
                Circle()
                    .strokeBorder(Color.dimText, lineWidth: 2)
                    .frame(width: 22, height: 22)
                    .frame(width: 44, height: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.Thread.taskWeather)
            Button { scrollToWeather = true } label: {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.PrepareWeather.title)
                            .scaledFont(size: 20, weight: .semibold, relativeTo: .title3)
                            .foregroundColor(.primaryText)
                        Text(L10n.Thread.weatherBelow)
                            .scaledFont(size: 15, relativeTo: .subheadline)
                            .foregroundColor(.dimText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.down")
                        .scaledFont(size: 14, weight: .semibold, relativeTo: .footnote)
                        .foregroundColor(.aviationGold)
                        .padding(.top, 4)
                }
                .padding(.top, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func taskRow(_ task: ThreadTask, in thread: FlightThread, prominent: Bool = false) -> some View {
        ThreadTaskRow(
            task: task,
            onToggle: { toggle(task, in: thread) },
            onDismissTask: { setState(.notApplicable, task, in: thread) },
            onOpen: { url in openURL(url) },
            tariffURL: tariffURL(for: task),
            chartLink: chartLink(for: task),
            touchesSwitzerland: thread.countries?.contains("CH") ?? false,
            briefing: briefing(for: thread),
            caution: task.key == .flightPlanFiled ? activationLine(for: thread) : nil,
            // v5.0.0: three tasks now open a calculator instead of only taking a tick.
            // The tick still works on its own — the tool is an aid, not a gate.
            toolLabel: toolLabel(for: task, in: thread),
            onOpenTool: { openTool(for: task, in: thread) },
            // The fuel task: a tap anywhere on it sets fuel on board. It can't be ticked (it ticks
            // itself once the tanks hold enough), so the whole row is free to do this.
            // (on-device review #4, point 3)
            onTapRow: task.key == .fuelPlanned && plan(for: thread) != nil
                ? { openTool(for: task, in: thread) } : nil,
            warning: fuelWarning(for: task, in: thread),
            prominent: prominent
        )
        // A dry run's coach rings the row (the fuel plan, the flight plan, the logbook line). (6.4.0)
        .coachTarget(ifAny: prominent ? nil : ThreadTaskRow.rowTarget(task.key))
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

    /// The readiness ring: pre-flight progress before the flight, close-out progress after it.
    private func readinessRing(_ thread: FlightThread) -> some View {
        let progress = (thread.state == .closeOut || thread.state == .done)
            ? thread.closeOutProgress
            : thread.preFlightProgress
        let fraction = progress.total > 0 ? Double(progress.done) / Double(progress.total) : 0
        return ZStack {
            Circle().stroke(Color.white.opacity(0.12), lineWidth: 4)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(fraction >= 1 ? Color.aviationGreen : Color.aviationGold,
                        style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(progress.done)/\(progress.total)")
                .scaledFont(size: 10, weight: .semibold, design: .monospaced, relativeTo: .caption2)
                .foregroundColor(.primaryText)
        }
        .frame(width: 46, height: 46)
        .accessibilityLabel(L10n.Thread.readiness(progress.done, progress.total))
    }

    // MARK: - Trip band (v5.x)

    /// The preparation this leg shares with the rest of the trip.
    ///
    /// Shown on EVERY leg rather than only the first, because a pilot opening leg two should be able
    /// to see that the weather is briefed without going to find leg one — and should be able to tick
    /// what is not. The state lives on the trip, so a tick here is a tick everywhere.
    private func tripBand(_ trip: Trip, leg: FlightThread) -> some View {
        // What THIS leg sees: a briefing that no longer covers its departure reads as pending again.
        let tasks = trip.tasks(forLegDeparting: leg.scheduledDeparture, legId: leg.id)
        let done = tasks.filter { $0.state == .done }.count

        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.Flights.tripProgress(done, tasks.count))
                    .scaledFont(size: 11, weight: .bold, design: .monospaced, relativeTo: .caption2)
                    .foregroundColor(.aviationGold)
                    .tracking(0.8)
                Spacer()
                Button {
                    renameText = trip.name ?? ""
                    renaming = .trip(trip.id)
                } label: {
                    HStack(spacing: 5) {
                        Text(trip.name ?? tripLabel(trip))
                            .scaledFont(size: 11, relativeTo: .caption2)
                            .foregroundColor(trip.name == nil ? .dimText : .secondaryText)
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
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color.panelBackground)

            legStrip(trip, current: leg)
            stopoverLine(leg, in: trip)

            // The weather in its block, beside Prepare; the band counts it all the same. (6.5.0)
            let rows = tasks.filter { !$0.key.isWeatherBlock }
            ForEach(rows) { task in
                let presentation = ThreadTaskPresentation.make(for: task)
                Button {
                    threadManager.setSharedTaskState(task.state == .done ? .pending : .done,
                                                     taskId: task.id,
                                                     tripId: trip.id,
                                                     fromLegId: leg.id)
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: task.state == .done ? "checkmark.circle.fill" : "circle")
                            .scaledFont(size: 18, relativeTo: .body)
                            .foregroundColor(task.state == .done ? .aviationGreen : .dimText)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(presentation.title)
                                .scaledFont(size: 14, weight: .semibold, relativeTo: .subheadline)
                                .foregroundColor(.primaryText)
                            // A refreshed-briefing prompt says WHEN it was last done, so it reads as
                            // a re-check rather than something the pilot forgot entirely.
                            if task.state == .pending, let last = task.completedAt {
                                Text(L10n.Flights.recheckForThisLeg(shortTime(last)))
                                    .scaledFont(size: 12, design: .monospaced, relativeTo: .caption)
                                    .foregroundColor(.aviationGold)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if task.id != rows.last?.id {
                    Divider().overlay(Color.white.opacity(0.06)).padding(.leading, 46)
                }
            }
        }
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.aviationGold.opacity(0.3), lineWidth: 1)
        )
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

    /// Add a stop to this flight, or join it back with the next leg — both only before either has
    /// flown. (v5.1)
    @ViewBuilder
    private func stopActions(_ thread: FlightThread) -> some View {
        let canAdd = (thread.state == .planned || thread.state == .ready)
            && FlightCreator.canAddStop(to: thread, plans: flightPlanManager)
        let next = threadManager.leg(after: thread.id)
        let canJoin = thread.flightId == nil && next != nil && next?.flightId == nil
        if canAdd || canJoin {
            HStack(spacing: 10) {
                if canAdd {
                    Button { addingStop = true } label: {
                        Label(L10n.Trip.addStop, systemImage: "mappin.and.ellipse")
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SecondaryButtonStyle(isLarge: false))
                }
                if canJoin {
                    Button {
                        FlightCreator.joinWithNextLeg(thread.id, plans: flightPlanManager, threads: threadManager)
                    } label: {
                        Label(L10n.Trip.joinNextLeg, systemImage: "arrow.triangle.merge")
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SecondaryButtonStyle(isLarge: false))
                }
            }
        }
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

    // MARK: - Chapter bar

    /// The state chip and the four chapters, all in view: on one row where they fit, else the state
    /// chip over the chapters, else the chapters two by two. On an iPhone the single scrolling row cut
    /// Close off at the edge with nothing to say there was more, and in French even the four
    /// chapters alone are wider than the screen. Scrolling stays as the last resort, for the largest
    /// text sizes. (v6.0 review)
    private func chapterBar(_ thread: FlightThread) -> some View {
        let chapters = Array(ThreadChapter.allCases)
        return ViewThatFits(in: .horizontal) {
            chapterRow(thread, chapters: chapters, withState: true)
            VStack(alignment: .leading, spacing: 8) {
                if usesCompactHeader { stateChip(thread) }
                chapterRow(thread, chapters: chapters, withState: false)
            }
            VStack(alignment: .leading, spacing: 8) {
                if usesCompactHeader { stateChip(thread) }
                chapterRow(thread, chapters: Array(chapters.prefix(2)), withState: false)
                chapterRow(thread, chapters: Array(chapters.dropFirst(2)), withState: false)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                chapterRow(thread, chapters: chapters, withState: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cockpitBackground)
    }

    private func chapterRow(_ thread: FlightThread, chapters: [ThreadChapter], withState: Bool) -> some View {
        HStack(spacing: 8) {
            // Displaced from the header on iPhone, where it was costing the route label the
            // width it needed. It belongs with the per-chapter progress anyway: same question,
            // one level up — and it leads, so it is on screen without scrolling the bar.
            // (device pass)
            if withState && usesCompactHeader { stateChip(thread) }
            ForEach(chapters) { chapter in
                chapterChip(thread, chapter: chapter)
            }
        }
    }

    private func chapterChip(_ thread: FlightThread, chapter: ThreadChapter) -> some View {
        let tasks = thread.tasks(in: chapter)
        let done = tasks.filter { $0.state == .done }.count
        let relevant = tasks.filter { $0.state != .notApplicable }.count
        let isComplete = relevant > 0 && done >= relevant
        // FLY used to be blue, which read as "different kind of thing" when what a pilot wants to
        // know is the same question as every other chapter: is it done? Gold until the flight has
        // been recorded, green once it has — and it is the flight that feeds CLOSE, so its state is
        // exactly what says whether the logbook line and the cost can be filled in yet.
        //
        // Read from the STATE, not from `flightId`. Since a flight links itself at start, a flightId
        // means "a flight began", not "a flight happened" — so this went green the moment the engine
        // did, and stayed green after an abandoned flight. (device pass)
        let flown = thread.state == .closeOut || thread.state == .done
        let color: Color = chapter == .fly
            ? (flown ? .aviationGreen : .aviationGold)
            : (isComplete ? .aviationGreen : .aviationGold)

        return Button {
            scrollToChapter = chapter
        } label: {
            HStack(spacing: 6) {
                Text(chapterName(chapter))
                    .scaledFont(size: 11, weight: .bold, design: .monospaced, relativeTo: .caption2)
                if chapter != .fly, relevant > 0 {
                    Text("\(done)/\(relevant)")
                        .scaledFont(size: 11, design: .monospaced, relativeTo: .caption2)
                        .foregroundColor(.dimText)
                }
            }
            .foregroundColor(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .overlay(Capsule().strokeBorder(color.opacity(0.5), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private static let footerId = "footer"
    private static let debriefId = "debrief"
    private static let weatherId = "weather"

    /// Where the page goes for a dry run's step: the row its ring is on, the Fly chapter's START FLIGHT, the
    /// footer's Finish. (6.4.0)
    private static func scrollTarget(of step: DryRunCoachStep, in thread: FlightThread) -> AnyHashable? {
        func row(_ key: ThreadTaskKey) -> AnyHashable? { thread.tasks.first { $0.key == key }.map { AnyHashable($0.id) } }
        switch step.target {
        case .fuelRow?: return row(.fuelPlanned)
        case .notamLink?, .notamTick?: return row(.notamChecked)
        case .flightPlanRow?: return row(.flightPlanFiled)
        case .logbookRow?, .logbookTick?: return row(.logbookEntry)
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

    // MARK: - Chapter section

    @ViewBuilder
    private func chapterSection(_ thread: FlightThread, chapter: ThreadChapter) -> some View {
        // The weather and the area forecasts are the weather block's, above the chapter. (6.5.0)
        let tasks = thread.tasks(in: chapter).filter { !$0.key.isWeatherBlock }
        if chapter == .fly {
            flyChapterCard(thread)
        } else if !tasks.isEmpty || (chapter == .close && thread.flightId != nil) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(chapterName(chapter).uppercased())
                        .scaledFont(size: 11, weight: .bold, design: .monospaced, relativeTo: .caption2)
                        .foregroundColor(.aviationGold)
                        .tracking(0.8)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color.panelBackground)

                if chapter == .prepare {
                    ForEach(briefing(for: thread).prohibited, id: \.country) { prohibited in
                        ProhibitedCountryRow(country: prohibited.country, directive: prohibited.directive) { openURL($0) }
                        Divider().overlay(Color.white.opacity(0.06)).padding(.leading, 46)
                    }
                }

                // What is left first; the ticked (and not-applicable) ones fold into one row, so a
                // chapter reads as its open work. (v6.0 · D3)
                let open = tasks.filter { $0.state == .pending }
                let closed = tasks.filter { $0.state != .pending }
                ForEach(open) { task in
                    taskRow(task, in: thread)
                        .id(task.id)
                    if task.id != open.last?.id || !closed.isEmpty {
                        Divider().overlay(Color.white.opacity(0.06)).padding(.leading, 46)
                    }
                }
                if !closed.isEmpty {
                    let unfolded = unfoldedDone.contains(chapter)
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if unfolded { unfoldedDone.remove(chapter) } else { unfoldedDone.insert(chapter) }
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.circle.fill")
                                .scaledFont(size: 18, relativeTo: .body)
                                .foregroundColor(.aviationGreen)
                            Text(L10n.Thread.doneCount(closed.count))
                                .scaledFont(size: 14, weight: .semibold, relativeTo: .subheadline)
                                .foregroundColor(.secondaryText)
                            Spacer(minLength: 0)
                            Image(systemName: unfolded ? "chevron.up" : "chevron.down")
                                .scaledFont(size: 13, weight: .semibold, relativeTo: .footnote)
                                .foregroundColor(.dimText)
                        }
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if unfolded {
                        ForEach(closed) { task in
                            Divider().overlay(Color.white.opacity(0.06)).padding(.leading, 46)
                            taskRow(task, in: thread)
                        }
                    }
                }
                // The debrief: the flight's notes, optional, never counted. (6.4.0, the author's st-18)
                if chapter == .close, let flightId = thread.flightId {
                    if !tasks.isEmpty { Divider().overlay(Color.white.opacity(0.06)).padding(.leading, 46) }
                    ThreadDebriefField(flightId: flightId)
                        .coachTarget(.debriefField)
                        .id(Self.debriefId)
                }
            }
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
            )
        }
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
            if let onStartFlight {
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
            .confirmationDialog(L10n.Thread.startEarlyTitle, isPresented: $confirmingEarlyStart,
                                titleVisibility: .visible) {
                Button(L10n.Thread.startNow) { onStart(thread.profile == .local) }
                Button(L10n.Button.cancel, role: .cancel) {}
            } message: {
                if !when.isEmpty { Text(L10n.Thread.startEarlyMessage(when)) }
            }
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
                    }
                }
                Spacer()
            }
            // Equal width, deliberately. These are peers — calling and marking the plan closed are
            // both complete answers to the same urgent question — so none should be typographically
            // louder than the other. The sizes used to be driven entirely by label length plus two
            // styles that disagreed on padding. (device pass)
            HStack(spacing: 8) {
                ForEach(closeOut.phones.prefix(2), id: \.number) { phone in
                    if let url = CloseOut.callURL(phone) {
                        Button {
                            openURL(url)
                        } label: {
                            VStack(spacing: 1) {
                                Text(L10n.CloseOut.call(phone.name))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.5)
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
                    }
                }
                Button {
                    threadManager.markFlightPlanClosed(threadId: thread.id)
                } label: {
                    Text(L10n.Thread.markFlightPlanClosed)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle(isLarge: false))
            }
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
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                        .scaledFont(size: 18, relativeTo: .title3)
                        .foregroundColor(.aviationGold)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.Trip.landedAt(landed.landedIdent))
                            .scaledFont(size: 15, weight: .bold, relativeTo: .subheadline)
                            .foregroundColor(.primaryText)
                        Text("\(landed.landedName) · \(L10n.Trip.planned(landed.plannedIdent))")
                            .scaledFont(size: 12, relativeTo: .caption)
                            .foregroundColor(.secondaryText)
                    }
                    Spacer()
                }
                Text(L10n.Trip.continueExplainer(landed.landedIdent, landed.plannedIdent))
                    .scaledFont(size: 12, relativeTo: .caption)
                    .foregroundColor(.dimText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button {
                        if let leg = FlightCreator.continueAfterDiversion(from: thread.id, plans: flightPlanManager,
                                                                         threads: threadManager,
                                                                         airports: airportDataService) {
                            onOpenLeg?(leg.id)
                        }
                    } label: {
                        Text(L10n.Trip.continueTo(landed.plannedIdent))
                            .lineLimit(1).minimumScaleFactor(0.6)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryButtonStyle(isLarge: false))
                    Button {
                        threadManager.dismissContinuation(threadId: thread.id)
                    } label: {
                        Text(L10n.Trip.finishHere)
                            .lineLimit(1).minimumScaleFactor(0.6)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SecondaryButtonStyle(isLarge: false))
                }
            }
            .padding(14)
            .background(Color.aviationGold.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.aviationGold.opacity(0.5), lineWidth: 1)
            )
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

    /// Prepare's weather as one block above its tasks (the author's v65-1): "Weather briefed" and the area forecasts,
    /// the flight's or, on a trip's leg, its trip's as this leg sees them; the reports before the flight, for a route
    /// with an aerodrome the app knows (q1), never in a dry run (its story has no network and its clock isn't today's);
    /// each country's pages. After the flight it opens folded. (6.5.0)
    @ViewBuilder
    private func weatherBlock(_ thread: FlightThread) -> some View {
        let trip = threadManager.trip(forThreadId: thread.id)
        let tasks = (trip?.tasks(forLegDeparting: thread.scheduledDeparture, legId: thread.id) ?? thread.tasks)
            .filter { $0.key.isWeatherBlock }
        if !tasks.isEmpty {
            let before = thread.state == .planned || thread.state == .ready
            let plan = plan(for: thread)
            let fields = dryRunSession == nil && before ? plan.map { PrepareWeather.fields(of: $0, airports: airportDataService) } ?? [] : []
            ThreadWeatherBlock(
                threadId: thread.id,
                tasks: tasks,
                fields: fields,
                route: plan?.waypoints.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) } ?? [],
                links: briefing(for: thread).weatherLinks(),
                startsFolded: !before,
                // A briefing ticked for an earlier leg that doesn't cover this one: when it was. (v5.x)
                recheck: trip == nil ? nil : tasks.filter { $0.state == .pending }.compactMap(\.completedAt).max(),
                onTick: { threadManager.setWeatherState($0, threadId: thread.id) },
                onOpen: { openURL($0) }
            )
            .id(Self.weatherId)
        }
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

// MARK: - Task row

/// One task. The tick is the whole point: same gesture, same feedback as a checklist item, applied to
/// admin work instead of an aircraft procedure.
struct ThreadTaskRow: View {
    /// Where a dry run's coach rings a task's row, or its tick. (6.4.0)
    static func rowTarget(_ key: ThreadTaskKey) -> DryRunCoachStep.Target? {
        switch key {
        case .fuelPlanned: return .fuelRow
        case .flightPlanFiled: return .flightPlanRow
        default: return nil
        }
    }

    static func tickTarget(_ key: ThreadTaskKey) -> DryRunCoachStep.Target? {
        switch key {
        case .notamChecked: return .notamTick
        case .logbookEntry: return .logbookTick
        default: return nil
        }
    }

    let task: ThreadTask
    let onToggle: () -> Void
    let onDismissTask: () -> Void
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
    /// Label for an in-app tool this task can open (mass & balance, cost & logbook). Nil for a task
    /// that is only ever a tick.
    var toolLabel: String?
    var onOpenTool: (() -> Void)?
    /// A tap anywhere on the row, for a task the row itself opens (fuel on board). Nil: the row
    /// only has its tick and chips. (on-device review #4, point 3)
    var onTapRow: (() -> Void)?
    /// A caution under the task, in amber: fuel on board short of the required fuel. (v6.0 review, B3)
    var warning: String?
    /// The flight page's "Next" card: the title and hint read larger. (v6.0 · D3)
    var prominent: Bool = false

    private var presentation: ThreadTaskPresentation { .make(for: task, briefing: briefing) }
    private var links: [ThreadTaskLink] {
        ThreadTaskPresentation.links(for: task, tariffURL: tariffURL, chartLink: chartLink,
                                     touchesSwitzerland: touchesSwitzerland, briefing: briefing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                tickButton
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(presentation.title)
                            .scaledFont(size: prominent ? 20 : 14, weight: .semibold,
                                        relativeTo: prominent ? .title3 : .subheadline)
                            .foregroundColor(task.state == .notApplicable ? .dimText : .primaryText)
                            .strikethrough(task.state == .notApplicable)
                        if task.kind == .auto {
                            Text(L10n.ThreadBadge.auto)
                                .scaledFont(size: 9, weight: .bold, design: .monospaced, relativeTo: .caption2)
                                .foregroundColor(.aviationGreen)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .overlay(Capsule().strokeBorder(Color.aviationGreen.opacity(0.5), lineWidth: 1))
                        }
                    }
                    if let detail = task.detail, !detail.isEmpty {
                        Text(detail)
                            .scaledFont(size: 12, design: .monospaced, relativeTo: .caption)
                            .foregroundColor(.secondaryText)
                    } else if let hint = presentation.hint {
                        Text(hint)
                            .scaledFont(size: prominent ? 15 : 12, relativeTo: prominent ? .subheadline : .caption)
                            .foregroundColor(.dimText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let caution, task.state != .notApplicable {
                        Text(caution)
                            .scaledFont(size: prominent ? 15 : 12, relativeTo: prominent ? .subheadline : .caption)
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
                            .scaledFont(size: prominent ? 16 : 13, weight: .semibold,
                                        relativeTo: prominent ? .subheadline : .caption)
                            .foregroundColor(.aviationAmber)
                            .padding(.top, 2)
                    }
                    // Inside the text column, not a sibling of it. These used to hang off the outer
                    // stack with a hand-tuned `.leading` padding that did not match the tick button's
                    // real width, so every chip sat a few points LEFT of the title it belonged to.
                    // Nesting them makes the alignment structural instead of a guess.
                    if (!links.isEmpty || toolLabel != nil) && task.state != .notApplicable {
                        actions
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: presentation.icon)
                    .scaledFont(size: 14, relativeTo: .footnote)
                    .foregroundColor(warning == nil ? .dimText.opacity(0.6) : .aviationAmber)
            }

        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .contextMenu {
            if task.kind != .auto {
                Button(L10n.Thread.markNotApplicable, systemImage: "minus.circle") { onDismissTask() }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(presentation.title)
        .accessibilityValue([task.state == .done ? L10n.Thread.markDone : nil, warning]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(task.kind == .auto && onTapRow == nil ? [] : .isButton)
        .modifier(RowTap(action: onTapRow))
    }

    /// A row the whole of which opens something: a tap anywhere but on its chips (buttons keep their
    /// own taps), and VoiceOver's activate. Rows without it are left exactly as they were: their
    /// activate still ticks.
    private struct RowTap: ViewModifier {
        let action: (() -> Void)?

        func body(content: Content) -> some View {
            if let action {
                content
                    .onTapGesture { action() }
                    .accessibilityAction { action() }
            } else {
                content
            }
        }
    }

    /// The row's actions: the in-app tool as a gold button, then the links as rows, one under the other (the author's q3,
    /// 22 Oct 2026). Until 6.5.0 they were chips of two sizes, read as badges. (6.5.0)
    private var actions: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let toolLabel, let onOpenTool {
                // Gold rather than blue: this one stays inside the app, where the blue rows all leave it.
                ThreadToolButton(label: toolLabel, action: onOpenTool)
                    // The logbook line's button, not its row: the line opens from it (r6-13). (6.4.0)
                    .coachTarget(ifAny: !prominent && task.key == .logbookEntry ? .logbookRow : nil)
            }
            if !links.isEmpty {
                VStack(spacing: 0) {
                    // By address: two publishers can share a name, never a page. (6.5.0)
                    ForEach(links, id: \.url) { link in
                        ThreadLinkRow(link: link) { onOpen(link.url) }
                            .coachTarget(ifAny: !prominent && task.key == .notamChecked && link.url == links.first?.url
                                         ? .notamLink : nil)
                    }
                }
            }
        }
        .padding(.top, 2)
    }

    private var tickButton: some View {
        Button(action: onToggle) {
            ZStack {
                Circle()
                    .strokeBorder(tickColor, style: StrokeStyle(lineWidth: 2, dash: task.kind == .auto ? [3, 2] : []))
                    .frame(width: 22, height: 22)
                if task.state == .done {
                    Circle().fill(tickColor).frame(width: 22, height: 22)
                    Image(systemName: "checkmark")
                        .scaledFont(size: 11, weight: .bold, relativeTo: .caption2)
                        .foregroundColor(.cockpitBackground)
                } else if task.state == .notApplicable {
                    Image(systemName: "minus")
                        .scaledFont(size: 11, weight: .bold, relativeTo: .caption2)
                        .foregroundColor(.dimText)
                }
            }
            .frame(width: 44, height: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(task.kind == .auto)
        .coachTarget(ifAny: prominent ? nil : Self.tickTarget(task.key))
    }

    private var tickColor: Color {
        switch task.state {
        case .done:          return .aviationGreen
        case .notApplicable: return .dimText.opacity(0.5)
        case .pending:       return task.isUrgent ? .aviationRed : .dimText
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
