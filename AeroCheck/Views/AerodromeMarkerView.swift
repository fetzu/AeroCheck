import UIKit

// MARK: - Where a marker's card or callout sits (6.7.0, c1 A)
//
// An aerodrome's card (`AerodromeCardView`) and the other markers' callouts (`PilotMarkerBubble`) sit over their
// marker with the tail on it, moved sideways to stay inside the map (`PilotMarkerCallout`). Until 6.8.0 a MapKit
// marker view hosted the card; the geometry stayed. (6.8.0)

/// A callout's place over its marker, inside the map.
enum CalloutPlacement {
    /// Between the marker's top and the callout's tail.
    static let gap: CGFloat = 4
    /// The callout's least distance from the map's edges.
    static let edge: CGFloat = 12

    /// The callout's frame in the map: centred over `anchor` (the marker's top), kept inside `area` sideways.
    static func frame(for size: CGSize, over anchor: CGPoint, in area: CGRect) -> CGRect {
        let left = min(max(anchor.x - size.width / 2, area.minX), max(area.minX, area.maxX - size.width))
        return CGRect(x: left, y: anchor.y - gap - size.height, width: size.width, height: size.height)
    }

    /// How far the map moves down so a callout leaving `area` at the top fits: never so far that the marker leaves it
    /// at the bottom.
    static func shortfall(of frame: CGRect, anchor: CGPoint, in area: CGRect) -> CGFloat {
        // A marker off the map (not placed yet, or panned away) moves nothing.
        guard area.contains(anchor) else { return 0 }
        let wanted = area.minY - frame.minY
        guard wanted > 0 else { return 0 }
        return max(0, min(wanted, area.maxY - 24 - anchor.y))
    }
}
