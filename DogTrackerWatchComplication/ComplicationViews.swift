import SwiftUI
import WidgetKit

/// Renders the three watchOS widget families we support:
///   - accessoryCircular (Modular/Meridian corner)
///   - accessoryRectangular (Infograph Modular, Siri watch face)
///   - accessoryInline (smart stack single-line text)
///
/// Every family tap deep-links into the main watch app via the
/// `pawmesh://` URL scheme, opening the compass page for the
/// corresponding dog.
struct ComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ComplicationEntry

    var body: some View {
        switch family {
        case .accessoryCircular:  circular
        case .accessoryRectangular: rectangular
        case .accessoryInline: inline
        default: Text("—")
        }
    }

    // MARK: - Circular

    private var circular: some View {
        Group {
            if let closest = entry.closest, let meters = entry.closestMeters {
                let tier = FixAge.describe(closest.lastFix?.fixTime, now: entry.date).tier
                ZStack {
                    AccessoryWidgetBackground()
                    VStack(spacing: 0) {
                        Image(systemName: "pawprint.fill")
                            .font(.caption2)
                            .foregroundStyle(tier.color)
                        Text(BearingMath.distanceString(meters,
                                                        useMetric: entry.snapshot.useMetric))
                            .font(.caption2.monospaced().bold())
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                    }
                    .padding(6)
                }
                .widgetURL(deepLink(for: closest.nodeNum))
            } else {
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: "pawprint")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Rectangular

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            if entry.snapshot.trackers.isEmpty {
                Text("PawMesh")
                    .font(.headline)
                Text("No dogs")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if let closest = entry.closest, let meters = entry.closestMeters {
                HStack(spacing: 4) {
                    Image(systemName: "pawprint.fill")
                        .foregroundStyle(Color(hex: closest.colorHex) ?? .green)
                    Text(closest.name)
                        .font(.headline)
                }
                Text(BearingMath.distanceString(meters,
                                                useMetric: entry.snapshot.useMetric))
                    .font(.caption.monospaced())
                let described = FixAge.describe(closest.lastFix?.fixTime, now: entry.date)
                HStack(spacing: 4) {
                    Circle().fill(described.tier.color).frame(width: 6, height: 6)
                    Text(described.text)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Waiting for fix")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .widgetURL(entry.closest.map { deepLink(for: $0.nodeNum) } ?? rootDeepLink)
    }

    // MARK: - Inline

    private var inline: some View {
        Group {
            if let closest = entry.closest, let meters = entry.closestMeters {
                Text("\(closest.name) \(BearingMath.distanceString(meters, useMetric: entry.snapshot.useMetric))")
            } else {
                Text("PawMesh")
            }
        }
        .widgetURL(entry.closest.map { deepLink(for: $0.nodeNum) } ?? rootDeepLink)
    }

    // MARK: - Deep link

    /// The watch app's URL handler watches for `pawmesh://dog/<nodeNum>`
    /// and navigates straight to that tracker's compass page.
    private func deepLink(for nodeNum: UInt32) -> URL {
        URL(string: "pawmesh://dog/\(nodeNum)")!
    }

    private var rootDeepLink: URL { URL(string: "pawmesh://")! }
}
