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
