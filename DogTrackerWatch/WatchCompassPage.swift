import SwiftUI
import CoreLocation

/// One page of the compass — single tracker.
///
/// Shows: tracker name + connection badge / arrow / distance / fix-age
/// indicator / ping button. Re-renders every second so the "ago" label and
/// the staleness color stay live without us pushing context every tick.
struct WatchCompassPage: View {
    @Environment(WatchSession.self) private var session
    @Environment(WatchHeadingProvider.self) private var heading
    /// True when the watch is in Always-On Display mode (dim).
    /// In this mode we skip animations and dim colors to preserve OLED.
    @Environment(\.isLuminanceReduced) private var isDimmed
    let tracker: TrackerSnapshot

    /// Drives a 1Hz re-render so the fix-age label and color tier update
    /// even when no new snapshot has arrived from the phone.
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 6) {
            header
            Spacer(minLength: 0)
            arrow
            distance
            fixAgeRow
            calibrationWarning
            Spacer(minLength: 0)
            pingButton
        }
        .padding(.horizontal, 8)
        .onReceive(tick) { now = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(voiceOverSummary)
    }

    /// VoiceOver reads the whole page as one phrase: "Maple, 20.5 miles,
    /// bearing 47 degrees, fix 12 seconds ago." The per-element visuals
    /// still render; we just give the screen reader a sensible narrative.
    private var voiceOverSummary: String {
        var parts: [String] = [tracker.name]
        if let meters = distanceMeters {
            parts.append(BearingMath.distanceString(meters, useMetric: session.snapshot.useMetric))
        }
        if let angle = arrowAngle {
            // Normalize 0..360 for readability.
            let normalized = Int(((angle.truncatingRemainder(dividingBy: 360)) + 360)
                                 .truncatingRemainder(dividingBy: 360))
            parts.append("bearing \(normalized) degrees")
        }
        parts.append(FixAge.describe(tracker.lastFix?.fixTime, now: now).text)
        return parts.joined(separator: ", ")
    }

    /// Shown when the watch's compass is poorly calibrated — the arrow
    /// can silently be 40-90° off and the user has no way to know. Prompts
    /// the figure-8 dance until accuracy improves.
    @ViewBuilder private var calibrationWarning: some View {
        if let acc = heading.accuracy, acc > 40, heading.trueHeading != nil {
            HStack(spacing: 3) {
                Image(systemName: "location.north.circle")
                    .font(.caption2)
                Text("Calibrate (figure-8)")
                    .font(.caption2)
            }
            .foregroundStyle(.yellow)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            trackerBadge
            Text(tracker.name)
                .font(.headline)
                .lineLimit(1)
            Spacer(minLength: 0)
            linkBadge
        }
    }

    /// Dog photo if we have one, else a solid colored dot. Matches the
    /// iOS map marker style so the two screens feel like one app.
    @ViewBuilder private var trackerBadge: some View {
        let color = Color(hex: tracker.colorHex) ?? .green
        if let data = tracker.photoThumbnail, let img = UIImage(data: data) {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
                .frame(width: 22, height: 22)
                .clipShape(Circle())
                .overlay(Circle().stroke(color, lineWidth: 2))
        } else {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
        }
    }

    @ViewBuilder private var linkBadge: some View {
        switch session.snapshot.linkState {
        case .connected:
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.caption2)
                .foregroundStyle(.green)
        case .connecting:
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.caption2)
                .foregroundStyle(.yellow)
        case .disconnected:
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.caption2)
                .foregroundStyle(.red)
        }
    }

    // MARK: - Arrow + distance

    private var arrowAngle: Double? {
        guard let user = session.snapshot.userLocation,
              let fix = tracker.lastFix else { return nil }
        let userCoord = CLLocationCoordinate2D(latitude: user.latitude, longitude: user.longitude)
        let dogCoord = CLLocationCoordinate2D(latitude: fix.latitude, longitude: fix.longitude)
        let bearing = BearingMath.bearing(from: userCoord, to: dogCoord)
        // Prefer the watch's own magnetometer so the arrow re-orients live
        // as the user turns their wrist. Fall back to the phone's heading
        // if the watch has no compass hardware (pre-Series 5).
        let userHeading = heading.trueHeading ?? user.trueHeading ?? 0
        return bearing - userHeading
    }

    private var distanceMeters: Double? {
        guard let user = session.snapshot.userLocation,
              let fix = tracker.lastFix else { return nil }
        let userCoord = CLLocationCoordinate2D(latitude: user.latitude, longitude: user.longitude)
        let dogCoord = CLLocationCoordinate2D(latitude: fix.latitude, longitude: fix.longitude)
        return BearingMath.distance(from: userCoord, to: dogCoord)
    }

    @ViewBuilder private var arrow: some View {
        if let angle = arrowAngle {
            Image(systemName: "location.north.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 60, height: 60)
                .foregroundStyle(Color(hex: tracker.colorHex) ?? .green)
                .opacity(isDimmed ? 0.5 : 1.0)
                .rotationEffect(.degrees(angle))
                // Skip the springy arrow animation in AOD — animations
                // cost extra OLED draw and the user doesn't see them
                // update smoothly anyway in dim mode.
                .animation(isDimmed ? nil : .easeOut(duration: 0.3), value: angle)
        } else {
            Image(systemName: "location.slash")
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 40)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var distance: some View {
        if let meters = distanceMeters {
            Text(BearingMath.distanceString(meters, useMetric: session.snapshot.useMetric))
                .font(.system(size: 22, weight: .bold, design: .rounded))
        } else if session.snapshot.userLocation == nil {
            Text("No phone location")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else {
            Text("Waiting for fix")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Fix age row

    private var fixAgeRow: some View {
        let described = FixAge.describe(tracker.lastFix?.fixTime, now: now)
        return HStack(spacing: 4) {
            Circle().fill(described.tier.color).frame(width: 6, height: 6)
            Text(described.text)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Ping button

    @ViewBuilder private var pingButton: some View {
        switch session.pingState {
        case .sending(let nodeNum) where nodeNum == tracker.nodeNum,
             .waitingForFix(let nodeNum, _) where nodeNum == tracker.nodeNum:
            Button {
                // No-op while in flight; visually disabled below.
            } label: {
                Label("Pinging…", systemImage: "hourglass")
                    .font(.caption.bold())
            }
            .controlSize(.small)
            .disabled(true)

        case .success(let nodeNum) where nodeNum == tracker.nodeNum:
            Label("Updated!", systemImage: "checkmark.circle.fill")
                .font(.caption.bold())
                .foregroundStyle(.green)

        case .error(let msg):
            VStack(spacing: 2) {
                pingActionButton
                Text(msg).font(.caption2).foregroundStyle(.red).lineLimit(1)
            }

        default:
            pingActionButton
        }
    }

    private var pingActionButton: some View {
        // Only disable when the phone-radio link itself is down — tapping
        // when the phone app is backgrounded should still work: sendMessage
        // wakes the iOS app long enough to process the request. If the
        // phone isn't reachable at all, sendPing surfaces that as an error
        // rather than silently no-op'ing.
        Button {
            session.sendPing(to: tracker.nodeNum)
        } label: {
            Label("Ping", systemImage: "location.magnifyingglass")
                .font(.caption.bold())
        }
        .controlSize(.small)
        .disabled(session.snapshot.linkState == .disconnected)
        .accessibilityLabel("Ping \(tracker.name)")
        .accessibilityHint("Requests a fresh GPS position from this tracker.")
    }
}
