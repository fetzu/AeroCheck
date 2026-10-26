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
        CalloutMetrics(target: CockpitTarget.control(scale), fontSize: CockpitType.label(for: scale),
                       captionSize: CockpitType.label(for: scale), sideBySide: scale == .phone)
    }

    static func metrics(inFlight: Bool) -> CalloutMetrics { inFlight ? .flight : .ground }
}

// MARK: - UIKit: map callouts

/// The official chart in a procedure's callout, carrying its link. (6.2.0; an aerodrome's is its card's since 6.7.0)
final class OfficialChartControl: UIButton {
    private(set) var link: OfficialChartLink?

    /// A row of a callout's detail (the VFR procedure's): "Official chart" with its symbol, and the
    /// subscription under it for SkyBriefing, at least `metrics.target` tall. It opens `link` itself.
    /// Side by side (`metrics.sideBySide`), its title is the short "Chart" over "Subscription" for
    /// SkyBriefing (the symbol is a lock); VoiceOver still reads the whole title.
    static func action(link: OfficialChartLink, metrics: CalloutMetrics, tint: UIColor,
                       open: @escaping (URL) -> Void) -> OfficialChartControl {
        var configuration = UIButton.Configuration.tinted()
        configuration.title = metrics.sideBySide ? L10n.OfficialChart.short : L10n.OfficialChart.title
        configuration.subtitle = metrics.sideBySide ? link.shortNote : link.note
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
