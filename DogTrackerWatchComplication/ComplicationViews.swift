import SwiftUI
import WidgetKit

/// Renders the three watchOS widget families we support:
///   - accessoryCircular (Modular/Meridian corner)
///   - accessoryRectangular (Infograph Modular, Siri watch face)
///   - accessoryInline (smart stack single-line text)
///
/// Each family shows a directional arrow plus distance to the closest
/// dog. The arrow uses the phone's last-known heading from the snapshot;
/// it'll be slightly stale if the user has rotated since the last
/// applicationContext push, but tapping the complication opens the live
/// compass in the watch app.
///
/// Every family tap deep-links into the main watch app via the
/// `pawmesh://dog/<nodeNum>` URL scheme.
struct ComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ComplicationEntry

    var body: some View {
        switch family {
        case .accessoryCircular:    circular
        case .accessoryRectangular: rectangular
        case .accessoryInline:      inline
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
                        // Arrow takes the upper half. Falls back to a paw
                        // icon if we have no heading or bearing yet.
                        directionGlyph(rotation: arrowRotation, color: tier.color)
                            .frame(width: 22, height: 22)
                        Text(BearingMath.distanceString(meters,
                                                        useMetric: entry.snapshot.useMetric))
                            .font(.caption2.monospaced().bold())
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                    }
                    .padding(4)
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
        Group {
            if entry.snapshot.trackers.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("PawMesh").font(.headline)
                    Text("No dogs").font(.caption2).foregroundStyle(.secondary)
                }
            } else if let closest = entry.closest, let meters = entry.closestMeters {
                let described = FixAge.describe(closest.lastFix?.fixTime, now: entry.date)
                HStack(spacing: 8) {
                    // Big arrow on the left — primary affordance.
                    directionGlyph(rotation: arrowRotation,
                                   color: Color(hex: closest.colorHex) ?? .green)
                        .frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(closest.name)
                            .font(.headline)
                            .lineLimit(1)
                        Text(BearingMath.distanceString(meters,
                                                        useMetric: entry.snapshot.useMetric))
                            .font(.caption.monospaced())
                        HStack(spacing: 3) {
                            Circle().fill(described.tier.color).frame(width: 5, height: 5)
                            Text(described.text)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
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
                // Inline can't render a rotated SwiftUI shape, so we use a
                // cardinal-direction letter as a textual arrow proxy.
                let cardinal = entry.closestBearing.map(Self.cardinal(for:)) ?? ""
                let parts = ["\(cardinal) \(BearingMath.distanceString(meters, useMetric: entry.snapshot.useMetric))",
                             closest.name].filter { !$0.isEmpty }
                Text(parts.joined(separator: " · "))
            } else {
                Text("PawMesh")
            }
        }
        .widgetURL(entry.closest.map { deepLink(for: $0.nodeNum) } ?? rootDeepLink)
    }

    // MARK: - Direction glyph

    /// Filled arrow icon, rotated to point toward the dog. When we
    /// don't have any bearing data, falls back to a paw print so the
    /// complication never looks broken.
    @ViewBuilder
    private func directionGlyph(rotation: Double?, color: Color) -> some View {
        if let rotation {
            Image(systemName: "location.north.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(color)
                .rotationEffect(.degrees(rotation))
        } else {
            Image(systemName: "pawprint.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(color)
        }
    }

    /// Arrow rotation in degrees: prefer relative-to-user-heading,
    /// fall back to absolute bearing (which means the arrow points to
    /// the dog assuming "up" is north, like a paper compass).
    private var arrowRotation: Double? {
        if let a = entry.arrowAngle { return a }
        return entry.closestBearing
    }

    /// 8-point cardinal label (N, NE, E, SE, S, SW, W, NW) for a
    /// 0..360 bearing.
    private static func cardinal(for bearing: Double) -> String {
        let labels = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let normalized = ((bearing.truncatingRemainder(dividingBy: 360)) + 360)
            .truncatingRemainder(dividingBy: 360)
        let idx = Int((normalized + 22.5) / 45) % 8
        return labels[idx]
    }

    // MARK: - Deep links

    /// The watch app's URL handler watches for `pawmesh://dog/<nodeNum>`
    /// and navigates straight to that tracker's compass page.
    private func deepLink(for nodeNum: UInt32) -> URL {
        URL(string: "pawmesh://dog/\(nodeNum)")!
    }

    private var rootDeepLink: URL { URL(string: "pawmesh://")! }
}
