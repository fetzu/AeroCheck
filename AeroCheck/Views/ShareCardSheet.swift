import SwiftUI
import UIKit

// MARK: - What both share sheets are made of (6.1)

/// The card scaled into the room the sheet leaves it, with the spinner over it while the map loads
/// and Retry where the map should be when it did not come. (6.1: out of `ShareCardCustomizationView`,
/// so the journey's sheet is the same sheet.)
struct ShareCardPreviewFrame<Card: View>: View {
    let canvas: CGSize
    let isLoadingMap: Bool
    let showsRetry: Bool
    let onRetry: () -> Void
    @ViewBuilder let card: () -> Card

    var body: some View {
        GeometryReader { geometry in
            let maxWidth = geometry.size.width
            let maxHeight = geometry.size.height
            let cardAspect: CGFloat = canvas.width / canvas.height
            let previewWidth = min(maxWidth, maxHeight * cardAspect)
            let previewHeight = previewWidth / cardAspect

            ZStack {
                card()
                    .scaleEffect(previewWidth / canvas.width)
                    .frame(width: previewWidth, height: previewHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                if isLoadingMap {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.black.opacity(0.4))
                        .frame(width: previewWidth, height: previewHeight)
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.5)
                } else if showsRetry {
                    // Over the map's place on the card: back online, one tap loads it. (6.1)
                    Button(L10n.Button.retry, action: onRetry)
                        .scaledFont(size: 14, weight: .semibold, relativeTo: .subheadline)
                        .foregroundColor(.black)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.aviationGold))
                        .position(x: previewWidth / 2, y: previewHeight * 0.47)
                        .frame(width: previewWidth, height: previewHeight)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// A section's small capitals.
struct ShareCardSectionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .scaledFont(size: 12, weight: .bold, relativeTo: .caption)
            .foregroundColor(.secondaryText)
            .tracking(1.5)
    }
}

/// STYLE and FORMAT, side by side.
struct ShareCardStyleFormatPickers: View {
    @Binding var style: ShareCardStyle
    @Binding var format: ShareCardFormat

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                ShareCardSectionLabel(text: L10n.ShareCard.style)
                Picker(L10n.ShareCard.style, selection: $style) {
                    ForEach(ShareCardStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.segmented)
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 8) {
                ShareCardSectionLabel(text: L10n.ShareCard.format)
                Picker(L10n.ShareCard.format, selection: $format) {
                    ForEach(ShareCardFormat.allCases) { format in
                        Text(verbatim: format.ratioLabel)
                            .accessibilityLabel(format.accessibilityName)
                            .tag(format)
                    }
                }
                .pickerStyle(.segmented)
            }
            .frame(maxWidth: 140)
        }
    }
}

/// MAP STYLE: the layers as capsules, the picked one in gold.
struct ShareCardLayerPicker: View {
    let selection: ShareCardMapLayer
    let onPick: (ShareCardMapLayer) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MAP STYLE")
                .scaledFont(size: 12, weight: .bold, relativeTo: .caption)
                .foregroundColor(.secondaryText)
                .tracking(1.5)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(ShareCardMapLayer.allCases) { layer in
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.2)) { onPick(layer) }
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: layer.icon)
                                    .scaledFont(size: 13, weight: .medium, relativeTo: .caption)

                                Text(layer.displayName)
                                    .scaledFont(size: 13, weight: .semibold, relativeTo: .caption)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                Capsule()
                                    .fill(selection == layer ? Color.aviationGold : Color.cardBackground)
                            )
                            .foregroundColor(selection == layer ? .black : .white)
                        }
                    }
                }
            }
        }
    }
}

/// COLOR THEME: a dot per theme, the picked one ringed in gold.
struct ShareCardThemePicker: View {
    let selection: ShareCardColorScheme
    let onPick: (ShareCardColorScheme) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("COLOR THEME")
                .scaledFont(size: 12, weight: .bold, relativeTo: .caption)
                .foregroundColor(.secondaryText)
                .tracking(1.5)

            HStack(spacing: 12) {
                ForEach(ShareCardColorScheme.allCases) { scheme in
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) { onPick(scheme) }
                    }) {
                        VStack(spacing: 6) {
                            ZStack {
                                Circle()
                                    .fill(scheme.dotColor)
                                    .frame(width: 32, height: 32)
                                    .overlay(
                                        Circle()
                                            .stroke(
                                                scheme == .dark || scheme == .darkBlue ? Color.white.opacity(0.2) : Color.black.opacity(0.1),
                                                lineWidth: 1
                                            )
                                    )

                                if selection == scheme {
                                    Circle()
                                        .stroke(Color.aviationGold, lineWidth: 2.5)
                                        .frame(width: 40, height: 40)
                                }
                            }
                            .frame(width: 44, height: 44)

                            Text(scheme.displayName)
                                .scaledFont(size: 11, weight: .medium, relativeTo: .caption2)
                                .foregroundColor(selection == scheme ? .aviationGold : .secondaryText)
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                }
            }
        }
    }
}

/// TERRAIN: the profile's ground, fetched on first use.
struct ShareCardTerrainToggle: View {
    @Binding var isOn: Bool
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .center, spacing: 8) {
            Text("TERRAIN")
                .scaledFont(size: 12, weight: .bold, relativeTo: .caption)
                .foregroundColor(.secondaryText)
                .tracking(1.5)

            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isOn.toggle()
                }
            }) {
                VStack(spacing: 6) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isOn ? Color(red: 0.45, green: 0.32, blue: 0.18) : Color.cardBackground)
                            .frame(width: 32, height: 32)
                            .overlay(
                                Group {
                                    if isLoading {
                                        ProgressView()
                                            .scaleEffect(0.7)
                                            .tint(.white)
                                    } else {
                                        Image(systemName: "mountain.2.fill")
                                            .scaledFont(size: 14, weight: .semibold, relativeTo: .subheadline)
                                            .foregroundColor(isOn ? .white : .secondaryText)
                                    }
                                }
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(isOn ? Color(red: 0.45, green: 0.32, blue: 0.18) : Color.white.opacity(0.2), lineWidth: isOn ? 2.5 : 1)
                            )
                    }
                    .frame(width: 44, height: 44)

                    Text(isLoading ? "..." : (isOn ? "On" : "Off"))
                        .scaledFont(size: 11, weight: .medium, relativeTo: .caption2)
                        .foregroundColor(isOn ? Color(red: 0.65, green: 0.48, blue: 0.28) : .secondaryText)
                }
            }
            .disabled(isLoading)
        }
    }
}

/// A switch with its title and a line of explanation: "Hide where I parked", "Add each leg's card".
struct ShareCardSwitch: View {
    @Binding var isOn: Bool
    let title: String
    let hint: String

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .scaledFont(size: 15, weight: .semibold, relativeTo: .subheadline)
                    .foregroundColor(.primaryText)
                Text(hint)
                    .scaledFont(size: 12, relativeTo: .caption)
                    .foregroundColor(.secondaryText)
            }
        }
        .tint(.aviationGold)
    }
}

/// Share, in gold: dimmed until the card is ready, a spinner while it is made (with how far, for a
/// share of several images).
struct ShareCardShareButton: View {
    let canShare: Bool
    let isWorking: Bool
    var progress: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isWorking {
                    ProgressView()
                        .tint(.black)
                    if let progress {
                        Text(verbatim: progress)
                            .scaledFont(size: 15, weight: .semibold, relativeTo: .subheadline)
                    }
                } else {
                    Image(systemName: "square.and.arrow.up")
                }
                Text("Share")
                    .scaledFont(size: 18, weight: .bold, relativeTo: .title3)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.aviationGold)
            )
            .foregroundColor(.black)
            .opacity(canShare || isWorking ? 1 : 0.5)
        }
        .disabled(!canShare)
    }
}

extension View {
    /// The share sheets on an iPad: a page rather than a form sheet, whose height left the card's
    /// preview a sliver under the controls. iOS 18 and later; a form sheet before. (6.1)
    @ViewBuilder
    func shareCardSheetSizing() -> some View {
        if #available(iOS 18.0, *) {
            presentationSizing(.page)
        } else {
            self
        }
    }
}

// MARK: - The shared image (6.1)

enum ShareCardExport {
    /// A card as it is shared: drawn at 2× (1080 × 1920 pt give 2160 × 3840 px), then one JPEG pass
    /// at `shareImageJPEGQuality` off the main thread. Nil when the renderer gives nothing three times.
    @MainActor
    static func jpeg<Content: View>(_ content: Content, size: CGSize) async -> Data? {
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2.0
        // Propose explicit size to help ImageRenderer resolve the layout
        renderer.proposedSize = ProposedViewSize(size)

        // ImageRenderer can return nil on first invocation for complex views.
        // Retry up to 3 times with brief yields to let the rendering pipeline warm up.
        var uiImage: UIImage?
        for attempt in 0..<3 {
            uiImage = renderer.uiImage
            if uiImage != nil { break }
            if attempt < 2 {
                try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
            }
        }
        guard let renderedImage = uiImage else { return nil }
        return await Task.detached(priority: .userInitiated) {
            renderedImage.jpegData(compressionQuality: shareImageJPEGQuality)
        }.value
    }
}

// MARK: - The journey's sheet (6.1)

/// Flights to share as one card, and the sheet's title: "Share day" from the Logbook, "Share trip"
/// from a trip's page.
struct JourneyShareRequest: Identifiable {
    let id = UUID()
    let flights: [Flight]
    let title: String
}

/// "Share day" and "Share trip": the single card's sheet for several flights. The same preview,
/// STYLE and FORMAT, MAP STYLE, COLOR THEME, TERRAIN and "Hide where I parked" (remembered with the
/// single card's), the same renderer, plus "Add each leg's card", off by default: the share then
/// sends the journey card first and each leg's own card after it, as one share of several images.
struct JourneyShareCustomizationView: View {
    let journey: ShareCardJourney
    var appState: AppState
    var airports: AirportDataService?
    /// "Share day" or "Share trip".
    let title: String

    @Environment(\.dismiss) private var dismiss

    @State private var selectedScheme: ShareCardColorScheme
    @State private var selectedMapLayer: ShareCardMapLayer
    @AppStorage("shareCard.style") private var selectedStyle: ShareCardStyle = .standard
    @AppStorage("shareCard.format") private var selectedFormat: ShareCardFormat = .story
    @AppStorage("shareCard.hideParking") private var hideParking = false
    /// Each leg's own card after the journey's: off by default, remembered on the device.
    @AppStorage("shareCard.eachLeg") private var eachLeg = false
    @State private var showTerrain = false
    /// Each leg's terrain and where it came from, by flight.
    @State private var terrain: [UUID: [(time: Date, elevationFeet: Double)]] = [:]
    @State private var terrainSources: [UUID: ElevationService.TrackTerrainSource] = [:]
    @State private var isLoadingTerrain = false
    @State private var previewMapImage: UIImage?
    @State private var previewMapCredit: ShareCardMapCredit?
    @State private var mapSubstitute: ShareCardTileSource?
    @State private var mapPlaceholder: ShareCardMapPlaceholder = .loading
    @State private var isLoadingMap = false
    @State private var mapLoadGeneration = 0
    @State private var isGeneratingShare = false
    /// "2/4" while a share of several images is being made.
    @State private var shareProgress: String?
    /// The aerodromes' names by ident, each leg's line of names and its route as flown (for its own
    /// card), once the data on the device has answered.
    @State private var names: [String: String] = [:]
    @State private var legLines: [UUID: String] = [:]
    @State private var legRoutes: [UUID: [ShareCardRouteStop]] = [:]
    @State private var isLoadingNames = true

    private let elevationService = ElevationService()

    init(flights: [Flight], appState: AppState, airports: AirportDataService? = nil, title: String) {
        self.journey = ShareCardJourney(flights: flights,
                                        nauticalMiles: appState.settings.distanceInNauticalMiles,
                                        useUTC: appState.settings.alwaysUseUTC)
        self.appState = appState
        self.airports = airports
        self.title = title
        _selectedScheme = State(initialValue: appState.settings.shareCardColorScheme)
        _selectedMapLayer = State(initialValue: appState.settings.shareCardMapLayer)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.cockpitBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    ShareCardPreviewFrame(canvas: selectedFormat.size, isLoadingMap: isLoadingMap,
                                          showsRetry: mapPlaceholder == .unavailable && previewMapImage == nil,
                                          onRetry: { Task { await loadMapPreview() } }) {
                        card(mapImage: previewMapImage)
                    }
                    .padding(.top, 12)
                    .padding(.horizontal, 24)

                    Spacer(minLength: 16)

                    ShareCardStyleFormatPickers(style: $selectedStyle, format: $selectedFormat)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 14)

                    ShareCardLayerPicker(selection: selectedMapLayer) { layer in
                        selectedMapLayer = layer
                        appState.settings.shareCardMapLayer = layer
                        appState.saveSettings()
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, substituteNote == nil ? 14 : 6)

                    if let substituteNote {
                        Text(substituteNote)
                            .scaledFont(size: 12, relativeTo: .caption)
                            .foregroundColor(.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 12)
                    }

                    HStack {
                        ShareCardThemePicker(selection: selectedScheme) { scheme in
                            selectedScheme = scheme
                            appState.settings.shareCardColorScheme = scheme
                            appState.saveSettings()
                        }
                        Spacer()
                        ShareCardTerrainToggle(isOn: $showTerrain, isLoading: isLoadingTerrain)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)

                    ShareCardSwitch(isOn: $hideParking, title: L10n.ShareCard.hideParking,
                                    hint: L10n.ShareCard.hideParkingJourneyHint)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 10)

                    ShareCardSwitch(isOn: $eachLeg, title: L10n.ShareCard.eachLeg,
                                    hint: L10n.ShareCard.eachLegHint(journey.legs.count + 1))
                        .padding(.horizontal, 20)
                        .padding(.bottom, 16)

                    ShareCardShareButton(canShare: canShare, isWorking: isGeneratingShare, progress: shareProgress) {
                        Task { await generateAndShare() }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Button.close) { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .shareCardSheetSizing()
        .task { await loadMapPreview() }
        .task { await loadNames() }
        .onChange(of: selectedMapLayer) { _, _ in Task { await loadMapPreview() } }
        .onChange(of: selectedScheme) { _, _ in Task { await loadMapPreview() } }
        .onChange(of: selectedStyle) { _, _ in Task { await loadMapPreview() } }
        .onChange(of: selectedFormat) { _, _ in Task { await loadMapPreview() } }
        .onChange(of: hideParking) { _, _ in Task { await loadMapPreview() } }
        .onChange(of: showTerrain) { _, newValue in
            if newValue && terrain.isEmpty { Task { await loadTerrainData() } }
        }
    }

    /// The journey card as it is shared, for the preview and the render.
    private func card(mapImage: UIImage?) -> JourneyShareCard {
        JourneyShareCard(journey: journey, mapImage: mapImage, colorScheme: selectedScheme,
                         terrain: shownTerrain, mapPlaceholder: mapPlaceholder,
                         credit: ShareCardFigures.credit(map: mapImage == nil ? nil : previewMapCredit,
                                                         terrains: shownTerrain.isEmpty ? [] : Array(terrainSources.values)),
                         style: selectedStyle, format: selectedFormat, names: names)
    }

    private var shownTerrain: [UUID: [(time: Date, elevationFeet: Double)]] { showTerrain ? terrain : [:] }

    private var substituteNote: String? {
        switch mapSubstitute {
        case .gliderChart?: return L10n.ShareCard.gliderChartNote
        case .nationalMap?: return L10n.ShareCard.nationalMapNote
        default: return nil
        }
    }

    private var canShare: Bool { !isGeneratingShare && !isLoadingMap && !isLoadingTerrain && !isLoadingNames }

    // MARK: Loading

    /// The aerodromes' names, and each leg's line and route for its own card, as the single sheet
    /// finds them: from the data on the device, nothing downloaded.
    @MainActor
    private func loadNames() async {
        defer { isLoadingNames = false }
        if let airports, airports.isDataAvailable {
            await airports.ensureLoaded()
            var found: [String: String] = [:]
            let idents = Set(journey.aerodromes + journey.ends.flatMap { [$0.departure, $0.arrival] }.compactMap { $0 })
            for ident in idents {
                if let name = airports.findAirport(byIdent: ident)?.name { found[ident] = name }
            }
            names = found
            for flight in journey.legs {
                legLines[flight.id] = ShareCardFigures.aerodromeLine(for: flight) { ident in
                    airports.findAirport(byIdent: ident)?.name
                        ?? (flight.flightPlan?.diversion?.ident == ident ? flight.flightPlan?.diversion?.name : nil)
                }
            }
        }
        guard eachLegNeedsRoutes else { return }
        let points = ReportingPointCatalog.shared
        guard points.isDataAvailable else { return }
        await points.ensureLoaded()
        for flight in journey.legs {
            guard let plan = flight.flightPlan,
                  plan.waypoints.contains(where: { $0.pointKind == .vrp && ($0.aerodromeICAO ?? "").isEmpty }) else { continue }
            let qualified = ShareCardRoute.qualifyingReportingPoints(plan) { waypoint in
                waypoint.sourceId.flatMap(points.aerodrome(forSourceId:))?.icao
            }
            legRoutes[flight.id] = ShareCardRoute.flown(flight, plan: qualified.withActualTimesOver(from: flight))
        }
    }

    /// A leg's own card names its reporting points' aerodromes ("E (LSGC)"): worth loading the
    /// points only when a plan needs it.
    private var eachLegNeedsRoutes: Bool {
        journey.legs.contains { flight in
            flight.flightPlan?.waypoints.contains { $0.pointKind == .vrp && ($0.aerodromeICAO ?? "").isEmpty } ?? false
        }
    }

    @MainActor
    private func loadMapPreview() async {
        mapLoadGeneration += 1
        let generation = mapLoadGeneration
        let layer = selectedMapLayer
        let mapJourney = journey.mapJourney(hideParking: hideParking)
        guard mapJourney.allCoordinates.count >= 2 else {
            previewMapImage = nil
            previewMapCredit = nil
            mapSubstitute = nil
            mapPlaceholder = .noTrack
            isLoadingMap = false
            return
        }
        isLoadingMap = true
        if previewMapImage == nil { mapPlaceholder = .loading }
        let shape = JourneyShareCard.mapShape(for: journey, style: selectedStyle, format: selectedFormat)
        let request = ShareCardMapRequest.journey(mapJourney, frame: shape.frame, clearTop: shape.clearTop,
                                                  clearBottom: shape.clearBottom, style: shape.style)
        let map = await ShareCardMapRenderer.render(request, layer: layer, scheme: selectedScheme)
        guard generation == mapLoadGeneration else { return }
        previewMapImage = map?.image
        previewMapCredit = map?.credit
        mapSubstitute = map?.substitute
        mapPlaceholder = map == nil ? .unavailable : .loading
        isLoadingMap = false
    }

    /// Each leg's terrain, for the journey's profile and each leg's own card.
    private func loadTerrainData() async {
        isLoadingTerrain = true
        var found: [UUID: [(time: Date, elevationFeet: Double)]] = [:]
        var sources: [UUID: ElevationService.TrackTerrainSource] = [:]
        for flight in journey.legs where flight.gpsTrack.count >= 2 {
            let points = flight.gpsTrack.map { (coordinate: $0.coordinate, timestamp: $0.timestamp) }
            let results = await elevationService.fetchTrackTerrainProfile(gpsTrack: points, targetSamples: 80)
            guard !results.isEmpty, let first = points.first, let last = points.last else { continue }
            found[flight.id] = results.map { (time: $0.time, elevationFeet: $0.elevationMeters * 3.28084) }
            sources[flight.id] = ElevationService.trackTerrainSource(first: first.coordinate, last: last.coordinate)
        }
        await MainActor.run {
            terrain = found
            terrainSources = sources
            isLoadingTerrain = false
            if found.isEmpty { showTerrain = false }
        }
    }

    // MARK: Sharing

    @MainActor
    private func generateAndShare() async {
        isGeneratingShare = true
        defer {
            isGeneratingShare = false
            shareProgress = nil
        }
        let items = journey.shareItems(eachLeg: eachLeg, hideParking: hideParking)
        var files: [(data: Data, filename: String)] = []
        for (position, item) in items.enumerated() {
            if items.count > 1 { shareProgress = "\(position + 1)/\(items.count)" }
            let data: Data?
            switch item.kind {
            case .journey:
                // The preview's map, already made for this style, format and trim.
                data = await ShareCardExport.jpeg(card(mapImage: previewMapImage), size: selectedFormat.size)
            case .leg(let index):
                data = await legCard(index, trimsStart: item.trimsStart, trimsEnd: item.trimsEnd)
            }
            // A leg whose card could not be drawn is left out rather than stopping the share.
            if let data { files.append((data, "\(item.filename).jpg")) }
        }
        guard !files.isEmpty else { return }
        presentImageShareSheet(files: files)
    }

    /// A leg's own card, #238's, exactly as its own sheet would make it in these settings: its route
    /// as flown, its map with the plan's waypoints, its terrain, its credit.
    @MainActor
    private func legCard(_ index: Int, trimsStart: Bool, trimsEnd: Bool) async -> Data? {
        let flight = journey.legs[index]
        let route = legRoutes[flight.id] ?? FlightShareCard.route(for: flight)
        let layout = FlightShareCard.layout(for: flight, style: selectedStyle, format: selectedFormat, route: route)
        let track = ShareCardPrivacy.trimmingParking(flight.gpsTrack, start: trimsStart, end: trimsEnd)
        var map: ShareCardMapImage?
        if track.count >= 2 {
            let request = ShareCardMapRequest(frame: layout.mapFrame, clearTop: layout.mapClearTop,
                                              clearBottom: layout.mapClearBottom, style: layout.mapStyle,
                                              track: track.map(\.coordinate),
                                              waypoints: ShareCardRoute.mapWaypoints(flight.flightPlan))
            map = await ShareCardMapRenderer.render(request, layer: selectedMapLayer, scheme: selectedScheme)
        }
        let legTerrain = showTerrain ? (terrain[flight.id] ?? []) : []
        let card = FlightShareCard(
            flight: flight,
            mapImage: map?.image,
            useUTC: appState.settings.alwaysUseUTC,
            colorScheme: selectedScheme,
            terrainData: legTerrain,
            nauticalMiles: appState.settings.distanceInNauticalMiles,
            mapPlaceholder: track.count >= 2 ? (map == nil ? .unavailable : .loading) : .noTrack,
            credit: ShareCardFigures.credit(map: map?.credit, terrain: legTerrain.isEmpty ? nil : terrainSources[flight.id]),
            style: selectedStyle,
            format: selectedFormat,
            aerodromeLine: legLines[flight.id],
            route: route
        )
        return await ShareCardExport.jpeg(card, size: selectedFormat.size)
    }
}
