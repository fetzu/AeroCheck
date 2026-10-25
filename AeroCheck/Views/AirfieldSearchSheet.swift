import SwiftUI
import MapKit
import CoreLocation

// MARK: - Plan › Map's aerodrome search (6.2.0)
//
// The author, testing: some aerodromes he didn't know were hard to find on Plan › Map. The magnifying
// glass left of "Map" opens a search by ICAO code or name, the planning screens' own
// (`AirportDataService.search`), and the map goes to the aerodrome chosen, its callout open.

/// What the search lists, and the callout of the aerodrome chosen. The rules are pure; the main-actor
/// entries read the app's store and the map through them.
enum AirfieldSearch {

    /// Fewer letters find half of Europe.
    static let minimumQueryLength = 2
    /// The list's length: a phone shows about that many rows over the keyboard.
    static let limit = 12
    /// The aerodromes the map's airport layer draws: no heliports, seaplane bases, balloon ports or
    /// closed fields, as in planning.
    static let types = AirportType.fixedWing
    /// The map's narrower side around the aerodrome chosen: its traffic circuit and the fields next to
    /// it in view (the approach view draws procedures from 8 NM across). The ICAO chart stops at its
    /// own nearest zoom (`AeroMapView.cameraZoomRange`), the glider chart, a little wider.
    static let spanNM: Double = 8

    /// The query as searched: trimmed, nil while too short to search.
    static func term(_ query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= minimumQueryLength ? trimmed : nil
    }

    /// The aerodromes for `query`: by ICAO code (whole, then its start), then by name, town or other
    /// names, whatever the case and the accents (`AirportSearchIndex`), the nearest to `near` (the map's
    /// centre) first within each.
    static func results(for query: String, airports: [Airport], index: AirportSearchIndex,
                        near reference: CLLocationCoordinate2D?) -> [Airport] {
        guard let term = term(query) else { return [] }
        return AirportDataService.search(airports, index: index, query: term, limit: limit,
                                         near: reference, types: types)
    }

    /// The same, from the app's store.
    @MainActor
    static func results(for query: String, in store: AirportDataService,
                        near reference: CLLocationCoordinate2D?) -> [Airport] {
        guard let term = term(query) else { return [] }
        return store.searchAirports(query: term, limit: limit, near: reference, types: types)
    }

    /// The aerodromes whose note holds `query` added to those found by code or name, each once, and
    /// the whole list nearest to `near` first: a note's match is listed where it is, not after the
    /// rest (the author's answer q-1, C). Without a reference, the note matches after the others.
    static func adding(noteMatchesFor query: String, to found: [Airport], notes: [AerodromeNote],
                       near reference: CLLocationCoordinate2D?, find: (String) -> Airport?) -> [Airport] {
        guard term(query) != nil else { return found }
        var result = found
        for note in notes {
            guard let airport = find(note.ident),
                  !result.contains(where: { $0.id == airport.id }) else { continue }
            result.append(airport)
        }
        guard let reference else { return result }
        let distance = { (airport: Airport) in
            AerodromeNoteMatch.distance(reference, CLLocationCoordinate2D(latitude: airport.latitude,
                                                                          longitude: airport.longitude))
        }
        return result.enumerated()
            .sorted { (distance($0.element), $0.offset) < (distance($1.element), $1.offset) }
            .map(\.element)
    }

    /// Whether the aerodrome has a marker on the map to open: the airport layer is on, and draws its
    /// kind. Otherwise the map only goes there.
    static func hasMarker(_ airport: Airport, airportsLayerOn: Bool) -> Bool {
        airportsLayerOn && types.contains(airport.type)
    }

    /// How long a callout asked for waits for the camera and the marker.
    static let calloutWait: TimeInterval = 5

    /// Whether the camera has got to the aerodrome: the map's centre within a tenth of its span of it.
    static func hasArrived(at pending: PendingCallout, center: CLLocationCoordinate2D, span: MKCoordinateSpan) -> Bool {
        abs(center.latitude - pending.latitude) <= span.latitudeDelta / 10
            && abs(center.longitude - pending.longitude) <= span.longitudeDelta / 10
    }

    /// Opens the callout the search asked for, as a tap on the marker would, once the camera is there
    /// and the marker on the map. Both map views call it after their airport markers are updated.
    ///
    /// Not before the camera has arrived: the marker is often on screen already, at the edge of where
    /// the map was, and a callout opening there moves the map a little, whose report of its region
    /// could take the camera back from the aerodrome (simulator, 11 Oct). MapKit ignores a marker still
    /// off screen: asked again at the next update until it takes.
    @MainActor
    static func openPendingCallout(on mapView: MKMapView, mapState: SharedMapState, now: Date = Date()) {
        guard let pending = mapState.pendingCallout else { return }
        guard now < pending.until else {
            mapState.pendingCallout = nil
            return
        }
        guard hasArrived(at: pending, center: mapView.centerCoordinate, span: mapView.region.span),
              let marker = mapView.annotations.lazy
                .compactMap({ $0 as? AirportAnnotation })
                .first(where: { $0.airport.ident == pending.ident }) else { return }
        mapView.selectAnnotation(marker, animated: true)
        if mapView.selectedAnnotations.contains(where: { $0 === marker }) {
            mapState.pendingCallout = nil
        }
    }
}

/// Where a search sends the map's camera (`SharedMapState.pendingCameraMove`). (6.2.0)
///
/// A camera at a distance, not a rectangle to fit: on the ICAO chart MapKit's fit stopped about 45 NM
/// across, far wider than the chart's own nearest zoom (simulator, 11 Oct).
struct PendingCameraMove {
    let center: CLLocationCoordinate2D

    init(to airport: Airport) {
        center = airport.coordinate
    }

    /// The camera there at once, `AirfieldSearch.spanNM` across the map's narrower side, within `range`
    /// (the swisstopo charts' zoom range: the ICAO chart's stops short of 8 NM), keeping its heading.
    /// False while the map has no size yet: left pending, as a fit is.
    @MainActor
    func apply(to mapView: MKMapView, within range: MKMapView.CameraZoomRange? = nil) -> Bool {
        let size = mapView.bounds.size
        guard size.width > 0, size.height > 0 else { return false }
        let wanted = Self.distance(across: AirfieldSearch.spanNM, viewSize: size,
                                   seenLatitudeDelta: mapView.region.span.latitudeDelta,
                                   at: mapView.camera.centerCoordinateDistance)
            ?? Self.fallbackDistance
        mapView.setCamera(MKMapCamera(lookingAtCenter: center, fromDistance: Self.held(wanted, within: range),
                                      pitch: 0, heading: mapView.camera.heading), animated: false)
        return true
    }

    /// The camera's distance for `spanNM` across a map of `viewSize`'s narrower side. A camera looking
    /// straight down sees a north-south extent in proportion to its distance, whatever the map's shape;
    /// the map as it is now (`seenLatitudeDelta` from `distance`) gives the proportion. Nil when the
    /// map has nothing to measure yet.
    static func distance(across spanNM: Double, viewSize: CGSize, seenLatitudeDelta: Double,
                         at distance: Double) -> Double? {
        guard viewSize.width > 0, viewSize.height > 0, seenLatitudeDelta > 0, seenLatitudeDelta < 90,
              distance > 0 else { return nil }
        let seenPerDistance = seenLatitudeDelta * 60 * 1852 / distance
        // North to south is the map's height; the narrower side has the span.
        let height = spanNM * 1852 * max(1, viewSize.height / viewSize.width)
        return height / seenPerDistance
    }

    /// Before the map has measured anything: about 8 NM on a square map.
    static let fallbackDistance: Double = 30_000

    /// `distance`, held within `range`. A range with no upper bound (an MKMapView's own, never set)
    /// reports 0 for it: held to 0, the camera went down to 56 m.
    static func held(_ distance: Double, within range: MKMapView.CameraZoomRange?) -> Double {
        guard let range else { return distance }
        let upper = range.maxCenterCoordinateDistance > range.minCenterCoordinateDistance
            ? range.maxCenterCoordinateDistance : .greatestFiniteMagnitude
        return min(max(distance, range.minCenterCoordinateDistance), upper)
    }
}

/// An aerodrome whose callout the map is to open when the camera and its marker are there. (6.2.0)
struct PendingCallout: Equatable {
    let ident: String
    let latitude: Double
    let longitude: Double
    /// Given up after this: the marker never came (the layer was switched off meanwhile).
    let until: Date

    init(_ airport: Airport, until: Date) {
        ident = airport.ident
        latitude = airport.latitude
        longitude = airport.longitude
        self.until = until
    }
}

/// The search itself: a field, focused at once, and the aerodromes found. Choosing one closes the sheet.
struct AirfieldSearchSheet: View {
    @EnvironmentObject var airportDataService: AirportDataService
    @Environment(\.dismiss) private var dismiss

    /// Where the map is: the nearest aerodromes first, and how far each is.
    let reference: CLLocationCoordinate2D?
    let onPick: (Airport) -> Void

    @State private var query = ""
    @State private var results: [Airport] = []
    @State private var isLoading = true
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    searchField
                    content
                }
                .padding()
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.cockpitBackground)
            .navigationTitle(L10n.Nav.searchAerodromes)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Button.cancel) { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { fieldFocused = true }
        .task {
            await airportDataService.ensureLoaded()
            isLoading = false
            search()
        }
        .onChange(of: query) { _, _ in search() }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .scaledFont(size: 15, relativeTo: .body)
                .foregroundColor(.dimText)
                .accessibilityHidden(true)
            TextField(L10n.Nav.searchAerodromes, text: $query,
                      prompt: Text(L10n.Flights.identPlaceholder))
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { if let first = results.first { pick(first) } }
                .scaledFont(size: 17, weight: .semibold, design: .monospaced, relativeTo: .body)
                .foregroundColor(.primaryText)
                .focused($fieldFocused)
                .accessibilityIdentifier("airfieldSearch.field")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .scaledFont(size: 15, relativeTo: .body)
                        .foregroundColor(.dimText)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.Button.clear)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, query.isEmpty ? 12 : 0)
        .frame(minHeight: 48)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.panelBackground))
    }

    @ViewBuilder
    private var content: some View {
        if isLoading || airportDataService.isDownloading {
            ProgressView().frame(maxWidth: .infinity).padding()
        } else if !airportDataService.isDataAvailable {
            note(L10n.Nav.searchNoAirportData)
        } else if AirfieldSearch.term(query) != nil && results.isEmpty {
            note(L10n.Nav.searchNoMatch(query.trimmingCharacters(in: .whitespacesAndNewlines)))
        } else if !results.isEmpty {
            VStack(spacing: 0) {
                ForEach(results) { airport in
                    if airport.id != results.first?.id {
                        Divider().overlay(Color.white.opacity(0.06)).padding(.leading, 82)
                    }
                    AirfieldSearchRow(airport: airport, reference: reference,
                                      note: AerodromeNoteStore.shared.note(for: airport), query: query) { pick(airport) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.cardBackground))
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .scaledFont(size: 14, relativeTo: .subheadline)
            .foregroundColor(.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
    }

    private func search() {
        guard !isLoading else { return }
        let found = AirfieldSearch.results(for: query, in: airportDataService, near: reference)
        results = AirfieldSearch.adding(noteMatchesFor: query, to: found,
                                        notes: AerodromeNoteStore.shared.notes(matching: query), near: reference,
                                        find: { airportDataService.findAirport(byIdent: $0) })
    }

    private func pick(_ airport: Airport) {
        onPick(airport)
        dismiss()
    }
}

/// One aerodrome found: its code, its name and town, and how far it is from the map's centre.
private struct AirfieldSearchRow: View {
    let airport: Airport
    let reference: CLLocationCoordinate2D?
    /// The pilot's note on it: the line the search found, else its first line, under the name. (6.7.0)
    var note: AerodromeNote?
    var query = ""
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Text(airport.ident)
                    .scaledFont(size: 15, weight: .bold, design: .monospaced, relativeTo: .body)
                    .foregroundColor(.aviationGold)
                    .lineLimit(1)
                    .frame(minWidth: 60, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(airport.name)
                        .scaledFont(size: 15, relativeTo: .body)
                        .foregroundColor(.primaryText)
                        .lineLimit(2)
                    if let town = place {
                        Text(town)
                            .scaledFont(size: 12, relativeTo: .caption)
                            .foregroundColor(.dimText)
                            .lineLimit(1)
                    }
                    if let note, !note.isEmpty {
                        Text(noteLine(note))
                            .scaledFont(size: 12, relativeTo: .caption)
                            .foregroundColor(.aviationGold)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                if let distance {
                    Text(distance)
                        .scaledFont(size: 13, weight: .medium, design: .monospaced, relativeTo: .footnote)
                        .foregroundColor(.secondaryText)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("airfieldSearch.result.\(airport.ident)")
    }

    /// The town and the country: "Geneva" finds fields in two countries, and a stranger's name says
    /// little on its own.
    private var place: String? {
        let town = airport.municipality.flatMap { $0.isEmpty || $0 == airport.name ? nil : $0 }
        let country = OpenAIPConfig.countryName(for: airport.isoCountry)
        guard let town else { return country.isEmpty ? nil : country }
        return country.isEmpty ? town : "\(town) · \(country)"
    }

    /// "Your note · On the ground: Restaurant open every day.", the part named.
    private func noteLine(_ note: AerodromeNote) -> String {
        let found = note.line(matching: query)
            ?? (note.hasArrival ? AerodromeNote.Part.arrival : .onTheGround, note.firstLine)
        let title = found.part == .arrival ? L10n.AerodromeNotes.yourNoteArrival : L10n.AerodromeNotes.yourNoteOnTheGround
        return L10n.Format.labelled(title, found.line)
    }

    private var distance: String? {
        guard let reference else { return nil }
        let nm = CLLocation(latitude: reference.latitude, longitude: reference.longitude)
            .distance(from: CLLocation(latitude: airport.latitude, longitude: airport.longitude)) / 1852
        return String(format: "%.0f NM", nm)
    }
}
