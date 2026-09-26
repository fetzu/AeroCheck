import SwiftUI

// MARK: - Upcoming flights (v5.0.0)
//
// The other half of the Flights destination. Flown flights live in Past; these are the ones still
// owed something — planned, being prepared, in the air, or waiting to be closed out.
//
// Close-out comes FIRST, always, and not because it is newest. It is the only state in this app with
// a real-world consequence for being ignored, and a pilot who has just landed opens this screen for
// exactly one reason.
//
// Planning proposal C (on-device review #4): overview first, details on demand. The next flight gets
// the room — when, its map and figures, the borders it crosses, its progress chapter by chapter and
// the next task — and later flights a line each, by day. It used to be a full-width button over one
// thin line per flight, with two thirds of the screen empty in portrait.

struct UpcomingFlightsList: View {
    let threads: [FlightThread]
    /// Trips whose legs appear in `threads`, so a multi-leg flight reads as one entry rather than
    /// as several unexplained ones. (v5.x)
    var trips: [Trip] = []
    let onOpen: (UUID) -> Void
    let onPlanNew: () -> Void
    /// Opens the saved-routes list. Optional so the view still previews without it. (v5.x)
    var onOpenRoutes: (() -> Void)?

    @EnvironmentObject private var flightPlanManager: FlightPlanManager

    private var needsAttention: [FlightThread] { threads.filter { $0.state == .closeOut } }

    /// What's ahead, in the order it will be flown. (on-device review #4)
    private var upcoming: [UpcomingOrder.Entry] { UpcomingOrder.entries(threads: threads, trips: trips) }

    var body: some View {
        GeometryReader { geometry in
            // Landscape: the next flight on the left, the rest beside it. (proposal C1)
            let wide = geometry.size.width > 1000
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    routesLink

                    if threads.isEmpty {
                        emptyState
                    } else {
                        if !needsAttention.isEmpty {
                            section(L10n.Flights.needsAttention, tint: .aviationRed, threads: needsAttention)
                        }
                        if let first = upcoming.first {
                            if wide {
                                HStack(alignment: .top, spacing: 16) {
                                    heroCard(first, wide: true)
                                        .frame(width: min(600, geometry.size.width * 0.52))
                                    laterList(Array(upcoming.dropFirst()))
                                        .frame(maxWidth: .infinity)
                                }
                            } else {
                                heroCard(first, wide: false)
                                laterList(Array(upcoming.dropFirst()))
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    // MARK: - Header (proposal C2)

    /// The count, and Plan new flight beside it: a button, not a bar over the list.
    private var header: some View {
        HStack(spacing: 12) {
            Text(L10n.FlightsPage.upcomingCount(upcoming.count).uppercased())
                .scaledFont(size: 13, weight: .bold, design: .monospaced, relativeTo: .caption)
                .foregroundColor(.secondaryText)
                .tracking(1.2)
            Spacer(minLength: 8)
            Button(action: onPlanNew) {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .scaledFont(size: 15, weight: .bold, relativeTo: .subheadline)
                    Text(L10n.Flights.planNewFlight)
                        .scaledFont(size: 16, weight: .bold, relativeTo: .body)
                }
                .foregroundColor(.black)
                .padding(.horizontal, 16)
                .frame(minHeight: 48)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.aviationGold))
            }
            .buttonStyle(.plain)
        }
    }

    /// The saved routes, reachable from here.
    ///
    /// Home shows ONE activity strip, and a followed flight takes that slot — which left the route
    /// list with no way in at all as soon as a flight existed, and arming (a swipe in that list) with
    /// it. Routes belong beside the flights that use them, so this is where they live now rather than
    /// behind whichever card Home happened to be showing. (device pass)
    @ViewBuilder
    private var routesLink: some View {
        if let onOpenRoutes {
            Button(action: onOpenRoutes) {
                HStack(spacing: 8) {
                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                        .scaledFont(size: 13, weight: .semibold, relativeTo: .footnote)
                    Text(L10n.Flights.savedRoutes)
                        .scaledFont(size: 13, weight: .semibold, relativeTo: .footnote)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .scaledFont(size: 11, weight: .semibold, relativeTo: .caption2)
                }
                .foregroundColor(.altimeterBlue)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.Flights.nothingPlanned)
                .scaledFont(size: 17, weight: .semibold, relativeTo: .title3)
                .foregroundColor(.primaryText)
            Text(L10n.Flights.homeExplainer)
                .scaledFont(size: 13, relativeTo: .callout)
                .foregroundColor(.dimText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.panelBackground))
    }

    // MARK: - The next flight (proposal C1)

    private func heroCard(_ entry: UpcomingOrder.Entry, wide: Bool) -> some View {
        let (thread, trip) = heroThread(entry)
        let plan = plan(for: thread)
        return Button { onOpen(thread.id) } label: {
            VStack(alignment: .leading, spacing: 14) {
                // When: the day, the time, and how long until.
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(dayLabel(thread.scheduledDeparture))
                        .scaledFont(size: 14, weight: .bold, design: .monospaced, relativeTo: .caption)
                        .tracking(1.2)
                        .foregroundColor(.aviationGold)
                    if let departure = thread.scheduledDeparture {
                        Text(departure.formatted(date: .omitted, time: .shortened))
                            .scaledFont(size: 30, weight: .bold, design: .monospaced, relativeTo: .title)
                            .foregroundColor(.primaryText)
                    }
                    Spacer(minLength: 8)
                    if let departure = thread.scheduledDeparture {
                        Text(Self.relative.localizedString(for: departure, relativeTo: Date()))
                            .scaledFont(size: 14, relativeTo: .subheadline)
                            .foregroundColor(.secondaryText)
                    }
                }
                if let trip, let leg = trip.legNumber(of: thread.id) {
                    Text(L10n.FlightsPage.tripLeg(leg, trip.legCount).uppercased())
                        .scaledFont(size: 12, weight: .bold, design: .monospaced, relativeTo: .caption2)
                        .tracking(1)
                        .foregroundColor(.secondaryText)
                }

                // What: the map, the name, the figures, the borders.
                HStack(alignment: .top, spacing: 16) {
                    if let plan, plan.waypoints.count >= 2 {
                        RouteThumbnail(waypoints: plan.waypoints)
                            .frame(width: wide ? 200 : 300, height: wide ? 140 : 180)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(trip?.name ?? thread.displayName)
                            .scaledFont(size: wide ? 22 : 26, weight: .bold, relativeTo: .title2)
                            .foregroundColor(.primaryText)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        if trip?.name != nil || thread.name != nil {
                            Text(thread.routeLabel)
                                .scaledFont(size: 15, design: .monospaced, relativeTo: .subheadline)
                                .foregroundColor(.secondaryText)
                        }
                        FlowLayout(spacing: 12) {
                            if let plan, plan.totalDistance > 0 { fact("DIST", String(format: "%.0f NM", plan.totalDistance)) }
                            if let plan, plan.totalEET > 0 { fact("EET", plan.formattedTotalEET) }
                            if let plan, !plan.waypoints.isEmpty { fact("WPT", "\(plan.waypoints.count)") }
                            if let registration = thread.aircraftRegistration, !registration.isEmpty {
                                fact("ACFT", registration)
                            }
                        }
                        if plan == nil || (plan?.waypoints.count ?? 0) < 2 {
                            Text(L10n.FlightsPage.noRoute)
                                .scaledFont(size: 13, relativeTo: .caption)
                                .foregroundColor(.dimText)
                        }
                        let borders = foreignCountries(thread)
                        if !borders.isEmpty {
                            FlowLayout(spacing: 8) {
                                ForEach(borders, id: \.self) { name in
                                    Text(L10n.FlightsPage.border(name))
                                        .scaledFont(size: 13, weight: .semibold, relativeTo: .caption)
                                        .foregroundColor(.secondaryText)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                                }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }

                // Where it stands: the flight's own chapters, as on its page.
                HStack(spacing: 10) {
                    ForEach(ThreadChapter.allCases) { chapter in
                        chapterProgress(thread, chapter: chapter)
                    }
                }

                // What's next, with the task's own figures.
                if let task = thread.nextTask {
                    HStack(spacing: 12) {
                        Text(L10n.Thread.nextUp.uppercased())
                            .scaledFont(size: 12, weight: .bold, design: .monospaced, relativeTo: .caption2)
                            .tracking(1.2)
                            .foregroundColor(.aviationGold)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ThreadTaskPresentation.make(for: task).title)
                                .scaledFont(size: 17, weight: .semibold, relativeTo: .body)
                                .foregroundColor(.primaryText)
                            if let detail = task.detail, !detail.isEmpty {
                                Text(detail)
                                    .scaledFont(size: 13, design: .monospaced, relativeTo: .caption)
                                    .foregroundColor(.secondaryText)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 8)
                        HStack(spacing: 4) {
                            Text(L10n.FlightsPage.openFlight)
                            Image(systemName: "chevron.right")
                        }
                        .scaledFont(size: 15, weight: .semibold, relativeTo: .subheadline)
                        .foregroundColor(.altimeterBlue)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.cockpitBackground))
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.cardBackground)
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.aviationGold.opacity(0.4), lineWidth: 1))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(label)
                .scaledFont(size: 11, weight: .semibold, design: .monospaced, relativeTo: .caption2)
                .foregroundColor(.dimText)
            Text(value)
                .scaledFont(size: 16, design: .monospaced, relativeTo: .subheadline)
                .foregroundColor(.primaryText)
        }
    }

    private func chapterProgress(_ thread: FlightThread, chapter: ThreadChapter) -> some View {
        let tasks = thread.tasks(in: chapter).filter { $0.state != .notApplicable }
        let done = tasks.filter { $0.state == .done }.count
        let flown = thread.state == .closeOut || thread.state == .done
        let fraction: Double = chapter == .fly ? (flown ? 1 : 0) : (tasks.isEmpty ? 0 : Double(done) / Double(tasks.count))
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(chapterName(chapter).uppercased())
                    .scaledFont(size: 12, weight: .bold, design: .monospaced, relativeTo: .caption2)
                    .foregroundColor(.secondaryText)
                if chapter != .fly && !tasks.isEmpty {
                    Text("\(done)/\(tasks.count)")
                        .scaledFont(size: 12, weight: .bold, design: .monospaced, relativeTo: .caption2)
                        .foregroundColor(.primaryText)
                }
            }
            ProgressBar(fraction: fraction)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chapterName(_ chapter: ThreadChapter) -> String {
        switch chapter {
        case .plan: return L10n.Thread.chapterPlan
        case .prepare: return L10n.Thread.chapterPrepare
        case .fly: return L10n.Thread.chapterFly
        case .close: return L10n.Thread.chapterClose
        }
    }

    // MARK: - Later flights, by day (proposal C1)

    private func laterList(_ entries: [UpcomingOrder.Entry]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(dayGroups(entries), id: \.title) { group in
                Text(group.title)
                    .scaledFont(size: 13, weight: .bold, design: .monospaced, relativeTo: .caption)
                    .tracking(1.2)
                    .foregroundColor(.secondaryText)
                    .padding(.top, 8)
                ForEach(group.entries) { entry in
                    switch entry {
                    case .trip(let trip): tripRow(trip)
                    case .flight(let thread): laterRow(thread)
                    }
                }
            }
        }
    }

    private struct DayGroup {
        let title: String
        let entries: [UpcomingOrder.Entry]
    }

    /// Consecutive entries under one heading per day; undated ones under "Not scheduled", last,
    /// which is where the order already puts them.
    private func dayGroups(_ entries: [UpcomingOrder.Entry]) -> [DayGroup] {
        var groups: [DayGroup] = []
        for entry in entries {
            let title = dayLabel(date(of: entry))
            if let last = groups.last, last.title == title {
                groups[groups.count - 1] = DayGroup(title: title, entries: last.entries + [entry])
            } else {
                groups.append(DayGroup(title: title, entries: [entry]))
            }
        }
        return groups
    }

    private func laterRow(_ thread: FlightThread) -> some View {
        let plan = plan(for: thread)
        let progress = thread.preFlightProgress
        return Button { onOpen(thread.id) } label: {
            HStack(spacing: 14) {
                Text(thread.scheduledDeparture.map { $0.formatted(date: .omitted, time: .shortened) } ?? "—")
                    .scaledFont(size: 19, weight: .bold, design: .monospaced, relativeTo: .body)
                    .foregroundColor(thread.scheduledDeparture == nil ? .dimText : .primaryText)
                    .frame(width: 64, alignment: .leading)
                if let plan, plan.waypoints.count >= 2 {
                    RouteThumbnail(waypoints: plan.waypoints)
                        .frame(width: 88, height: 54)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(thread.displayName)
                        .scaledFont(size: 17, weight: .semibold, relativeTo: .body)
                        .foregroundColor(.primaryText)
                        .lineLimit(1)
                    Text(routeFacts(thread, plan: plan))
                        .scaledFont(size: 13, design: .monospaced, relativeTo: .caption)
                        .foregroundColor(.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 5) {
                    Text(progressText(thread, progress: progress))
                        .scaledFont(size: 12, relativeTo: .caption)
                        .foregroundColor(.secondaryText)
                        .lineLimit(1)
                    ProgressBar(fraction: progress.total > 0 ? Double(progress.done) / Double(progress.total) : 0)
                        .frame(width: 140)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.cardBackground))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private func routeFacts(_ thread: FlightThread, plan: FlightPlan?) -> String {
        var parts: [String] = []
        if thread.name != nil { parts.append(thread.routeLabel) }
        if let plan, plan.waypoints.count >= 2 {
            if plan.totalDistance > 0 { parts.append(String(format: "%.0f NM", plan.totalDistance)) }
            if plan.totalEET > 0 { parts.append(plan.formattedTotalEET) }
        } else {
            parts.append(L10n.FlightsPage.noRoute)
        }
        if let registration = thread.aircraftRegistration, !registration.isEmpty { parts.append(registration) }
        return parts.joined(separator: " · ")
    }

    private func progressText(_ thread: FlightThread, progress: (done: Int, total: Int)) -> String {
        if let task = thread.nextTask {
            return L10n.FlightsPage.progressNext(progress.done, progress.total, ThreadTaskPresentation.make(for: task).title)
        }
        return L10n.FlightsPage.progress(progress.done, progress.total)
    }

    // MARK: - Close-out

    private func section(_ title: String, tint: Color, threads: [FlightThread]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .scaledFont(size: 11, weight: .bold, design: .monospaced, relativeTo: .caption2)
                .foregroundColor(tint)
                .tracking(0.8)
            ForEach(threads) { thread in
                row(thread)
            }
        }
    }

    private func row(_ thread: FlightThread) -> some View {
        let closing = thread.state == .closeOut
        let progress = closing ? thread.closeOutProgress : thread.preFlightProgress
        return Button { onOpen(thread.id) } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(thread.displayName)
                        .scaledFont(size: 15, weight: .semibold, relativeTo: .subheadline)
                        .foregroundColor(.primaryText)
                        .lineLimit(1)
                    Text(detail(thread))
                        .scaledFont(size: 12, design: .monospaced, relativeTo: .caption)
                        .foregroundColor(.dimText)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(badge(thread))
                    .scaledFont(size: 10, weight: .bold, design: .monospaced, relativeTo: .caption2)
                    .tracking(0.6)
                    .foregroundColor(closing ? .aviationRed : .aviationGold)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(closing ? Color.aviationRed : Color.aviationGold, lineWidth: 1)
                    )
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.cardBackground)
                    .overlay(alignment: .leading) {
                        // A rail rather than a full border: the close-out row has to be findable
                        // without reading, and only that row earns the colour.
                        if closing {
                            Rectangle().fill(Color.aviationRed).frame(width: 3)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(thread.displayName), \(badge(thread)), \(detail(thread))")
            .accessibilityValue(Text(verbatim: "\(progress.done)/\(progress.total)"))
        }
        .buttonStyle(.plain)
    }

    /// A trip: one card, its legs nested inside it. A journey is one thing to a pilot even when it
    /// is three flights to the app, and three loose rows would read as three journeys.
    private func tripRow(_ trip: Trip) -> some View {
        let legs = trip.legIds.compactMap { id in threads.first { $0.id == id } }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(trip.name ?? tripLabel(legs))
                    .scaledFont(size: 17, weight: .semibold, relativeTo: .body)
                    .foregroundColor(.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(L10n.Flights.legCount(legs.count))
                    .scaledFont(size: 10, weight: .bold, design: .monospaced, relativeTo: .caption2)
                    .tracking(0.6)
                    .foregroundColor(.aviationGold)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.aviationGold, lineWidth: 1))
            }
            ForEach(Array(legs.enumerated()), id: \.element.id) { index, leg in
                Button { onOpen(leg.id) } label: {
                    HStack(spacing: 8) {
                        Text("\(index + 1)")
                            .font(.aero(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.aviationGold)
                            .frame(width: 14, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(leg.displayName)
                                .scaledFont(size: 14, relativeTo: .footnote)
                                .foregroundColor(.primaryText)
                                .lineLimit(1)
                            Text(detail(leg))
                                .scaledFont(size: 12, design: .monospaced, relativeTo: .caption2)
                                .foregroundColor(.dimText)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.cockpitBackground))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.cardBackground))
    }

    // MARK: - Helpers

    private func plan(for thread: FlightThread) -> FlightPlan? {
        guard let id = thread.flightPlanId else { return nil }
        return flightPlanManager.flightPlans.first { $0.id == id }
    }

    /// The flight a hero card shows: the flight itself, or a trip's first leg still to fly.
    private func heroThread(_ entry: UpcomingOrder.Entry) -> (FlightThread, Trip?) {
        switch entry {
        case .flight(let thread):
            return (thread, nil)
        case .trip(let trip):
            let legs = trip.legIds.compactMap { id in threads.first { $0.id == id && $0.state != .closeOut } }
            // `UpcomingOrder` lists a trip only while a leg is still ahead, so there is one.
            let first = legs.first ?? threads.first { trip.legIds.contains($0.id) }
                ?? FlightThread(routeLabel: trip.name ?? "")
            return (first, trip)
        }
    }

    private func date(of entry: UpcomingOrder.Entry) -> Date? {
        switch entry {
        case .flight(let thread): return thread.scheduledDeparture
        case .trip(let trip):
            let legs = trip.legIds.compactMap { id in threads.first { $0.id == id && $0.state != .closeOut } }
            return legs.compactMap(\.scheduledDeparture).min() ?? trip.scheduledStart
        }
    }

    /// "TODAY", "TOMORROW · SUN 27 SEP", "MON 28 SEP", or "NOT SCHEDULED".
    private func dayLabel(_ date: Date?) -> String {
        guard let date else { return L10n.FlightsPage.notScheduled.uppercased() }
        let day = date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)).uppercased()
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return L10n.FlightsPage.today.uppercased() + " · " + day }
        if calendar.isDateInTomorrow(date) { return L10n.FlightsPage.tomorrow.uppercased() + " · " + day }
        return day
    }

    /// The countries the route crosses other than the one it leaves from, by name.
    private func foreignCountries(_ thread: FlightThread) -> [String] {
        let home = thread.homeCountry
        return (thread.countries ?? []).filter { $0 != home }
            .map { Locale.current.localizedString(forRegionCode: $0) ?? $0 }
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    /// Built from the legs rather than stored, so it stays right when one is added or removed.
    private func tripLabel(_ legs: [FlightThread]) -> String {
        guard let first = legs.first else { return "" }
        var idents = [first.routeLabel.components(separatedBy: " → ").first ?? ""]
        idents += legs.compactMap { $0.routeLabel.components(separatedBy: " → ").last }
        return idents.filter { !$0.isEmpty }.joined(separator: " → ")
    }

    private func badge(_ thread: FlightThread) -> String {
        switch thread.state {
        case .planned:  return L10n.Thread.chapterPlan
        case .ready:    return L10n.Thread.chapterPrepare
        case .flying:   return L10n.Thread.chapterFly
        case .closeOut, .done: return L10n.Thread.chapterClose
        }
    }

    /// What is actually left, rather than a timestamp. A pilot scanning this list is deciding what to
    /// pick up next, and "2 to do" answers that where "updated 3 h ago" does not.
    private func detail(_ thread: FlightThread) -> String {
        var parts: [String] = []
        if let departure = thread.scheduledDeparture {
            parts.append(departure.formatted(date: .abbreviated, time: .shortened))
        }
        if let registration = thread.aircraftRegistration, !registration.isEmpty {
            parts.append(registration)
        }
        let progress = thread.state == .closeOut ? thread.closeOutProgress : thread.preFlightProgress
        let remaining = max(0, progress.total - progress.done)
        if remaining > 0 { parts.append(L10n.Flights.toDo(remaining)) }
        return parts.joined(separator: " · ")
    }
}

/// A thin gold bar: how much of something is done.
private struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(Color.aviationGold)
                    .frame(width: max(0, min(1, fraction)) * geometry.size.width)
            }
        }
        .frame(height: 8)
    }
}

// MARK: - Order

/// The Upcoming list's order: the soonest planned departure first, then the flights with no date
/// yet, newest first. A trip is one entry, at the date of its first leg still to fly.
///
/// The list used to be two runs, every trip and then every flight, each by when it was last
/// EDITED: a flight planned for the 28th sat above one planned for the 27th because it had been
/// touched more recently. (on-device review #4)
enum UpcomingOrder {
    enum Entry: Identifiable {
        case trip(Trip)
        case flight(FlightThread)

        var id: UUID {
            switch self {
            case .trip(let trip): return trip.id
            case .flight(let thread): return thread.id
            }
        }
    }

    static func entries(threads: [FlightThread], trips: [Trip]) -> [Entry] {
        let ahead = threads.filter { $0.state != .closeOut }
        // Trips with at least one leg still owing something; their date is that leg's.
        let tripEntries: [(Entry, Date?, Date)] = trips.compactMap { trip in
            let legs = trip.legIds.compactMap { id in ahead.first { $0.id == id } }
            guard !legs.isEmpty else { return nil }
            let date = legs.compactMap(\.scheduledDeparture).min() ?? trip.scheduledStart
            return (.trip(trip), date, trip.createdAt)
        }
        // A trip's legs are shown under their trip, not loose: three rows for one journey would
        // read as three journeys.
        let flightEntries: [(Entry, Date?, Date)] = ahead.filter { $0.tripId == nil }.map {
            (.flight($0), $0.scheduledDeparture, $0.createdAt)
        }
        return (tripEntries + flightEntries).sorted { a, b in
            switch (a.1, b.1) {
            case let (x?, y?): return x != y ? x < y : a.2 > b.2
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return a.2 > b.2
            }
        }.map(\.0)
    }
}
