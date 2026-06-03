import SwiftUI
import SwiftData
import CoreLocation

struct MapScreen: View {
    @Environment(RadioController.self) private var radio
    @Environment(MeshService.self) private var mesh
    @Environment(UnitSettings.self) private var units
    @Environment(LocationProvider.self) private var location
    @Query(sort: \Tracker.assignedAt) private var trackers: [Tracker]
    @Query(sort: \Fix.fixTime) private var allFixes: [Fix]
    @Query(filter: #Predicate<Geofence> { $0.isEnabled }) private var fences: [Geofence]
    @Query(sort: \TileRegion.downloadedAt, order: .reverse) private var regions: [TileRegion]
    /// Persisted Settings override: "auto" or a specific MapSource.id.
    @AppStorage("mapSourceMode") private var mapSourceMode = MapSource.autoModeID
    /// Last source that auto-resolved from a real location. Used as the default
    /// before a GPS fix / first marker arrives so we don't downgrade (e.g. a US
    /// user briefly seeing worldwide tiles instead of USGS). Defaults to USGS.
    @AppStorage("lastAutoMapSource") private var lastAutoSource = MapSource.usgs.id
    @State private var centerOn: CLLocationCoordinate2D?
    @State private var selectedTracker: Tracker?
    /// Bump this to ask DogMapView to fit the viewport to user+markers.
    @State private var fitID: UUID?
    /// Tracks whether we've already auto-fit once so we don't re-fit every
    /// time a marker updates — only on first appearance.
    @State private var hasAutoFit = false

    var body: some View {
        ZStack(alignment: .top) {
            DogMapView(
                markers: dogMarkers,
                trails: dogTrails,
                fences: fenceOverlays,
                centerOn: centerOn,
                fitToMarkersID: fitID,
                onlineSource: resolvedOnlineSource,
                offlineTilePath: activeOfflineRegion.flatMap(offlinePath)
            )
            .ignoresSafeArea()

            statusBar
            if let t = selectedTracker {
                TrackerSheet(tracker: t, mesh: mesh, units: units) { coord in
                    centerOn = coord
                }
                .transition(.move(edge: .bottom))
            }
        }
        .overlay(alignment: .topTrailing) { recenterButton }
        .overlay(alignment: .bottomTrailing) { pingAllButton }
        .overlay(alignment: .bottom) { lowBatteryBanner }
        .overlay(alignment: .bottomLeading) {
            MapAttributionLabel(source: attributionSource)
                .padding(.leading, 8)
                .padding(.bottom, 8)
        }
        .onChange(of: dogMarkers.count) { _, newCount in
            // Auto-fit once, the first time we actually have a marker to show.
            if !hasAutoFit && newCount > 0 {
                hasAutoFit = true
                fitID = UUID()
            }
        }
        .onAppear {
            // If markers are already there on first appear, fit immediately.
            if !hasAutoFit && !dogMarkers.isEmpty {
                hasAutoFit = true
                fitID = UUID()
            }
            consumeDeepLink()
        }
        .onChange(of: NotificationAuthorization.shared.pendingDeepLink) { _, _ in
            consumeDeepLink()
        }
        .onChange(of: autoResolvedSourceID) { _, newID in
            // Remember the source we resolved from a real location so the next
            // cold launch defaults to it instead of the worldwide fallback.
            if let newID { lastAutoSource = newID }
        }
    }

    private func consumeDeepLink() {
        guard let link = NotificationAuthorization.shared.pendingDeepLink else { return }
        centerOn = CLLocationCoordinate2D(latitude: link.latitude, longitude: link.longitude)
        if let match = trackers.first(where: { $0.nodeNum == link.nodeNum }) {
            selectedTracker = match
        }
        NotificationAuthorization.shared.pendingDeepLink = nil
    }

    // MARK: - Recenter button

    private var recenterButton: some View {
        Button {
            fitID = UUID()
        } label: {
            Image(systemName: "scope")
                .font(.title3)
                .padding(10)
                .background(.ultraThinMaterial, in: Circle())
        }
        .padding(.top, 60)
        .padding(.trailing, 12)
    }

    // MARK: - Trails

    private var dogTrails: [DogTrail] {
        // Group fixes by tracker nodeNum using the @Query'd allFixes
        // (accessing tracker.fixes via the relationship doesn't trigger
        // SwiftUI updates, so we query Fix directly instead).
        let trackerMap = Dictionary(uniqueKeysWithValues: trackers.map { ($0.nodeNum, $0) })
        let grouped = Dictionary(grouping: allFixes.filter { $0.tracker != nil }) {
            $0.tracker!.nodeNum
        }
        return trackers.compactMap { tracker -> DogTrail? in
            guard trackerMap[tracker.nodeNum] != nil else { return nil }
            let fixes = (grouped[tracker.nodeNum] ?? []).sorted { $0.fixTime < $1.fixTime }
            guard fixes.count >= 2 else { return nil }
            let coords = fixes.map { (lat: $0.latitude, lon: $0.longitude) }
            return DogTrail(nodeNum: tracker.nodeNum, colorHex: tracker.colorHex, coordinates: coords)
        }
    }

    // MARK: - Fences

    private var fenceOverlays: [FenceOverlay] {
        fences.map {
            FenceOverlay(
                id: $0.id,
                centerLatitude: $0.centerLatitude,
                centerLongitude: $0.centerLongitude,
                radiusMeters: $0.radiusMeters,
                colorHex: $0.colorHex
            )
        }
    }

    // MARK: - Tile source

    /// Best coordinate to choose a tile source / matching offline region from:
    /// the user's GPS, else the centroid of the dogs on the map.
    private var representativeCoordinate: CLLocationCoordinate2D? {
        if let loc = location.userLocation { return loc.coordinate }
        let markers = dogMarkers
        guard !markers.isEmpty else { return nil }
        let lat = markers.map(\.latitude).reduce(0, +) / Double(markers.count)
        let lon = markers.map(\.longitude).reduce(0, +) / Double(markers.count)
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// Online source to use when no offline tiles cover the view.
    private var resolvedOnlineSource: MapSource {
        MapSource.resolve(mode: mapSourceMode, coordinate: representativeCoordinate,
                          fallbackID: lastAutoSource)
    }

    /// The source auto-resolved from a real location/marker right now, or nil if
    /// location is unknown or a manual override is active. Observed so we can
    /// remember it as the cold-launch default (see `lastAutoSource`).
    private var autoResolvedSourceID: String? {
        guard mapSourceMode == MapSource.autoModeID,
              let c = representativeCoordinate else { return nil }
        return MapSource.automatic(for: c).id
    }

    /// Downloaded region to render, if any: the one covering our location, or —
    /// when location is still unknown — the most recently downloaded region.
    private var activeOfflineRegion: TileRegion? {
        guard !regions.isEmpty else { return nil }
        guard let c = representativeCoordinate else { return regions.first }
        return regions.first { region in
            c.latitude >= region.minLatitude && c.latitude <= region.maxLatitude &&
            c.longitude >= region.minLongitude && c.longitude <= region.maxLongitude
        }
    }

    /// Attribution to display: the offline region's provider when one is shown,
    /// otherwise the resolved online provider.
    private var attributionSource: MapSource {
        activeOfflineRegion?.source ?? resolvedOnlineSource
    }

    /// Absolute `file://` URL string of a region's mbtiles file (DogMapView
    /// wraps it as `mbtiles://`). Nil if the file is missing.
    private func offlinePath(for region: TileRegion) -> String? {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("TileRegions") else { return nil }
        let url = dir.appendingPathComponent(region.filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url.absoluteString
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
            if let companion = mesh.nodes[mesh.myNodeNum], let level = companion.batteryLevel, level <= 100 {
                Image(systemName: level > 25 ? "battery.50" : "battery.25")
                    .foregroundStyle(level <= 20 ? .red : .secondary)
                Text("\(level)%").font(.caption2).foregroundStyle(.secondary)
            }
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

    // MARK: - Low battery warning

    @ViewBuilder private var lowBatteryBanner: some View {
        let lowNodes = lowBatteryNodes
        if !lowNodes.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "battery.25")
                    .foregroundStyle(.red)
                Text(lowBatteryText(lowNodes))
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.bottom, 80)
        }
    }

    private var lowBatteryNodes: [(String, UInt32)] {
        var results: [(String, UInt32)] = []
        // Check companion
        if let companion = mesh.nodes[mesh.myNodeNum], companion.isBatteryLow,
           let level = companion.batteryLevel {
            results.append(("Companion", level))
        }
        // Check trackers
        for tracker in trackers {
            if let node = mesh.nodes[tracker.nodeNum], node.isBatteryLow,
               let level = node.batteryLevel {
                results.append((tracker.name, level))
            }
        }
        return results
    }

    private func lowBatteryText(_ nodes: [(String, UInt32)]) -> String {
        nodes.map { "\($0.0) \($0.1)%" }.joined(separator: " · ")
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
            node.batteryLevel.map { ("Battery", $0 > 100 ? "Plugged in" : "\($0)%") },
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
            // Watch for a new fix — tracker-role nodes broadcast on a timer,
            // so we may need to wait up to 2.5 minutes for the next position.
            let startTime = Date()
            let nodeNum = tracker.nodeNum
            for _ in 0..<150 { // poll for up to 2.5 minutes
                try? await Task.sleep(for: .seconds(1))
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
