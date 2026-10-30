import SwiftUI

/// The month's online allowance for the Atlas: Settings › Offline data › Atlas online. (6.8.0)
struct PilotMapAllowanceRow: View {
    @ObservedObject var downloads: PilotMapDownloads

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L10n.PilotMap.allowance(used: downloads.allowanceUsed, limit: downloads.allowanceLimit))
                .font(.aero(.subheadline))
                .foregroundColor(.primaryText)
            switch downloads.allowanceLevel {
            case .open:
                EmptyView()
            case .nearLimit:
                Text(L10n.PilotMap.allowanceNear)
                    .font(.aero(.caption))
                    .foregroundColor(.aviationAmber)
            case .exhausted:
                Text(L10n.PilotMap.allowanceExhausted)
                    .font(.aero(.caption))
                    .foregroundColor(.aviationAmber)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

/// One region: name, then its state, build date and size; the action at the end.
struct PilotMapRegionRow: View {
    let region: PilotMapRegion
    let state: PilotMapDownloads.State
    let bytesToFetch: Int
    let tint: Color
    let download: () -> Void
    let stop: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(region.displayName)
                    .font(.aero(.subheadline))
                    .foregroundColor(.primaryText)
                Text(detail)
                    .font(.aero(.caption))
                    .foregroundColor(state == .failed ? .aviationRed : .secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if case let .downloading(fraction) = state {
                    ProgressView(value: fraction)
                        .tint(tint)
                        .accessibilityLabel(L10n.PilotMap.downloading(fraction))
                }
            }
            Spacer(minLength: 8)
            action
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var detail: String {
        var parts: [String] = []
        switch state {
        case .notDownloaded: parts.append(L10n.DataStorage.statusMissing)
        case let .downloading(fraction): parts.append(L10n.PilotMap.downloading(fraction))
        case .downloaded: parts.append(L10n.PilotMap.downloaded)
        case .updateAvailable: parts.append(L10n.PilotMap.updateAvailable)
        case .failed: parts.append(L10n.PilotMap.failed)
        }
        if let built = Self.date(region.built) { parts.append(L10n.DataStorage.asOf(built)) }
        // What is on the device, or what the tap would fetch (an update: only the archives rebuilt).
        let bytes: Int
        switch state {
        case .downloading: bytes = 0
        case .updateAvailable: bytes = bytesToFetch
        default: bytes = region.downloadBytes
        }
        if bytes > 0 { parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var action: some View {
        switch state {
        case .downloading:
            Button(action: stop) {
                Image(systemName: "stop.circle")
                    .scaledFont(size: 20, relativeTo: .title3)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .foregroundColor(.secondaryText)
            .accessibilityLabel(L10n.PilotMap.stop)
        case .notDownloaded, .failed:
            Button(L10n.PilotMap.download, action: download)
                .font(.aero(.subheadline).weight(.semibold))
                .foregroundColor(tint)
                .frame(minHeight: 44)
        case .downloaded, .updateAvailable:
            Menu {
                if state == .updateAvailable {
                    Button(action: download) { Label(L10n.PilotMap.update, systemImage: "arrow.triangle.2.circlepath") }
                }
                Button(role: .destructive, action: delete) { Label(L10n.DataStorage.delete, systemImage: "trash") }
            } label: {
                Image(systemName: state == .updateAvailable ? "arrow.down.circle" : "checkmark.circle")
                    .scaledFont(size: 20, relativeTo: .title3)
                    .foregroundColor(state == .updateAvailable ? tint : .secondaryText)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(L10n.DataStorage.rowActions)
        }
    }

    /// `yyyyMMdd` as the device writes a date.
    static func date(_ built: String) -> String? {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.dateFormat = "yyyyMMdd"
        guard let date = parser.date(from: built) else { return nil }
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: TimeZone(identifier: "UTC")!))
    }
}
