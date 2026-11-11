import SwiftUI
import UIKit

// MARK: - An aerodrome's card on the map (6.7.0, the author's answers c1 A, c2 A, c3 A)
//
// The author's device check n-2: MapKit's bubble read badly (two kinds of button, five sizes, the note cut after a
// line). An aerodrome's marker opens the app's own card instead: the code large, the name, the frequencies, the
// pilot's note, and one row of buttons of equal width. The card knows nothing of the map it sits on: what it holds is
// `AerodromeCardContent`, how it looks is `AerodromeCardView`, and the map's own anchor places it over the marker
// (`PilotMarkerCallout`, by `CalloutPlacement`), so the move to MapLibre (6.8.0) kept the card and changed only the
// anchor.

/// What the map knows of a field beyond its marker: the rows of the card. (6.9.0, c1 A)
struct AerodromeFacts: Equatable {
    var isPPR = false
    var runways: [String] = []
    /// "circuit 2900 ft" beside the elevation, from open flightmaps.
    var circuit: String?
    /// "12:50Z · 240/08 kt · 9999 m · Q1018", when the app holds a METAR under an hour old (c3 A).
    var weather: String?
    /// Plan › Map's links, after the note (c5 A).
    var feeLink: URL?
    var briefingLink: URL?
    /// The field's NOTAMs on the device. None, or a country without a list: no row at all, because any text would make a
    /// pilot expect NOTAMs to be there (the author, 6 Nov 2026).
    var notams: [Notam] = []

    /// What the two sources write for the same surface. Words a pilot reads as written in every language.
    private static let surfaceNames = ["GRS": "GRASS", "ASP": "ASPHALT", "CON": "CONCRETE", "TURF": "GRASS"]
    /// A field's strips can run to seven (Bern): the card keeps the three longest, its row stays one glance.
    static let maxRunways = 3

    /// A field's circuit altitude, or the range when its circuits differ: Bern flies 3000 ft to the north-east and 2800 ft
    /// to the south-west, and one number would be wrong for one of them (the author's q9, 5 Nov 2026). The map says which
    /// circuit is which.
    static func circuitText(_ altitudes: [Int]) -> String? {
        guard let low = altitudes.min(), let high = altitudes.max() else { return nil }
        return L10n.Nav.cardCircuit(low == high ? String(low) : "\(low)–\(high)")
    }

    /// The rows for a field's runways: the longest first, three at most, none closed. In columns, the card's font being
    /// monospaced: Grenchen's 06R/24L under its 06/24 read as a broken list before (the author's r2-4, 5 Nov 2026).
    static func runwayLines(_ runways: [Runway]) -> [String] {
        let rows = runways.filter { !$0.closed }.sorted { ($0.lengthFt ?? 0) > ($1.lengthFt ?? 0) }
            .compactMap(runwayColumns).prefix(maxRunways)
        let nameWidth = rows.map(\.name.count).max() ?? 0
        let lengthWidth = rows.map(\.length.count).max() ?? 0
        return rows.map { row in
            var line = row.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
            if lengthWidth > 0 {
                line += row.name.isEmpty || row.length.isEmpty ? "   " : " · "
                line += String(repeating: " ", count: lengthWidth - row.length.count) + row.length
            }
            if !row.surface.isEmpty { line += row.length.isEmpty ? "   " : " · " }
            return (line + row.surface).trimmingCharacters(in: .whitespaces)
        }
    }

    /// "05/23 · 1200 m · ASPHALT": the designators, the length in metres, the surface. Nil for a closed runway.
    static func runwayLine(_ runway: Runway) -> String? {
        runwayColumns(runway).map { [$0.name, $0.length, $0.surface].filter { !$0.isEmpty }.joined(separator: " · ") }
    }

    /// A runway's three columns, empty where the source has nothing. Nil for a closed runway, or one with nothing to say.
    private static func runwayColumns(_ runway: Runway) -> (name: String, length: String, surface: String)? {
        guard !runway.closed else { return nil }
        let name = [runway.leIdent, runway.heIdent].compactMap { $0 }.joined(separator: "/")
        let length = runway.lengthFt.map { "\(Int((Double($0) * 0.3048).rounded())) m" } ?? ""
        let surface = runway.surface.flatMap { $0.isEmpty ? nil : surfaceNames[$0.uppercased()] ?? $0.uppercased() } ?? ""
        return name.isEmpty && length.isEmpty && surface.isEmpty ? nil : (name, length, surface)
    }

    /// A METAR as one line, or nil over an hour old: wind, visibility, QNH, each left out where the report has none.
    static func weatherLine(_ metar: AviationWeatherService.Metar, now: Date) -> String? {
        guard let observed = metar.observedAt, now.timeIntervalSince(observed) < 3600 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let time = calendar.dateComponents([.hour, .minute], from: observed)
        var parts = [String(format: "%02d:%02dZ", time.hour ?? 0, time.minute ?? 0)]
        if metar.windVariable, let speed = metar.windSpeedKt {
            parts.append(String(format: "VRB/%02d kt", speed))
        } else if let direction = metar.windDirectionDeg, let speed = metar.windSpeedKt {
            parts.append(String(format: "%03d/%02d kt", direction, speed))
        }
        if let conditions = metar.decoded?.conditions {
            if conditions.cavok {
                parts.append("CAVOK")
            } else if let visibility = conditions.visibility {
                parts.append(visibility.unit == "m" ? "\(Int(visibility.value)) m" : "\(visibility.value) SM")
            }
        }
        if let qnh = metar.altimeterHpa { parts.append("Q\(Int(qnh.rounded()))") }
        return parts.joined(separator: " · ")
    }
}

/// What an aerodrome's card holds, decided from the field, the pilot's note and what the map surface offers.
struct AerodromeCardContent: Equatable {
    struct Frequency: Equatable {
        let label: String
        let value: String
        /// The field's own contact, framed (c2 A).
        var isFieldContact = false
    }

    /// A part of the pilot's note as the card shows it: its text and how many lines it may take.
    struct NoteLine: Equatable {
        let part: AerodromeNote.Part
        let text: String
        let maxLines: Int
    }

    enum Action: Equatable {
        case chart(OfficialChartLink)
        /// The pilot's note: `existing` opens it, otherwise one is started.
        case note(existing: Bool)
        case divert
        case addToRoute
        case fees(URL)
        case briefing(URL)

        var identifier: String {
            switch self {
            case .chart: return "aerodromeCard.chart"
            case .note: return "aerodromeCard.note"
            case .divert: return "aerodromeCard.divert"
            case .addToRoute: return "aerodromeCard.addToRoute"
            case .fees: return "aerodromeCard.fees"
            case .briefing: return "aerodromeCard.briefing"
            }
        }
    }

    let ident: String
    let name: String
    let frequencies: [Frequency]
    let note: [NoteLine]
    let actions: [Action]
    var elevationFt: Int? = nil
    var facts = AerodromeFacts()
    /// In flight the Cockpit's colours, on the ground the gold (c6 A).
    var inFlight = false
    var isDiverting = false

    /// What the card writes where the app has nothing (c1 A).
    static let dash = "—"

    /// The rows, so one reads the same with or without data: ident and name, then these.
    var elevationRow: String {
        var parts = [elevationFt.map { "\($0) ft" } ?? Self.dash]
        if let circuit = facts.circuit { parts.append(circuit) }
        if facts.isPPR { parts.append("PPR") }
        return parts.joined(separator: " · ")
    }

    var runwayRow: String {
        facts.runways.isEmpty ? Self.dash : facts.runways.joined(separator: "\n")
    }

    var weatherRow: String { facts.weather ?? Self.dash }

    /// "NOTAM 2" and the first one's text; nil with none, and the card then has no row. Never a dash here.
    var notamRow: (count: String, text: String)? {
        facts.notams.first.map { ("NOTAM \(facts.notams.count)", $0.shownText) }
    }

    /// On the ground the first line of each part written, two lines each; in flight the Arrival part alone, three
    /// lines, as everywhere in the Cockpit (c2 A, n1 A). A note without an Arrival part shows nothing in flight.
    static let groundLinesPerPart = 2
    static let flightLines = 3

    /// - Parameters:
    ///   - frequencyLines: the field's frequencies, one per line, its kind then its value ("AD 122.055").
    ///   - note: the pilot's note, nil where the surface shows none (the dry run).
    ///   - canOpenNote: the surface opens notes.
    ///   - canDivert: in flight, with a route to divert from.
    ///   - canAddToRoute: the route builder's "+".
    static func make(airport: Airport, frequencyLines: String?, note: AerodromeNote?, inFlight: Bool,
                     chart: OfficialChartLink?, canOpenNote: Bool, canDivert: Bool, canAddToRoute: Bool,
                     facts: AerodromeFacts = AerodromeFacts(), isDiverting: Bool = false) -> Self {
        var lines: [NoteLine] = []
        if let note, !note.isEmpty {
            if inFlight {
                if note.hasArrival {
                    lines = [NoteLine(part: .arrival, text: AerodromeNote.trimmed(note.arrival), maxLines: flightLines)]
                }
            } else {
                for (part, text) in [(AerodromeNote.Part.arrival, note.arrival), (.onTheGround, note.onTheGround)] {
                    guard let first = firstLine(of: text) else { continue }
                    lines.append(NoteLine(part: part, text: first, maxLines: groundLinesPerPart))
                }
            }
        }
        var actions: [Action] = []
        if let chart { actions.append(.chart(chart)) }
        // In flight a note only reads, and none is started (n3 A).
        if canOpenNote, !lines.isEmpty || !inFlight { actions.append(.note(existing: !lines.isEmpty)) }
        if canDivert { actions.append(.divert) }
        if canAddToRoute { actions.append(.addToRoute) }
        if !inFlight {
            if let link = facts.feeLink { actions.append(.fees(link)) }
            if let link = facts.briefingLink { actions.append(.briefing(link)) }
        }
        return Self(ident: airport.ident, name: AerodromeName.display(airport.name),
                    frequencies: frequencies(from: frequencyLines), note: lines, actions: actions,
                    elevationFt: airport.elevation, facts: facts, inFlight: inFlight, isDiverting: isDiverting)
    }

    /// Who a pilot calls, in that order: ATIS, approach or information, the field, ground (c2 A).
    static func callingRank(_ label: String) -> Int {
        let upper = label.uppercased()
        if upper.contains("ATIS") { return 0 }
        if ["APP", "ARR", "DEP", "INFO", "FIS", "APPROACH"].contains(where: upper.contains) { return 1 }
        if ["TWR", "TOWER", "AFIS", "AD", "RDO", "RADIO", "A/G", "CTAF", "UNICOM"].contains(where: upper.contains) { return 2 }
        if ["GND", "GROUND", "DEL", "APRON"].contains(where: upper.contains) { return 3 }
        return 4
    }

    /// The field's frequencies in calling order, one chip per frequency: two names for one frequency are merged, the
    /// 8.33 kHz name kept (`Station.preferredName`), and the field's own contact framed.
    static func called(_ frequencies: [Frequency]) -> [Frequency] {
        var merged: [Frequency] = []
        for frequency in frequencies {
            let hertz = RouteRadioPlanner.Station.hertz(frequency.value)
            if let hertz, let index = merged.firstIndex(where: { RouteRadioPlanner.Station.hertz($0.value) == hertz }) {
                let kept = merged[index]
                let label = callingRank(frequency.label) < callingRank(kept.label) ? frequency.label : kept.label
                merged[index] = Frequency(label: label, value: RouteRadioPlanner.Station.preferredName(kept.value, frequency.value))
            } else {
                merged.append(frequency)
            }
        }
        var ordered = merged.enumerated().sorted {
            (callingRank($0.element.label), $0.offset) < (callingRank($1.element.label), $1.offset)
        }.map(\.element)
        if let field = ordered.firstIndex(where: { callingRank($0.label) == 2 }) { ordered[field].isFieldContact = true }
        return ordered
    }

    static func frequencies(from lines: String?) -> [Frequency] {
        called((lines ?? "").split(whereSeparator: \.isNewline).compactMap { line in
            let words = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard let label = words.first, !label.isEmpty else { return nil }
            return words.count == 2 ? Frequency(label: label, value: words[1]) : Frequency(label: "", value: label)
        })
    }

    private static func firstLine(of text: String) -> String? {
        AerodromeNote.trimmed(text).split(whereSeparator: \.isNewline).first.map(String.init)
    }
}

// MARK: - The name

/// An aerodrome's name as the card and the search show it (c3 A). The data writes many Swiss and French names in
/// capitals ("BRESSAUCOURT", "LA CHAUX-DE-FONDS"): such a name is shown in title case, its small words kept small
/// after the first ("La Chaux-de-Fonds"). A name the data already writes in mixed case is shown as written.
enum AerodromeName {
    /// Articles and prepositions of the languages the fields are named in, kept small inside a name.
    static let smallWords: Set<String> = [
        "de", "du", "des", "la", "le", "les", "l", "d", "sur", "sous", "en", "et", "aux", "au", "à",
        "am", "im", "an", "auf", "bei", "ob", "der", "die", "das", "von", "zum", "zur",
        "di", "del", "della", "dei", "da", "e", "of", "the", "and",
    ]

    static func display(_ name: String) -> String {
        // A name with a digit in it is closer to a code than a name ("CH-0002"): shown as written.
        guard name.contains(where: \.isLetter), !name.contains(where: \.isLowercase),
              !name.contains(where: \.isNumber) else { return name }
        var result = ""
        var word = ""
        var wordIndex = 0
        func flush() {
            guard !word.isEmpty else { return }
            let lower = word.lowercased()
            if wordIndex > 0, smallWords.contains(lower) {
                result += lower
            } else {
                result += lower.prefix(1).uppercased() + lower.dropFirst()
            }
            word = ""
            wordIndex += 1
        }
        for character in name {
            if character.isLetter || character.isNumber {
                word.append(character)
            } else {
                flush()
                result.append(character)
            }
        }
        flush()
        return result
    }
}

// MARK: - The card

/// The card itself: opaque, in the app's colours and fonts, at the ground's sizes or the Cockpit's in flight
/// (`CalloutMetrics`). Its tail points down at `tailX`, which the anchor sets over the marker.
final class AerodromeCardView: UIView {
    let content: AerodromeCardContent
    private let onAction: (AerodromeCardContent.Action) -> Void
    private let onNotams: (() -> Void)?
    private let shape = CAShapeLayer()
    private let stack = UIStackView()

    static let tailHeight: CGFloat = 10
    static let cornerRadius: CGFloat = 14
    /// The card's widest: on the ground about a third of the iPad's map, in flight more for the Cockpit's sizes.
    static func maxWidth(metrics: CalloutMetrics) -> CGFloat { metrics.target >= 50 ? 520 : 380 }

    /// The tail's middle from the card's left edge; the anchor keeps it over the marker.
    var tailX: CGFloat = 0 {
        didSet { setNeedsLayout() }
    }

    init(content: AerodromeCardContent, metrics: CalloutMetrics, tint: UIColor, width: CGFloat,
         onNotams: (() -> Void)? = nil, onAction: @escaping (AerodromeCardContent.Action) -> Void) {
        self.content = content
        self.onAction = onAction
        self.onNotams = onNotams
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: 0))
        build(metrics: metrics, tint: tint)
        let fitting = stack.systemLayoutSizeFitting(
            CGSize(width: width - 2 * padding(metrics), height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        frame.size.height = ceil(fitting.height) + 2 * padding(metrics) + Self.tailHeight
        tailX = width / 2
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func padding(_ metrics: CalloutMetrics) -> CGFloat { metrics.target >= 50 ? 16 : 12 }

    private func build(metrics: CalloutMetrics, tint: UIColor) {
        let flight = metrics.target >= 50
        let scale: CGFloat = flight ? metrics.fontSize / 15 : 1
        backgroundColor = .clear
        shape.fillColor = UIColor(Color.panelBackground).cgColor
        shape.strokeColor = UIColor.white.withAlphaComponent(0.12).cgColor
        shape.lineWidth = 1
        layer.insertSublayer(shape, at: 0)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.4
        layer.shadowRadius = 14
        layer.shadowOffset = CGSize(width: 0, height: 8)

        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = flight ? 12 : 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let inset = padding(metrics)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -(inset + Self.tailHeight)),
        ])

        // The code large, the name beside it: gold on the ground, the Cockpit's white in flight (c6 A).
        let head = UILabel()
        head.numberOfLines = 2
        let headText = NSMutableAttributedString(string: content.ident, attributes: [
            .font: UIFont.aero(size: 22 * scale, weight: .bold, monospaced: true),
            .foregroundColor: content.inFlight ? UIColor(Color.primaryText) : UIColor(Color.aviationGold)])
        if !content.name.isEmpty, content.name != content.ident {
            headText.append(NSAttributedString(string: "  " + content.name, attributes: [
                .font: UIFont.aero(size: 16 * scale), .foregroundColor: UIColor(Color.primaryText)]))
        }
        head.attributedText = headText
        head.accessibilityIdentifier = "aerodromeCard.head"
        stack.addArrangedSubview(head)

        // Fixed rows, the same on the ground and in flight, a dash where the app has nothing (c1 A).
        stack.addArrangedSubview(rowLabel(content.elevationRow, id: "elevation", scale: scale))
        if content.frequencies.isEmpty {
            stack.addArrangedSubview(rowLabel(AerodromeCardContent.dash, id: "radio", scale: scale))
        } else {
            stack.addArrangedSubview(chips(scale: scale, available: frame.width - 2 * inset))
        }
        stack.addArrangedSubview(rowLabel(content.runwayRow, id: "runways", scale: scale))
        stack.addArrangedSubview(rowLabel(content.weatherRow, id: "weather", scale: scale))
        if let row = content.notamRow {
            stack.addArrangedSubview(notamRow(row, metrics: metrics, tint: tint, scale: scale))
        }
        if !content.note.isEmpty { stack.addArrangedSubview(noteBlock(scale: scale)) }
        if !content.actions.isEmpty {
            stack.addArrangedSubview(buttonRow(metrics: metrics, tint: tint, available: frame.width - 2 * inset))
        }

        isAccessibilityElement = false
        accessibilityIdentifier = "aerodromeCard"
    }

    /// A row of plain facts.
    private func rowLabel(_ text: String, id: String, scale: CGFloat) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.font = UIFont.aero(size: 14 * scale, monospaced: true)
        label.textColor = UIColor(Color.primaryText)
        label.text = text
        label.accessibilityIdentifier = "aerodromeCard.\(id)"
        return label
    }

    /// The frequencies as chips, as many to a row as fit, in calling order, the field's own framed (c2 A).
    private func chips(scale: CGFloat, available: CGFloat) -> UIView {
        let font = UIFont.aero(size: 13 * scale, monospaced: true)
        let rows = UIStackView()
        rows.axis = .vertical
        rows.alignment = .leading
        rows.spacing = 6
        var row = UIStackView()
        var used: CGFloat = 0
        func newRow() {
            row = UIStackView()
            row.axis = .horizontal
            row.spacing = 6
            rows.addArrangedSubview(row)
            used = 0
        }
        newRow()
        for frequency in content.frequencies {
            let label = PaddedLabel()
            let text = NSMutableAttributedString()
            if !frequency.label.isEmpty {
                text.append(NSAttributedString(string: frequency.label + " ", attributes: [
                    .font: font, .foregroundColor: UIColor(Color.secondaryText)]))
            }
            text.append(NSAttributedString(string: frequency.value, attributes: [
                .font: font, .foregroundColor: UIColor(Color.primaryText)]))
            label.attributedText = text
            label.backgroundColor = UIColor(Color.cardBackground)
            label.layer.cornerRadius = 7
            label.clipsToBounds = true
            if frequency.isFieldContact {
                label.layer.borderWidth = 1.5
                label.layer.borderColor = UIColor(Color.primaryText).cgColor
            }
            let width = label.intrinsicContentSize.width
            if used > 0, used + 6 + width > available { newRow() }
            row.addArrangedSubview(label)
            used += (used > 0 ? 6 : 0) + width
        }
        return rows
    }

    /// The field's NOTAMs in one row, a tap reads them: gold on the ground, cyan in flight, where gold reads as a caution
    /// and anything touchable is cyan. As tall as the surface's touch target.
    private func notamRow(_ row: (count: String, text: String), metrics: CalloutMetrics, tint: UIColor, scale: CGFloat) -> UIView {
        let mark = content.inFlight ? tint : UIColor(Color.aviationGold)
        let count = UILabel()
        count.font = UIFont.aero(size: 13 * scale, weight: .bold)
        count.textColor = mark
        count.text = row.count
        count.setContentHuggingPriority(.required, for: .horizontal)
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        let text = UILabel()
        text.font = UIFont.aero(size: 13 * scale, monospaced: true)
        text.textColor = UIColor(Color.primaryText)
        text.numberOfLines = 2
        text.lineBreakMode = .byTruncatingTail
        text.text = row.text
        let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
        chevron.tintColor = UIColor(Color.dimText)
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.setContentCompressionResistancePriority(.required, for: .horizontal)
        let line = UIStackView(arrangedSubviews: [count, text, chevron])
        line.axis = .horizontal
        line.alignment = .center
        line.spacing = 8 * scale
        line.isUserInteractionEnabled = false
        line.translatesAutoresizingMaskIntoConstraints = false
        // A button, never a plain control: UIKit keeps the map's own tap off a button, and on a plain control that tap took
        // the touch, closed the card and read nothing.
        let control = UIButton(primaryAction: UIAction { [weak self] _ in self?.onNotams?() })
        control.layer.cornerRadius = 8
        control.layer.borderWidth = 1
        control.layer.borderColor = UIColor(Color.dimText).cgColor
        control.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: control.leadingAnchor, constant: 9),
            line.trailingAnchor.constraint(equalTo: control.trailingAnchor, constant: -9),
            line.topAnchor.constraint(equalTo: control.topAnchor, constant: 5),
            line.bottomAnchor.constraint(equalTo: control.bottomAnchor, constant: -5),
            control.heightAnchor.constraint(greaterThanOrEqualToConstant: metrics.target),
        ])
        control.isAccessibilityElement = true
        control.accessibilityTraits = .button
        control.accessibilityLabel = "\(row.count), \(row.text)"
        control.accessibilityIdentifier = "aerodromeCard.notams"
        return control
    }

    /// The note's mark: gold on the ground, grey in flight, where gold reads as a caution (c6 A).
    private var noteMark: UIColor { content.inFlight ? UIColor(Color.secondaryText) : UIColor(Color.aviationGold) }

    /// The note under a rule, each part's name inline before its text.
    private func noteBlock(scale: CGFloat) -> UIView {
        let lines = UIStackView()
        lines.axis = .vertical
        lines.spacing = 4
        for line in content.note {
            let label = UILabel()
            label.numberOfLines = line.maxLines
            label.lineBreakMode = .byTruncatingTail
            let title = line.part == .arrival ? L10n.AerodromeNotes.arrival : L10n.AerodromeNotes.onTheGround
            let text = NSMutableAttributedString(string: title.uppercased() + "  ", attributes: [
                .font: UIFont.aero(size: 11 * scale, weight: .bold, monospaced: true), .kern: 0.8,
                .foregroundColor: noteMark])
            text.append(NSAttributedString(string: line.text, attributes: [
                .font: UIFont.aero(size: 14 * scale), .foregroundColor: UIColor(Color.primaryText)]))
            label.attributedText = text
            label.accessibilityIdentifier = "aerodromeCard.note.\(line.part == .arrival ? "arrival" : "onTheGround")"
            lines.addArrangedSubview(label)
        }
        let rule = UIView()
        rule.backgroundColor = noteMark
        rule.layer.cornerRadius = 1.5
        rule.widthAnchor.constraint(equalToConstant: 3).isActive = true
        let block = UIStackView(arrangedSubviews: [rule, lines])
        block.axis = .horizontal
        block.alignment = .fill
        block.spacing = 9 * scale
        return block
    }

    static let buttonSpacing: CGFloat = 8
    /// A button's room around its symbol and title.
    static let buttonInsets: CGFloat = 12
    static let symbolGap: CGFloat = 6

    /// Whether the row's symbols go above their words: when one word doesn't fit beside its symbol in its share
    /// of the row ("Déroutement" on the phone's Cockpit, three buttons across). Every button the same, so the row
    /// reads as one.
    static func stacksSymbols(titles: [String], font: UIFont, symbolSize: CGFloat, rowWidth: CGFloat) -> Bool {
        guard !titles.isEmpty else { return false }
        let share = (rowWidth - buttonSpacing * CGFloat(titles.count - 1)) / CGFloat(titles.count)
        return titles.contains { title in
            let word = (title as NSString).size(withAttributes: [.font: font]).width
            return word + symbolSize + symbolGap + buttonInsets > share
        }
    }

    /// The buttons in one row of equal width, as tall as the surface's touch target.
    private func buttonRow(metrics: CalloutMetrics, tint: UIColor, available: CGFloat) -> UIView {
        let stacked = Self.stacksSymbols(titles: content.actions.map(Self.title(for:)),
                                         font: UIFont.aero(size: metrics.fontSize, weight: .semibold),
                                         symbolSize: metrics.fontSize + 4, rowWidth: available)
        let row = UIStackView(arrangedSubviews: content.actions.map {
            button(for: $0, metrics: metrics, tint: tint, stacked: stacked)
        })
        row.axis = .horizontal
        row.distribution = .fillEqually
        row.spacing = Self.buttonSpacing
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: metrics.target).isActive = true
        return row
    }

    static func title(for action: AerodromeCardContent.Action) -> String {
        switch action {
        case .chart: return L10n.OfficialChart.short
        case .note: return L10n.AerodromeNotes.cardButton
        // The verb, as on the Cockpit's own Divert button: French "Dérouter" fits, "Déroutement" was cut (r2-11).
        case .divert: return L10n.Act.divert
        case .addToRoute: return L10n.Nav.addToRouteShort
        case .fees: return L10n.Nav.cardFees
        case .briefing: return L10n.Nav.cardBriefing
        }
    }

    private func button(for action: AerodromeCardContent.Action, metrics: CalloutMetrics, tint: UIColor,
                        stacked: Bool) -> UIButton {
        var configuration: UIButton.Configuration
        let symbol: String
        let label: String
        switch action {
        case .chart(let link):
            configuration = .plain()
            configuration.background.strokeColor = tint
            configuration.background.strokeWidth = 1.5
            symbol = link.symbolName
            label = link.title
        case .note(let existing):
            configuration = .tinted()
            symbol = existing ? "note.text" : "square.and.pencil"
            label = existing ? L10n.AerodromeNotes.yourNote : L10n.AerodromeNotes.add
        case .divert:
            configuration = .filled()
            // The Cockpit's own Divert in flight: cyan, amber while diverting. Gold on the ground (c6 A).
            configuration.baseBackgroundColor = content.inFlight
                ? (content.isDiverting ? UIColor(CockpitTheme.day.warning) : tint)
                : UIColor(red: 0.898, green: 0.655, blue: 0.227, alpha: 1.0)
            symbol = "arrow.triangle.turn.up.right.diamond.fill"
            label = L10n.Trip.divert
        case .addToRoute:
            configuration = .tinted()
            symbol = "plus"
            label = L10n.Nav.addToRoute
        case .fees:
            configuration = .tinted()
            symbol = "banknote"
            label = L10n.Nav.cardFees
        case .briefing:
            configuration = .tinted()
            symbol = "doc.text"
            label = L10n.Nav.cardBriefing
        }
        configuration.title = Self.title(for: action)
        configuration.image = UIImage(systemName: symbol)
        configuration.imagePlacement = stacked ? .top : .leading
        configuration.imagePadding = stacked ? 2 : Self.symbolGap
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            pointSize: metrics.fontSize - 1, weight: .semibold)
        configuration.cornerStyle = .medium
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: Self.buttonInsets / 2, bottom: 4,
                                                              trailing: Self.buttonInsets / 2)
        configuration.titleLineBreakMode = .byTruncatingTail
        if case .divert = action {
            configuration.baseForegroundColor = UIColor(red: 0.10, green: 0.08, blue: 0.03, alpha: 1)
        } else {
            configuration.baseForegroundColor = tint
            if case .chart = action {} else { configuration.baseBackgroundColor = tint }
        }
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.aero(size: metrics.fontSize, weight: .semibold)
            return attributes
        }
        let button = AerodromeCardButton(configuration: configuration,
                                         primaryAction: UIAction { [weak self] _ in self?.onAction(action) })
        button.action = action
        button.accessibilityIdentifier = action.identifier
        button.accessibilityLabel = label
        if case .chart(let link) = action {
            button.accessibilityHint = link.accessibilityHint
            button.accessibilityTraits = .link
        }
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: metrics.target).isActive = true
        return button
    }

    /// The card's buttons, in the row's order.
    var buttons: [AerodromeCardButton] {
        func all(_ view: UIView) -> [UIView] { view.subviews + view.subviews.flatMap(all) }
        return all(self).compactMap { $0 as? AerodromeCardButton }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let body = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - Self.tailHeight)
        let path = UIBezierPath(roundedRect: body, cornerRadius: Self.cornerRadius)
        let x = min(max(tailX, Self.cornerRadius + Self.tailHeight), bounds.width - Self.cornerRadius - Self.tailHeight)
        let tail = UIBezierPath()
        tail.move(to: CGPoint(x: x - Self.tailHeight, y: body.maxY - 0.5))
        tail.addLine(to: CGPoint(x: x, y: bounds.height))
        tail.addLine(to: CGPoint(x: x + Self.tailHeight, y: body.maxY - 0.5))
        tail.close()
        path.append(tail)
        shape.frame = bounds
        shape.path = path.cgPath
        layer.shadowPath = path.cgPath
    }
}

/// A button of the card, which says what it does (the tests and the anchor read it).
final class AerodromeCardButton: UIButton {
    fileprivate(set) var action: AerodromeCardContent.Action?
}

/// A label with room around its text: a frequency's chip.
private final class PaddedLabel: UILabel {
    private let insets = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)

    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: insets)) }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + insets.left + insets.right, height: size.height + insets.top + insets.bottom)
    }
}

extension AerodromeFacts {
    /// What the card says of a field, from what the app already holds: nothing here fetches. The map and the route builder
    /// share it; until 6.10.0 the builder's card had none of it and showed a dash on every row (device check n-7).
    /// - Parameters:
    ///   - planMap: Plan › Map's links, after the note (c5 A).
    ///   - dryRun: no NOTAMs in a dry run.
    @MainActor
    static func onDevice(_ airport: Airport, airports: AirportDataService, observations: [AviationWeatherService.Metar], planMap: Bool,
                         dryRun: Bool) -> AerodromeFacts {
        var facts = AerodromeFacts()
        facts.isPPR = OpenAIPAirportDataService.shared.pprIcaoCodes.contains(airport.ident)
        facts.runways = runwayLines(airports.getRunways(for: airport.ident))
        facts.circuit = circuitText(OFMDataService.shared.procedures(forAerodrome: airport.ident)
            .filter { $0.kind == .circuit && $0.categories.contains(.powered) }.compactMap(\.altitudeFt))
        facts.weather = observations.first { $0.icao == airport.ident }
            .flatMap { weatherLine($0, now: FlightClock.now) }
        if planMap {
            facts.feeLink = AirfieldTariffService.shared.tariff(for: airport.ident).flatMap { URL(string: $0.url) }
            facts.briefingLink = BriefingRegistryService.shared.registry?.country(airport.isoCountry)?.notam.first?.url
        }
        // What's on the device, on the ground and in flight, never in a dry run.
        if !dryRun { facts.notams = NotamService.shared.notams(at: airport.ident) }
        return facts
    }
}
