import SwiftUI
import SwiftData
import CoreLocation

struct MapScreen: View {
    @Environment(RadioController.self) private var radio
    @Environment(MeshService.self) private var mesh
    @Environment(UnitSettings.self) private var units
    @Query(sort: \Tracker.assignedAt) private var trackers: [Tracker]
    @State private var centerOn: CLLocationCoordinate2D?
    @State private var selectedTracker: Tracker?

    var body: some View {
        ZStack(alignment: .top) {
            DogMapView(markers: dogMarkers, centerOn: centerOn)
                .ignoresSafeArea()

            statusBar
            if let t = selectedTracker {
                TrackerSheet(tracker: t, mesh: mesh, units: units) { coord in
                    centerOn = coord
                }
                .transition(.move(edge: .bottom))
            }
        }
        .overlay(alignment: .bottomTrailing) { pingAllButton }
    }

    // MARK: - Markers

    private var dogMarkers: [DogMarker] {
        trackers.compactMap { tracker -> DogMarker? in
            guard let node = mesh.nodes[tracker.nodeNum], node.hasPosition,
                  let lat = node.latitude, let lon = node.longitude else { return nil }
            let age = node.positionTime.map { fixAgeString($0) } ?? "no fix"
            return DogMarker(
                nodeNum: tracker.nodeNum,
                name: tracker.name,
                colorHex: tracker.colorHex,
                latitude: lat,
                longitude: lon,
                subtitle: age,
                photoData: tracker.photoData
            )
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(radioColor)
            Text(radioLabel).font(.caption)
            Spacer()
            ForEach(trackers) { t in
                Button {
                    withAnimation { selectedTracker = selectedTracker?.id == t.id ? nil : t }
                } label: {
                    Circle()
                        .fill(Color(hex: t.colorHex) ?? .gray)
                        .frame(width: 20, height: 20)
                        .overlay(
                            Text(String(t.name.prefix(1)))
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                        )
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    private var radioColor: Color {
        switch radio.connectionState {
        case .connected: .green
        case .configuring, .connecting, .scanning: .yellow
        default: .red
        }
    }

    private var radioLabel: String {
        switch radio.connectionState {
        case .connected(let n): n
        case .disconnected: "Disconnected"
        default: "Connecting…"
        }
    }

    // MARK: - Ping all FAB

    @ViewBuilder private var pingAllButton: some View {
        if !trackers.isEmpty, case .connected = radio.connectionState {
            Button {
                pingAll()
            } label: {
                Label("Ping All", systemImage: "location.magnifyingglass")
                    .font(.subheadline.bold())
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThickMaterial, in: Capsule())
            }
            .padding()
        }
    }

    private func pingAll() {
        Task {
            for tracker in trackers {
                _ = try? await mesh.requestPosition(from: tracker.nodeNum)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func fixAgeString(_ date: Date) -> String {
        let secs = -date.timeIntervalSinceNow
        if secs < 60 { return "\(Int(secs))s ago" }
        if secs < 3600 { return "\(Int(secs / 60))m ago" }
        return "\(Int(secs / 3600))h ago"
    }
}

// MARK: - Tracker bottom sheet

private struct TrackerSheet: View {
    let tracker: Tracker
    let mesh: MeshService
    let units: UnitSettings
    let onCenter: (CLLocationCoordinate2D) -> Void

    @State private var isPinging = false
    @State private var pingResult: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(Color(hex: tracker.colorHex) ?? .gray)
                    .frame(width: 12, height: 12)
                Text(tracker.name).font(.headline)
                Spacer()
                if let node = mesh.nodes[tracker.nodeNum], node.hasPosition,
                   let lat = node.latitude, let lon = node.longitude {
                    Button("Center") {
                        onCenter(CLLocationCoordinate2D(latitude: lat, longitude: lon))
                    }
                    .buttonStyle(.bordered)
                }
            }
            if let node = mesh.nodes[tracker.nodeNum] {
                nodeInfo(node)
            }
            HStack {
                Button {
                    ping()
                } label: {
                    Label(isPinging ? "Pinging…" : "Ping", systemImage: "location.magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isPinging)
                if let r = pingResult {
                    Text(r).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding()
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    @ViewBuilder private func nodeInfo(_ node: MeshNode) -> some View {
        let fields: [(String, String)] = [
            node.latitude.map { ("Lat", String(format: "%.6f", $0)) },
            node.longitude.map { ("Lon", String(format: "%.6f", $0)) },
            node.altitude.map { ("Alt", BearingMath.altitudeString($0, useMetric: units.useMetric)) },
            node.positionTime.map { ("Fix age", fixAgeText($0)) },
        ].compactMap { $0 }
        HStack(spacing: 16) {
            ForEach(fields, id: \.0) { label, value in
                VStack {
                    Text(label).font(.caption2).foregroundStyle(.secondary)
                    Text(value).font(.caption.monospaced())
                }
            }
        }
    }

    private func ping() {
        isPinging = true
        pingResult = nil
        Task {
            do {
                _ = try await mesh.requestPosition(from: tracker.nodeNum)
            } catch {
                isPinging = false
                pingResult = "Send failed: \(error.localizedDescription)"
                return
            }
            // Watch for a new fix
            let startTime = Date()
            let nodeNum = tracker.nodeNum
            for _ in 0..<60 { // poll for 30 seconds
                try? await Task.sleep(for: .milliseconds(500))
                if let node = mesh.nodes[nodeNum],
                   let t = node.lastPositionUpdate, t > startTime {
                    isPinging = false
                    pingResult = "Updated!"
                    if let lat = node.latitude, let lon = node.longitude {
                        onCenter(CLLocationCoordinate2D(latitude: lat, longitude: lon))
                    }
                    return
                }
            }
            isPinging = false
            pingResult = "No response (timeout)"
        }
    }

    private func fixAgeText(_ date: Date) -> String {
        let secs = -date.timeIntervalSinceNow
        if secs < 60 { return "\(Int(secs))s" }
        if secs < 3600 { return "\(Int(secs / 60))m" }
        return "\(Int(secs / 3600))h"
    }
}
