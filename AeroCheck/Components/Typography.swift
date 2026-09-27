import SwiftUI
import UIKit

// MARK: - Typeface (v6.0)
//
// B612 throughout the app: the typeface Airbus designed with ENAC and Intactile DESIGN for cockpit
// displays, drawn to keep look-alike characters apart (0/O, 1/l/I, 5/S, 8/B) at small sizes and in
// poor light. Open source, SIL Open Font License 1.1 (bundled as `OFL-B612.txt`).
//
// Each family has two weights, Regular and Bold: SwiftUI's lighter weights (up to medium) map to
// Regular, semibold and heavier to Bold. `.monospaced` maps to B612 Mono. The widget and the Watch
// app keep the system font; the font files ship in the app bundle only.
//
// `Font.aero` mirrors `Font.system` label for label, so a view swaps one for the other without any
// other change: fixed sizes stay fixed, text styles scale with Dynamic Type.

enum AeroTypeface {
    static let regular = "B612-Regular"
    static let bold = "B612-Bold"
    static let monoRegular = "B612Mono-Regular"
    static let monoBold = "B612Mono-Bold"

    static func name(bold isBold: Bool, monospaced: Bool) -> String {
        if monospaced { return isBold ? monoBold : monoRegular }
        return isBold ? bold : regular
    }

    static func isBold(_ weight: Font.Weight?) -> Bool {
        guard let weight else { return false }
        return [Font.Weight.semibold, .bold, .heavy, .black].contains(weight)
    }

    /// The point size of each text style at the default (Large) content size; `relativeTo:` scales it.
    static func size(of style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: return 34
        case .title: return 28
        case .title2: return 22
        case .title3: return 20
        case .headline: return 17
        case .subheadline: return 15
        case .body: return 17
        case .callout: return 16
        case .footnote: return 13
        case .caption: return 12
        case .caption2: return 11
        @unknown default: return 17
        }
    }
}

extension Font {
    /// B612 at a fixed size: the drop-in for `.system(size:weight:design:)`.
    static func aero(size: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil) -> Font {
        .custom(AeroTypeface.name(bold: AeroTypeface.isBold(weight), monospaced: design == .monospaced),
                fixedSize: size)
    }

    /// B612 for a text style, scaling with Dynamic Type: the drop-in for `.system(_:design:weight:)`.
    /// A headline is bold, as the system's is.
    static func aero(_ style: Font.TextStyle, design: Font.Design? = nil, weight: Font.Weight? = nil) -> Font {
        let bold = weight.map(AeroTypeface.isBold) ?? (style == .headline)
        return .custom(AeroTypeface.name(bold: bold, monospaced: design == .monospaced),
                       size: AeroTypeface.size(of: style), relativeTo: style)
    }
}

/// Which in-flight scale this device reads at. The scale is physical, so it follows the device, not
/// the window: a phone point is 0.166 mm (iPhone 17, 460 ppi at 3×), an iPad Air point 0.192 mm (264 ppi
/// at 2×), and a phone is read closer, in the hand or on a yoke clip at about 40 cm rather than a
/// kneeboard's 55. The phone's sizes are the iPad's × 0.85, the same angle at the eye. (iPhone pass, I6)
enum CockpitScale: Equatable {
    case kneeboard
    case phone

    static let current: CockpitScale = UIDevice.current.userInterfaceIdiom == .phone ? .phone : .kneeboard
}

/// The in-flight type scale. On the iPad, sized for a kneeboard read from about 55 cm: FAA HFDS asks
/// for a cap height of at least 1/200 of the viewing distance (about 2.75 mm, 20 pt on an iPad Air)
/// and prefers 1/167 (about 3.3 mm, 24 pt). On the phone, the same angles from about 40 cm
/// (`CockpitScale`). Anything read in flight uses one of these. (v6.0 · P6)
enum CockpitType {
    /// Secondary labels: units, captions, counters, hints.
    static var label: CGFloat { size(kneeboard: 20, phone: 17) }
    /// Checklist rows and list rows.
    static var row: CGFloat { size(kneeboard: 24, phone: 20) }
    /// The current checklist item's response.
    static var response: CGFloat { size(kneeboard: 28, phone: 24) }
    /// Labels of the buttons in the thumb bar.
    static var button: CGFloat { size(kneeboard: 30, phone: 25) }
    /// The current checklist item's challenge.
    static var item: CGFloat { size(kneeboard: 42, phone: 36) }
    /// Instrument values: speed, altitude, track. 36 on the phone rather than 41: three values across
    /// its width, "10500" among them, set the limit.
    static var value: CGFloat { size(kneeboard: 48, phone: 36) }

    static func size(kneeboard: CGFloat, phone: CGFloat, scale: CockpitScale = .current) -> CGFloat {
        scale == .phone ? phone : kneeboard
    }
}

/// Touch targets in flight, from the same yardsticks: an EFB control wants about 15 mm (78 pt on an
/// iPad Air), a critical one about 20 mm (104 pt, Avsar et al.). The phone's thumb bar keeps the 15 mm
/// (92 pt); 20 mm would take the checklist's room. (v6.0 · P6, iPhone pass I6)
enum CockpitTarget {
    /// The thumb bar: CHECK, MARK and their neighbours.
    static var thumb: CGFloat { CockpitType.size(kneeboard: 104, phone: 92) }
    /// Controls over the map: Map, orientation, centre, zoom. Short enough to leave the map visible.
    static var control: CGFloat { CockpitType.size(kneeboard: 64, phone: 50) }
}

extension Font {
    /// B612 at `size` at the default text size, scaling with Dynamic Type like `style` does.
    static func aero(size: CGFloat, relativeTo style: Font.TextStyle, weight: Font.Weight? = nil,
                     design: Font.Design? = nil) -> Font {
        .custom(AeroTypeface.name(bold: AeroTypeface.isBold(weight), monospaced: design == .monospaced),
                size: size, relativeTo: style)
    }
}

extension UIFont {
    /// B612 for the UIKit parts: map labels, navigation bars, segmented controls.
    static func aero(size: CGFloat, weight: UIFont.Weight = .regular, monospaced: Bool = false) -> UIFont {
        let name = AeroTypeface.name(bold: weight >= .semibold, monospaced: monospaced)
        return UIFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }
}

enum AeroAppearance {
    /// The UIKit chrome SwiftUI draws with UIKit controls: navigation bar titles, bar buttons,
    /// segmented pickers and tab bar labels. Call once, at launch.
    static func apply() {
        UINavigationBar.appearance().titleTextAttributes = [.font: UIFont.aero(size: 17, weight: .bold)]
        UINavigationBar.appearance().largeTitleTextAttributes = [.font: UIFont.aero(size: 34, weight: .bold)]
        UIBarButtonItem.appearance().setTitleTextAttributes([.font: UIFont.aero(size: 17)], for: .normal)
        UISegmentedControl.appearance().setTitleTextAttributes([.font: UIFont.aero(size: 14)], for: .normal)
        UISegmentedControl.appearance().setTitleTextAttributes([.font: UIFont.aero(size: 14, weight: .bold)],
                                                             for: .selected)
        UITabBarItem.appearance().setTitleTextAttributes([.font: UIFont.aero(size: 11)], for: .normal)
    }
}
