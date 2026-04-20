import SwiftUI
import CoreLocation

/// Overview screen — shows one row per tracker with name, distance, and
/// fix-age color. Tap a row to push the full-screen compass page for
/// that dog.
struct WatchDogsListScreen: View {
    @Environment(WatchSession.self) private var session
    /// Nav path passed from the root so deep-link pushes work.
    @Binding var path: [UInt32]

    /// 1Hz tick so the fix-age "ago" labels stay live.
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        List(session.snapshot.trackers) { tracker in
            NavigationLink(value: tracker.nodeNum) {
                DogRow(tracker: tracker,
                       userLocation: session.snapshot.userLocation,
                       useMetric: session.snapshot.useMetric,
                       now: now)
            }
        }
        .navigationTitle("Dogs")
        .navigationDestination(for: UInt32.self) { nodeNum in
            if let t = session.snapshot.trackers.first(where: { $0.nodeNum == nodeNum }) {
                WatchCompassPage(tracker: t)
            }
        }
        .onReceive(tick) { now = $0 }
    }
}

private struct DogRow: View {
    let tracker: TrackerSnapshot
    let userLocation: UserLocation?
    let useMetric: Bool
    let now: Date

    var body: some View {
        HStack(spacing: 8) {
            badge
            VStack(alignment: .leading, spacing: 2) {
                Text(tracker.name)
                    .font(.headline)
                    .lineLimit(1)
                distanceLabel
            }
            Spacer(minLength: 0)
            fixAgeDot
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var badge: some View {
        let color = Color(hex: tracker.colorHex) ?? .green
        if let data = tracker.photoThumbnail, let img = UIImage(data: data) {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
                .frame(width: 32, height: 32)
                .clipShape(Circle())
                .overlay(Circle().stroke(color, lineWidth: 2))
        } else {
            Text(tracker.name.prefix(1))
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(color)
                .clipShape(Circle())
        }
    }

    @ViewBuilder private var distanceLabel: some View {
        if let user = userLocation, let fix = tracker.lastFix {
            let meters = BearingMath.distance(
                from: CLLocationCoordinate2D(latitude: user.latitude, longitude: user.longitude),
                to: CLLocationCoordinate2D(latitude: fix.latitude, longitude: fix.longitude)
            )
            Text(BearingMath.distanceString(meters, useMetric: useMetric))
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        } else {
            Text("Waiting")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var fixAgeDot: some View {
        let described = FixAge.describe(tracker.lastFix?.fixTime, now: now)
        return Circle()
            .fill(described.tier.color)
            .frame(width: 8, height: 8)
    }
}
