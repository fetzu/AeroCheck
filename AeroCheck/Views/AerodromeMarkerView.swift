import MapKit
import UIKit

// MARK: - The aerodrome card's anchor on MapKit (6.7.0, c1 A)
//
// MapKit draws an aerodrome's marker; the marker's view hosts the app's card (`AerodromeCardView`) above itself, so
// the card moves with the marker as the map pans and zooms, and a touch on it is the marker's (MapKit keeps the
// marker selected) rather than the map's. The only MapKit in the card's life: 6.8.0's MapLibre anchors the same card.

/// An aerodrome's marker, which shows its card while selected. MapKit's own callout is off (`canShowCallout`).
final class AerodromeMarkerView: MKAnnotationView {
    private(set) var card: AerodromeCardView?
    /// When a touch last landed on the card. MapKit takes a tap on the card's body for a tap on the map and
    /// deselects the marker; the map's coordinator keeps the card open when the deselect follows such a touch.
    private var cardTouchedAt: Date?

    /// The card was touched just now: a deselect this soon is MapKit's reading of that touch, not the pilot's.
    func cardWasJustTouched(now: Date = Date()) -> Bool {
        guard card != nil, let cardTouchedAt else { return false }
        return now.timeIntervalSince(cardTouchedAt) < 0.6
    }

    /// Between the marker's top and the card's tail.
    static let gap: CGFloat = 4
    /// The card's least distance from the map's edges.
    static let edge: CGFloat = 12

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        canShowCallout = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Shows `card` over the marker, in place of any before it.
    func show(_ card: AerodromeCardView, on mapView: MKMapView) {
        hideCard()
        self.card = card
        addSubview(card)
        place(card, on: mapView, moving: false)
        // Selected right after a camera jump (a search), the marker is placed a turn later: the card follows, and
        // only then may the map move for it.
        DispatchQueue.main.async { [weak self, weak card, weak mapView] in
            guard let self, let card, let mapView, self.card === card else { return }
            self.place(card, on: mapView, moving: true)
        }
        // VoiceOver reads the card's name and buttons, not the marker under it.
        isAccessibilityElement = false
        UIAccessibility.post(notification: .layoutChanged, argument: card)
    }

    func hideCard() {
        guard let card else { return }
        card.removeFromSuperview()
        self.card = nil
        cardTouchedAt = nil
        isAccessibilityElement = true
    }

    /// Over the marker with its tail on it, moved sideways to stay inside the map. With `moving`, a card that would
    /// leave the map at the top moves the map down until it fits, as MapKit's bubble did.
    func place(_ card: AerodromeCardView, on mapView: MKMapView, moving: Bool) {
        let area = Self.area(of: mapView)
        let anchor = convert(CGPoint(x: bounds.midX, y: bounds.minY), to: mapView)
        let frame = Self.frame(for: card.bounds.size, over: anchor, in: area)
        card.tailX = anchor.x - frame.minX
        card.frame = CGRect(origin: convert(frame.origin, from: mapView), size: frame.size)
        let shortfall = Self.shortfall(of: frame, anchor: anchor, in: area)
        guard moving, shortfall > 0 else { return }
        let center = mapView.convert(mapView.centerCoordinate, toPointTo: mapView)
        mapView.setCenter(mapView.convert(CGPoint(x: center.x, y: center.y - shortfall), toCoordinateFrom: mapView),
                          animated: true)
    }

    /// Where a card may sit: the map inside its safe area, `edge` from every side.
    static func area(of mapView: MKMapView) -> CGRect {
        mapView.bounds.inset(by: mapView.safeAreaInsets).insetBy(dx: edge, dy: edge)
    }

    /// The card's frame in the map: centred over `anchor` (the marker's top), kept inside `area` sideways.
    static func frame(for size: CGSize, over anchor: CGPoint, in area: CGRect) -> CGRect {
        let left = min(max(anchor.x - size.width / 2, area.minX), max(area.minX, area.maxX - size.width))
        return CGRect(x: left, y: anchor.y - gap - size.height, width: size.width, height: size.height)
    }

    /// How far the map moves down so a card leaving `area` at the top fits: never so far that the marker leaves it
    /// at the bottom.
    static func shortfall(of frame: CGRect, anchor: CGPoint, in area: CGRect) -> CGFloat {
        // A marker off the map (not placed yet, or panned away) moves nothing.
        guard area.contains(anchor) else { return 0 }
        let wanted = area.minY - frame.minY
        guard wanted > 0 else { return 0 }
        return max(0, min(wanted, area.maxY - 24 - anchor.y))
    }

    // A touch on the card is the marker's: its buttons answer, and MapKit keeps the marker selected.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if let card, card.frame.contains(point) { return true }
        return super.point(inside: point, with: event)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let card, card.frame.contains(point) {
            cardTouchedAt = Date()
            return card.hitTest(convert(point, to: card), with: event) ?? card
        }
        return super.hitTest(point, with: event)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        hideCard()
    }
}
