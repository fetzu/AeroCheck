import SwiftUI

// MARK: - Task presentation
//
// Copy, icons and links for a task key. Kept out of the model on purpose: a persisted thread stores
// only the key, so switching the app to French re-renders an old thread correctly and the wording can
// change without a data migration.

struct ThreadTaskPresentation {
    let title: String
    let hint: String?
    let icon: String

    static func make(for task: ThreadTask) -> ThreadTaskPresentation {
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
            return .init(title: L10n.Thread.taskDabs, hint: L10n.Thread.hintDabs, icon: "doc.text")
        case .gaforChecked:
            return .init(title: L10n.Thread.taskGafor, hint: L10n.Thread.hintGafor, icon: "map")
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
                return parts.joined(separator: " · ")
            }()
            return .init(title: L10n.Thread.taskCustoms(task.subject ?? ""), hint: hint, icon: "globe.europe.africa")
        case .flightPlanClosed:
            return .init(title: L10n.Thread.taskFlightPlanClose, hint: L10n.Thread.hintFlightPlanClose, icon: "checkmark.shield")
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
    static func links(for task: ThreadTask,
                      tariffURL: URL? = nil,
                      touchesSwitzerland: Bool = false) -> [(label: String, url: URL)] {
        switch task.key {
        case .flightPlanFiled:
            return [(L10n.Thread.openSkybriefing,
                     URL(string: "https://www.skybriefing.com/services/flightplan-services")!)]
        case .notamChecked:
            // Was a bare tick with nowhere to go, which is the one task state that teaches a pilot to
            // tick without doing. skybriefing is the Swiss briefing channel, same as for filing.
            return [(L10n.Thread.openNotamBriefing,
                     URL(string: "https://www.skybriefing.com/services/notam-briefing")!)]
        case .dabsChecked:
            return [(L10n.Thread.openDabs, URL(string: "https://www.skybriefing.com/dabs")!)]
        case .gaforChecked:
            return [(L10n.Thread.openMeteoSwiss,
                     URL(string: "https://www.meteoswiss.admin.ch/services-and-publications/service/weather-and-climate-products/aviation-weather.html")!)]
        case .flightPlanClosed:
            // Skyguide's free flight-plan closing number. A `tel:` link is the whole feature here.
            return [(L10n.Thread.callFIC, URL(string: "tel://0800437837")!)]
        case .feesPaid:
            // The operator's OWN tariff page, from the server registry. Absent for an aerodrome
            // nobody has verified yet, which is the honest state rather than a guessed link.
            guard let tariffURL else { return [] }
            return [(L10n.Cost.openTariff, tariffURL)]
        case .customsNotified:
            // The authority's own page, in its own language, is the source — the app only points at
            // it. The Swiss side applies whichever country is at the other end, but only when the
            // flight actually touches Switzerland.
            var links: [(label: String, url: URL)] = []
            if let country = task.subject, let rule = BorderCrossingGuide.rule(for: country) {
                links.append((L10n.Border.openOfficial, rule.officialURL))
            }
            if touchesSwitzerland {
                links.append((L10n.Border.swissSide, BorderCrossingGuide.switzerland.officialURL))
            }
            return links
        default:
            return []
        }
    }
}

// MARK: - Flight Thread screen

/// One followed flight, chapter by chapter. The FLY chapter is shown but not interactive — it is the
/// existing 16-phase flight, and this screen deliberately does not try to own it.
struct FlightThreadView: View {
    let threadId: UUID
    var onClose: (() -> Void)?
    /// Supplied by whoever presents this screen, because starting a flight runs `FlightLauncher`'s
    /// whole guard sequence and that belongs to the presenter, not here. `Bool` is circuit mode.
    var onStartFlight: ((Bool) -> Void)?

    @EnvironmentObject var threadManager: FlightThreadManager
    @EnvironmentObject var flightPlanManager: FlightPlanManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var expandedChapter: ThreadChapter?
    /// Registration whose mass & balance is open, from the PLAN task. (v5.0.0)
    @State private var weightBalanceRegistration: String?
    /// Flight whose cost and logbook line are open, from the CLOSE tasks. (v5.0.0)
    @State private var numbersFlightId: UUID?
    /// Confirmation for the ICAO flight-plan copy, which is otherwise invisible. (v5.0.0)
    @State private var copiedFPL = false
    /// The nav log rendered for sharing, held until its share sheet is up. (v5.0.0)
    @State private var navLogExport: Data?
    /// Plan open in the map builder, from the route task. (v5.0.0)
    @State private var routeBuilderPlanId: UUID?
    /// Plan open in the details editor, from the fuel task. (v5.0.0)
    @State private var planEditorPlan: FlightPlan?

    private var thread: FlightThread? { threadManager.thread(withId: threadId) }

    var body: some View {
        ZStack {
            Color.cockpitBackground.ignoresSafeArea()

            if let thread {
                VStack(spacing: 0) {
                    header(thread)
                    chapterBar(thread)
                    Divider().overlay(Color.white.opacity(0.06))
                    ScrollView {
                        VStack(spacing: 16) {
                            if thread.hasOpenFlightPlan && thread.state == .closeOut {
                                openFlightPlanCard(thread)
                            }
                            ForEach(ThreadChapter.allCases) { chapter in
                                chapterSection(thread, chapter: chapter)
                            }
                            footer(thread)
                        }
                        .padding(20)
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity)
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
            }
        }
        .sheet(isPresented: Binding(
            get: { navLogExport != nil },
            set: { if !$0 { navLogExport = nil } }
        )) {
            if let data = navLogExport, let thread {
                ShareSheet(activityItems: [
                    ShareFile(data: data,
                              filename: "\(thread.routeLabel.replacingOccurrences(of: " ", with: ""))_NavLog.pdf",
                              dataTypeIdentifier: "com.adobe.pdf")
                ])
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { routeBuilderPlanId != nil },
            set: { if !$0 { routeBuilderPlanId = nil } }
        )) {
            if let id = routeBuilderPlanId {
                FlightPlanMapBuilderView(planId: id)
            }
        }
        .sheet(item: $planEditorPlan) { plan in
            FlightPlanEditorView(flightPlan: plan)
        }
        .copiedConfirmation(L10n.Nav.icaoFlightPlanCopied, isPresented: $copiedFPL)
        // Warm the tariff registry so the fee task can offer the operator's page. Cached for a week
        // and silent on failure — a missing link is a missing convenience, never an error.
        .task { await AirfieldTariffService.shared.refreshIfNeeded() }
    }

    // MARK: - Header

    private func header(_ thread: FlightThread) -> some View {
        HStack(spacing: 14) {
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
                        .frame(width: 68, height: 46)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.Thread.editRoute)
                .accessibilityHint(thread.routeLabel)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(thread.routeLabel)
                    .scaledFont(size: 19, weight: .semibold, design: .monospaced, relativeTo: .title3)
                    .foregroundColor(.primaryText)
                    .lineLimit(1)
                Text(subtitle(thread))
                    .scaledFont(size: 12, relativeTo: .caption)
                    .foregroundColor(.dimText)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            stateChip(thread)
            readinessRing(thread)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.panelBackground)
    }

    private func subtitle(_ thread: FlightThread) -> String {
        var parts: [String] = []
        if let departure = thread.scheduledDeparture {
            parts.append(departure.formatted(date: .abbreviated, time: .shortened))
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

    // MARK: - Chapter bar

    private func chapterBar(_ thread: FlightThread) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ThreadChapter.allCases) { chapter in
                    chapterChip(thread, chapter: chapter)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Color.cockpitBackground)
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
        let flown = thread.flightId != nil
        let color: Color = chapter == .fly
            ? (flown ? .aviationGreen : .aviationGold)
            : (isComplete ? .aviationGreen : .aviationGold)

        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                expandedChapter = (expandedChapter == chapter) ? nil : chapter
            }
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
        let tasks = thread.tasks(in: chapter)
        if chapter == .fly {
            flyChapterCard(thread)
        } else if !tasks.isEmpty {
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

                ForEach(tasks) { task in
                    ThreadTaskRow(
                        task: task,
                        onToggle: { toggle(task, in: thread) },
                        onDismissTask: { setState(.notApplicable, task, in: thread) },
                        onOpen: { url in openURL(url) },
                        tariffURL: tariffURL(for: task),
                        touchesSwitzerland: thread.countries?.contains("CH") ?? false,
                        // v5.0.0: three tasks now open a calculator instead of only taking a tick.
                        // The tick still works on its own — the tool is an aid, not a gate.
                        toolLabel: toolLabel(for: task, in: thread),
                        onOpenTool: { openTool(for: task, in: thread) }
                    )
                    if task.id != tasks.last?.id {
                        Divider().overlay(Color.white.opacity(0.06)).padding(.leading, 46)
                    }
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
        // did — this only starts them.
        if let onStartFlight, thread.flightId == nil {
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

    // MARK: - Open flight plan card

    /// The headline: a filed plan that is still open after landing. Red, unmissable, and carrying the
    /// two ways to actually close it.
    private func openFlightPlanCard(_ thread: FlightThread) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .scaledFont(size: 18, relativeTo: .title3)
                    .foregroundColor(.aviationRed)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.Thread.closeFlightPlanTitle)
                        .scaledFont(size: 15, weight: .bold, relativeTo: .subheadline)
                        .foregroundColor(.primaryText)
                    Text(L10n.Thread.hintFlightPlanClose)
                        .scaledFont(size: 12, relativeTo: .caption)
                        .foregroundColor(.secondaryText)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                if let url = URL(string: "tel://0800437837") {
                    Button(L10n.Thread.callFIC) { openURL(url) }
                        .buttonStyle(PrimaryButtonStyle(color: .aviationRed))
                }
                Button(L10n.Thread.markFlightPlanClosed) {
                    threadManager.markFlightPlanClosed(threadId: thread.id)
                }
                .buttonStyle(SecondaryButtonStyle())
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
                .frame(maxWidth: .infinity)
            }
            Button(role: .destructive) {
                threadManager.deleteThread(threadId: thread.id)
                close()
            } label: {
                Text(L10n.Thread.deleteThread)
                    .scaledFont(size: 13, relativeTo: .footnote)
                    .foregroundColor(.aviationRed.opacity(0.9))
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 4)
    }

    // MARK: - Actions

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
            // Fuel on board is entered on the plan's own sheet. Without this, the row could tell you
            // the numbers disagreed and give you nowhere to fix them.
            return plan(for: thread) != nil ? L10n.Thread.editFuel : nil
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
            planEditorPlan = plan
        case .navLogReady:
            guard let plan = plan(for: thread) else { return }
            navLogExport = FlightPlanExportService.exportToPDF(plan)
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

// MARK: - Task row

/// One task. The tick is the whole point: same gesture, same feedback as a checklist item, applied to
/// admin work instead of an aircraft procedure.
struct ThreadTaskRow: View {
    let task: ThreadTask
    let onToggle: () -> Void
    let onDismissTask: () -> Void
    let onOpen: (URL) -> Void
    /// Operator tariff page for a fee task, resolved by the parent view. (v5.0.0)
    var tariffURL: URL?
    /// Whether this flight actually touches Switzerland, which gates the Swiss customs link.
    var touchesSwitzerland: Bool = false
    /// Label for an in-app tool this task can open (mass & balance, cost & logbook). Nil for a task
    /// that is only ever a tick.
    var toolLabel: String?
    var onOpenTool: (() -> Void)?

    private var presentation: ThreadTaskPresentation { .make(for: task) }
    private var links: [(label: String, url: URL)] {
        ThreadTaskPresentation.links(for: task, tariffURL: tariffURL, touchesSwitzerland: touchesSwitzerland)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                tickButton
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(presentation.title)
                            .scaledFont(size: 14, weight: .semibold, relativeTo: .subheadline)
                            .foregroundColor(task.state == .notApplicable ? .dimText : .primaryText)
                            .strikethrough(task.state == .notApplicable)
                        if task.kind == .auto {
                            Text("AUTO")
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
                            .scaledFont(size: 12, relativeTo: .caption)
                            .foregroundColor(.dimText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let note = task.note, !note.isEmpty {
                        Text(note)
                            .scaledFont(size: 12, relativeTo: .caption)
                            .foregroundColor(.aviationGold)
                    }
                    // Inside the text column, not a sibling of it. These used to hang off the outer
                    // stack with a hand-tuned `.leading` padding that did not match the tick button's
                    // real width, so every chip sat a few points LEFT of the title it belonged to.
                    // Nesting them makes the alignment structural instead of a guess.
                    if (!links.isEmpty || toolLabel != nil) && task.state != .notApplicable {
                        actionChips.padding(.top, 4)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: presentation.icon)
                    .scaledFont(size: 14, relativeTo: .footnote)
                    .foregroundColor(.dimText.opacity(0.6))
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
        .accessibilityValue(task.state == .done ? L10n.Thread.markDone : "")
        .accessibilityAddTraits(task.kind == .auto ? [] : .isButton)
    }

    /// The row's actions. Wraps rather than overflowing: a task can carry a tool button and two
    /// links, which does not fit on one line on an iPhone.
    private var actionChips: some View {
        FlowLayout(spacing: 8) {
                    if let toolLabel, let onOpenTool {
                        // Gold rather than blue: this one stays inside the app, where the blue chips
                        // all leave it.
                        Button(toolLabel) { onOpenTool() }
                            .scaledFont(size: 11, weight: .semibold, relativeTo: .caption2)
                            .foregroundColor(.aviationGold)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .overlay(Capsule().strokeBorder(Color.aviationGold.opacity(0.5), lineWidth: 1))
                            .buttonStyle(.plain)
                    }
                    ForEach(links, id: \.label) { link in
                        Button(link.label) { onOpen(link.url) }
                            .scaledFont(size: 11, weight: .semibold, relativeTo: .caption2)
                            .foregroundColor(.altimeterBlue)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .overlay(Capsule().strokeBorder(Color.altimeterBlue.opacity(0.45), lineWidth: 1))
                            .buttonStyle(.plain)
                    }
        }
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
    }

    private var tickColor: Color {
        switch task.state {
        case .done:          return .aviationGreen
        case .notApplicable: return .dimText.opacity(0.5)
        case .pending:       return task.isUrgent ? .aviationRed : .dimText
        }
    }
}
