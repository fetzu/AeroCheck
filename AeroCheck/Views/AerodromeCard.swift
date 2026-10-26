import SwiftUI
import UIKit

// MARK: - An aerodrome's card on the map (6.7.0, the author's answers c1 A, c2 A, c3 A)
//
// The author's device check n-2: MapKit's bubble read badly (two kinds of button, five sizes, the note cut after a
// line). An aerodrome's marker opens the app's own card instead: the code large, the name, the frequencies, the
// pilot's note, and one row of buttons of equal width. The card knows nothing of the map it sits on: what it holds is
// `AerodromeCardContent`, how it looks is `AerodromeCardView`, and the map's own anchor places it over the marker
// (`AerodromeMarkerView` on MapKit), so the move to MapLibre (6.8.0) keeps the card and changes only the anchor.

/// What an aerodrome's card holds, decided from the field, the pilot's note and what the map surface offers.
struct AerodromeCardContent: Equatable {
    struct Frequency: Equatable {
        let label: String
        let value: String
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

        var identifier: String {
            switch self {
            case .chart: return "aerodromeCard.chart"
            case .note: return "aerodromeCard.note"
            case .divert: return "aerodromeCard.divert"
            case .addToRoute: return "aerodromeCard.addToRoute"
            }
        }
    }

    let ident: String
    let name: String
    let frequencies: [Frequency]
    let note: [NoteLine]
    let actions: [Action]

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
                     chart: OfficialChartLink?, canOpenNote: Bool, canDivert: Bool, canAddToRoute: Bool) -> Self {
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
        return Self(ident: airport.ident, name: AerodromeName.display(airport.name),
                    frequencies: frequencies(from: frequencyLines), note: lines, actions: actions)
    }

    static func frequencies(from lines: String?) -> [Frequency] {
        (lines ?? "").split(whereSeparator: \.isNewline).compactMap { line in
            let words = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard let label = words.first, !label.isEmpty else { return nil }
            return words.count == 2 ? Frequency(label: label, value: words[1]) : Frequency(label: "", value: label)
        }
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
         onAction: @escaping (AerodromeCardContent.Action) -> Void) {
        self.content = content
        self.onAction = onAction
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

        // The code large and gold, the name beside it.
        let head = UILabel()
        head.numberOfLines = 2
        let headText = NSMutableAttributedString(string: content.ident, attributes: [
            .font: UIFont.aero(size: 22 * scale, weight: .bold, monospaced: true),
            .foregroundColor: UIColor(Color.aviationGold)])
        if !content.name.isEmpty, content.name != content.ident {
            headText.append(NSAttributedString(string: "  " + content.name, attributes: [
                .font: UIFont.aero(size: 16 * scale), .foregroundColor: UIColor(Color.primaryText)]))
        }
        head.attributedText = headText
        head.accessibilityIdentifier = "aerodromeCard.head"
        stack.addArrangedSubview(head)

        if !content.frequencies.isEmpty { stack.addArrangedSubview(chips(scale: scale, available: frame.width - 2 * inset)) }
        if !content.note.isEmpty { stack.addArrangedSubview(noteBlock(scale: scale)) }
        if !content.actions.isEmpty {
            stack.addArrangedSubview(buttonRow(metrics: metrics, tint: tint, available: frame.width - 2 * inset))
        }

        isAccessibilityElement = false
        accessibilityIdentifier = "aerodromeCard"
    }

    /// The frequencies as chips, as many to a row as fit, in the order the data gives them.
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
            let width = label.intrinsicContentSize.width
            if used > 0, used + 6 + width > available { newRow() }
            row.addArrangedSubview(label)
            used += (used > 0 ? 6 : 0) + width
        }
        return rows
    }

    /// The note under a gold rule, each part's name inline before its text.
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
                .foregroundColor: UIColor(Color.aviationGold)])
            text.append(NSAttributedString(string: line.text, attributes: [
                .font: UIFont.aero(size: 14 * scale), .foregroundColor: UIColor(Color.primaryText)]))
            label.attributedText = text
            label.accessibilityIdentifier = "aerodromeCard.note.\(line.part == .arrival ? "arrival" : "onTheGround")"
            lines.addArrangedSubview(label)
        }
        let rule = UIView()
        rule.backgroundColor = UIColor(Color.aviationGold)
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
            configuration.baseBackgroundColor = UIColor(red: 0.898, green: 0.655, blue: 0.227, alpha: 1.0)
            symbol = "arrow.triangle.turn.up.right.diamond.fill"
            label = L10n.Trip.divert
        case .addToRoute:
            configuration = .tinted()
            symbol = "plus"
            label = L10n.Nav.addToRoute
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
