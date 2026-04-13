import SwiftUI
import SwiftData
import CoreLocation

struct CompassScreen: View {
    @Environment(MeshService.self) private var mesh
    @Environment(LocationProvider.self) private var location
    @Environment(UnitSettings.self) private var units
    @Query(sort: \Tracker.assignedAt) private var trackers: [Tracker]
    @State private var selectedIndex = 0

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Compass")
                .onAppear {
                    location.requestPermission()
                    location.startUpdating()
                }
                .onChange(of: trackers.count) { _, count in
                    if selectedIndex >= count { selectedIndex = max(0, count - 1) }
                }
        }
    }

    @ViewBuilder private var content: some View {
        if trackers.isEmpty {
            ContentUnavailableView(
                "No dogs assigned",
                systemImage: "pawprint",
                description: Text("Assign a tracker as a dog first.")
            )
        } else {
            VStack(spacing: 0) {
                dogPicker
                compassBody
            }
        }
    }

    // MARK: - Dog picker

    private var dogPicker: some View {
        Picker("Dog", selection: $selectedIndex) {
            ForEach(Array(trackers.enumerated()), id: \.offset) { i, t in
                Text(t.name).tag(i)
            }
        }
        .pickerStyle(.segmented)
        .padding()
    }

    // MARK: - Compass

    @ViewBuilder private var compassBody: some View {
        let safeIndex = min(max(selectedIndex, 0), trackers.count - 1)
        let tracker = trackers[safeIndex]
        let node = mesh.nodes[tracker.nodeNum]

        if let node, node.hasPosition,
           let dogLat = node.latitude, let dogLon = node.longitude,
           let userLoc = location.userLocation {

            let dogCoord = CLLocationCoordinate2D(latitude: dogLat, longitude: dogLon)
            let userCoord = userLoc.coordinate
            let bearing = BearingMath.bearing(from: userCoord, to: dogCoord)
            let distance = BearingMath.distance(from: userCoord, to: dogCoord)
            let trueHeading = location.heading?.trueHeading ?? 0
            let arrowAngle = bearing - trueHeading

            VStack(spacing: 24) {
                Spacer()
                arrowView(angle: arrowAngle, color: Color(hex: tracker.colorHex) ?? .green)
                Text(BearingMath.distanceString(distance, useMetric: units.useMetric))
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                fixAgeLabel(node: node)
                Spacer()
                pingButton(tracker: tracker)
            }
            .padding()
        } else {
            ContentUnavailableView(
                "Waiting for position",
                systemImage: "location.slash",
                description: Text(
                    node == nil
                    ? "No data from \(tracker.name) yet."
                    : "Waiting for GPS fix from \(tracker.name)."
                )
            )
        }
    }

    // MARK: - Arrow

    private func arrowView(angle: Double, color: Color) -> some View {
        Image(systemName: "location.north.fill")
            .resizable()
            .scaledToFit()
            .frame(width: 120, height: 120)
            .foregroundStyle(color)
            .rotationEffect(.degrees(angle))
            .animation(.easeOut(duration: 0.3), value: angle)
    }

    // MARK: - Fix age

    private func fixAgeLabel(node: MeshNode) -> some View {
        let age = node.positionTime.map { -$0.timeIntervalSinceNow } ?? .infinity
        let text: String
        let color: Color
        if age <= 180 {         // green ≤ 3 min
            text = "Fix \(Int(age))s ago"
            color = .green
        } else if age <= 600 {  // yellow ≤ 10 min
            text = "Fix \(Int(age / 60))m ago"
            color = .yellow
        } else if age < .infinity {
            text = "Fix \(Int(age / 60))m ago"
            color = .red
        } else {
            text = "No fix"
            color = .red
        }

        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(text).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    // MARK: - Ping

    @State private var isPinging = false
    @State private var pingTask: Task<Void, Never>?

    private func pingButton(tracker: Tracker) -> some View {
        Button {
            pingTask?.cancel()
            pingTask = Task {
                isPinging = true
                _ = try? await mesh.requestPosition(from: tracker.nodeNum)
                try? await Task.sleep(for: .seconds(30))
                if !Task.isCancelled { isPinging = false }
            }
        } label: {
            Label(isPinging ? "Pinging…" : "Ping \(tracker.name)",
                  systemImage: "location.magnifyingglass")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(isPinging)
        .padding(.horizontal)
        .padding(.bottom)
        .onDisappear {
            pingTask?.cancel()
            isPinging = false
        }
    }
}

#Preview {
    CompassScreen()
        .modelContainer(for: [Tracker.self, Fix.self, TileRegion.self], inMemory: true)
}
