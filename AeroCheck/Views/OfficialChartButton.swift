import SwiftUI
import UIKit
import MapKit

// MARK: - Sizes

/// How big a map callout's controls are: 44 pt on the ground; in flight the Cockpit's map-control size
/// (64 pt on the kneeboard, 50 on the phone) with the in-flight label size, since the callout is
/// touched and read over the Cockpit's MAP. (6.2.0)
struct CalloutMetrics: Equatable {
    /// The side of an accessory, the height of a button.
    let target: CGFloat
    /// A button's title.
    let fontSize: CGFloat
    /// The word under an accessory's symbol.
    let captionSize: CGFloat
    /// A callout's buttons side by side, each a symbol and a short word, rather than one above the other:
    /// on the phone's Cockpit MAP the stacked ones made the callout about as tall as the chart.
    var sideBySide = false

    static let ground = CalloutMetrics(target: 44, fontSize: 15, captionSize: 11)
    static var flight: CalloutMetrics { flight(.current) }

    static func flight(_ scale: CockpitScale) -> CalloutMetrics {
        CalloutMetrics(target: CockpitTarget.control(scale), fontSize: CockpitType.label(scale),
                       captionSize: CockpitType.label(scale), sideBySide: scale == .phone)
    }

    static func metrics(inFlight: Bool) -> CalloutMetrics { inFlight ? .flight : .ground }
}

// MARK: - UIKit: map callouts

/// The official chart in a map callout. It carries its link, so a callout's tap handler can tell it
/// from the callout's other control (Divert, the builder's "+"): MapKit reports every accessory tap
/// through the one delegate method. (6.2.0)
final class OfficialChartControl: UIButton {
    private(set) var link: OfficialChartLink?

    /// An airport callout's left accessory: the symbol over "Chart", at least `metrics.target` square.
    /// No action of its own: MapKit sends its taps to `calloutAccessoryControlTapped`.
    static func accessory(link: OfficialChartLink, metrics: CalloutMetrics, tint: UIColor) -> OfficialChartControl {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: link.symbolName)
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            pointSize: metrics.captionSize + 6, weight: .semibold)
        configuration.imagePlacement = .top
        configuration.imagePadding = 2
        configuration.title = L10n.OfficialChart.short
        configuration.baseForegroundColor = tint
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 2, bottom: 2, trailing: 2)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.aero(size: metrics.captionSize, weight: .semibold)
            return attributes
        }
        let control = OfficialChartControl(configuration: configuration)
        control.link = link
        let fitting = control.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        control.frame = CGRect(x: 0, y: 0, width: max(metrics.target, fitting.width),
                               height: max(metrics.target, fitting.height))
        control.describe(link)
        return control
    }

    /// A row of a callout's detail (the VFR procedure's): "Official chart" with its symbol, and the
    /// subscription under it for SkyBriefing, at least `metrics.target` tall. It opens `link` itself.
    /// Side by side (`metrics.sideBySide`), its title is the short "Chart" over "Subscription" for
    /// SkyBriefing (the symbol is a lock); VoiceOver still reads the whole title.
    static func action(link: OfficialChartLink, metrics: CalloutMetrics, tint: UIColor,
                       open: @escaping (URL) -> Void) -> OfficialChartControl {
        var configuration = UIButton.Configuration.tinted()
        configuration.title = metrics.sideBySide ? L10n.OfficialChart.short : L10n.OfficialChart.title
        configuration.subtitle = metrics.sideBySide && link.requiresLogin ? L10n.OfficialChart.subscriptionShort : link.note
        configuration.image = UIImage(systemName: link.symbolName)
        configuration.imagePadding = 6
        configuration.baseForegroundColor = tint
        configuration.baseBackgroundColor = tint
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.aero(size: metrics.fontSize, weight: .semibold)
            return attributes
        }
        configuration.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.aero(size: max(13, metrics.fontSize - 3))
            return attributes
        }
        let control = OfficialChartControl(configuration: configuration, primaryAction: UIAction { _ in open(link.url) })
        control.link = link
        control.heightAnchor.constraint(greaterThanOrEqualToConstant: metrics.target).isActive = true
        control.describe(link)
        return control
    }

    private func describe(_ link: OfficialChartLink) {
        isAccessibilityElement = true
        accessibilityLabel = link.title
        accessibilityHint = link.accessibilityHint
        accessibilityTraits = .link
    }
}

/// The two controls of an airport's callout on the nav maps (Plan › Map and the Cockpit's MAP): the
/// official chart on the left, "Divert here" on the right in flight. Both maps share them, and the tap
/// handler asks `action(for:)` which one it was: before 6.2.0 any control meant Divert.
enum AirportCalloutControls {
    enum Action: Equatable {
        case officialChart(URL)
        case divert(String)
    }

    /// - Parameters:
    ///   - chart: the field's official chart, nil when it has none (or the map can't open one).
    ///   - divert: whether the callout offers Divert (in flight, with a route).
    @MainActor
    static func configure(_ view: MKAnnotationView, chart: OfficialChartLink?, divert: Bool,
                          metrics: CalloutMetrics, tint: UIColor) {
        view.leftCalloutAccessoryView = chart.map { OfficialChartControl.accessory(link: $0, metrics: metrics, tint: tint) }
        view.rightCalloutAccessoryView = divert ? divertButton(metrics: metrics) : nil
    }

    /// "Divert here": opens the Divert sheet on this field, where the time, runway and the big button
    /// are. (v5.1)
    @MainActor
    private static func divertButton(metrics: CalloutMetrics) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "arrow.triangle.turn.up.right.diamond.fill",
                                withConfiguration: UIImage.SymbolConfiguration(pointSize: metrics.target * 0.45)),
                        for: .normal)
        button.tintColor = UIColor(red: 0.898, green: 0.655, blue: 0.227, alpha: 1.0)
        button.frame = CGRect(x: 0, y: 0, width: metrics.target, height: metrics.target)
        button.accessibilityLabel = L10n.Trip.divert
        return button
    }

    /// What a tap on `control` asks for: the chart when it is the chart, otherwise Divert.
    @MainActor
    static func action(for control: UIControl, airport: Airport) -> Action {
        if let chart = control as? OfficialChartControl, let link = chart.link {
            return .officialChart(link.url)
        }
        return .divert(airport.ident)
    }
}

// MARK: - SwiftUI: the Divert sheet and the briefing

/// The official chart as an in-flight button, outlined in the action colour: it leaves the app for the
/// publisher's page (in the browser), where the filled buttons around it stay in the app. (6.2.0)
struct OfficialChartButton: View {
    @Environment(\.cockpitTheme) private var theme
    @Environment(\.openURL) private var openURL
    let link: OfficialChartLink
    var minHeight: CGFloat = CockpitTarget.control

    var body: some View {
        Button { openURL(link.url) } label: {
            HStack(spacing: 10) {
                Image(systemName: link.symbolName)
                Text(link.title)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.right")
                    .font(.aero(size: CockpitType.label - 4, weight: .semibold))
            }
            .font(.aero(size: CockpitType.label, weight: .semibold))
            .foregroundColor(theme.action)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.action, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(link.title)
        .accessibilityHint(link.accessibilityHint)
        .accessibilityAddTraits(.isLink)
    }
}

/// The official-chart button of an aerodrome, or nothing when it has none. Follows the registry, so
/// the button turns up when the file arrives.
struct OfficialChartLinkButton: View {
    @ObservedObject private var charts = OfficialChartService.shared
    let icao: String
    let type: AirportType?
    var minHeight: CGFloat = CockpitTarget.control

    var body: some View {
        if let link = charts.link(for: icao, type: type) {
            OfficialChartButton(link: link, minHeight: minHeight)
        }
    }
}
