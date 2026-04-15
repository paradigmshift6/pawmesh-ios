import SwiftUI
import SwiftData
@preconcurrency import MapLibre
import CoreLocation

struct TileManagerScreen: View {
    @Query(sort: \TileRegion.downloadedAt, order: .reverse) private var regions: [TileRegion]
    @Environment(\.modelContext) private var modelContext
    @State private var showDownloadSheet = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Offline Tiles")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showDownloadSheet = true
                        } label: {
                            Label("Add Region", systemImage: "plus")
                        }
                    }
                }
                .sheet(isPresented: $showDownloadSheet) {
                    TileDownloadSheet()
                }
        }
    }

    @ViewBuilder private var content: some View {
        if regions.isEmpty {
            ContentUnavailableView(
                "No offline regions",
                systemImage: "square.grid.3x3.square",
                description: Text("Tap + to download USGS topo tiles for offline use.\nDo this on Wi-Fi before heading into the backcountry.")
            )
        } else {
            List {
                ForEach(regions) { region in
                    TileRegionRow(region: region)
                }
                .onDelete(perform: deleteRegions)
            }
        }
    }

    private func deleteRegions(at offsets: IndexSet) {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("TileRegions") else { return }

        // Tell the map to release its SQLite handle before we delete the file
        NotificationCenter.default.post(name: .willDeleteTileRegion, object: nil)

        for i in offsets {
            let region = regions[i]
            let file = dir.appendingPathComponent(region.filename)
            try? FileManager.default.removeItem(at: file)
            modelContext.delete(region)
        }
        try? modelContext.save()

        // Let the map reload with remaining tiles or online fallback
        NotificationCenter.default.post(name: .didDeleteTileRegion, object: nil)
    }
}

private struct TileRegionRow: View {
    let region: TileRegion

    var body: some View {
        VStack(alignment: .leading) {
            Text(region.name).font(.headline)
            Text("z\(region.minZoom)–\(region.maxZoom) · \(sizeString)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Downloaded \(region.downloadedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var sizeString: String {
        ByteCountFormatter.string(fromByteCount: region.sizeBytes, countStyle: .file)
    }
}

// MARK: - Map-based download sheet

struct TileDownloadSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var regionName = ""
    @State private var minZoom = 10
    @State private var maxZoom = 15
    @State private var isDownloading = false
    @State private var progress = 0
    @State private var total = 0
    @State private var errorMessage: String?
    /// Bounding box derived from the visible map region.
    @State private var visibleBounds: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)?
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                mapSection
                controlsSection
            }
            // Keep the map at its full size when the keyboard appears — otherwise
            // the visible-bounds callback fires with a smaller map and the region
            // the user picked jumps around.
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .navigationTitle("Download Region")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isDownloading)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { nameFieldFocused = false }
                }
            }
        }
    }

    // MARK: - Map

    private var mapSection: some View {
        ZStack {
            RegionPickerMap(onBoundsChanged: { bounds in
                visibleBounds = bounds
            })
            .ignoresSafeArea(edges: .horizontal)

            // Crosshair overlay showing the download region
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor, lineWidth: 2)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor.opacity(0.08))
                )
                .padding(24)
                .allowsHitTesting(false)

            VStack {
                Text("Pan & zoom to select area")
                    .font(.caption.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                Spacer()
            }
            .padding(.top, 8)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Controls

    private var controlsSection: some View {
        VStack(spacing: 12) {
            TextField("Region name (e.g. Yellowstone)", text: $regionName)
                .textFieldStyle(.roundedBorder)
                .focused($nameFieldFocused)
                .submitLabel(.done)
                .onSubmit { nameFieldFocused = false }

            HStack {
                Text("Zoom")
                    .font(.subheadline)
                Spacer()
                Stepper("Min \(minZoom)", value: $minZoom, in: 1...maxZoom)
                    .fixedSize()
            }
            HStack {
                Spacer()
                Stepper("Max \(maxZoom)", value: $maxZoom, in: minZoom...16)
                    .fixedSize()
            }

            Text(estimatedInfo)
                .font(.caption)
                .foregroundStyle(.secondary)

            if isDownloading {
                ProgressView(value: Double(progress), total: Double(max(total, 1)))
                Text("\(progress)/\(total) tiles")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            if let err = errorMessage {
                Text(err).font(.caption).foregroundStyle(.red)
            }

            Button {
                startDownload()
            } label: {
                Label(isDownloading ? "Downloading…" : "Download Tiles",
                      systemImage: "arrow.down.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canDownload)
        }
        .padding()
        .background(.bar)
    }

    // MARK: - Logic

    private var canDownload: Bool {
        !regionName.isEmpty && !isDownloading && visibleBounds != nil
    }

    private var estimatedInfo: String {
        guard let b = visibleBounds else {
            return "Move the map to see estimate"
        }
        var count = 0
        for z in minZoom...maxZoom {
            let xRange = tileX(lon: b.minLon, zoom: z)...tileX(lon: b.maxLon, zoom: z)
            let yRange = tileY(lat: b.maxLat, zoom: z)...tileY(lat: b.minLat, zoom: z)
            count += xRange.count * yRange.count
        }
        let estMB = Double(count) * 30 / 1024
        return "~\(count) tiles, est. \(Int(estMB)) MB"
    }

    private func tileX(lon: Double, zoom: Int) -> Int {
        let n = Double(1 << zoom)
        return max(0, Int(floor((lon + 180) / 360 * n)))
    }

    private func tileY(lat: Double, zoom: Int) -> Int {
        let n = Double(1 << zoom)
        let r = lat * .pi / 180
        return max(0, Int(floor((1 - log(tan(r) + 1 / cos(r)) / .pi) / 2 * n)))
    }

    private func startDownload() {
        guard let b = visibleBounds else { return }
        isDownloading = true
        errorMessage = nil

        Task {
            do {
                guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
                    .appendingPathComponent("TileRegions") else {
                    throw TileDownloadError.noDocumentsDirectory
                }
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

                let filename = "\(regionName.replacingOccurrences(of: " ", with: "_"))_\(Int(Date().timeIntervalSince1970)).mbtiles"
                let fileURL = dir.appendingPathComponent(filename)

                let downloader = TileDownloader()
                let size = try await downloader.download(
                    minLat: b.minLat, maxLat: b.maxLat,
                    minLon: b.minLon, maxLon: b.maxLon,
                    minZoom: minZoom, maxZoom: maxZoom,
                    outputURL: fileURL
                ) { done, tot in
                    Task { @MainActor in
                        progress = done
                        total = tot
                    }
                }

                let region = TileRegion(
                    name: regionName,
                    filename: filename,
                    minLatitude: b.minLat, maxLatitude: b.maxLat,
                    minLongitude: b.minLon, maxLongitude: b.maxLon,
                    minZoom: minZoom, maxZoom: maxZoom,
                    sizeBytes: size
                )
                modelContext.insert(region)
                try modelContext.save()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isDownloading = false
            }
        }
    }
}

// MARK: - Region picker map (UIViewRepresentable)

/// A plain MapLibre map used to select a download region.
/// Reports the visible bounding box whenever the user finishes panning/zooming.
private struct RegionPickerMap: UIViewRepresentable {
    let onBoundsChanged: ((minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)) -> Void

    func makeUIView(context: Context) -> MLNMapView {
        let map = MLNMapView(frame: .zero)
        map.delegate = context.coordinator
        map.showsUserLocation = true
        // Center on user's current location if available, otherwise default to US center
        map.userTrackingMode = .follow
        map.setZoomLevel(10, animated: false)

        return map
    }

    func updateUIView(_ uiView: MLNMapView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onBoundsChanged: onBoundsChanged)
    }

    @MainActor class Coordinator: NSObject, @preconcurrency MLNMapViewDelegate {
        let onBoundsChanged: ((minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)) -> Void
        private var tileSourceAdded = false
        private var hasInitialCenter = false

        init(onBoundsChanged: @escaping ((minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)) -> Void) {
            self.onBoundsChanged = onBoundsChanged
        }

        func mapView(_ mapView: MLNMapView, didUpdate userLocation: MLNUserLocation?) {
            // Center on user location once, then let them pan freely
            guard !hasInitialCenter,
                  let coord = userLocation?.coordinate,
                  CLLocationCoordinate2DIsValid(coord),
                  coord.latitude != 0 || coord.longitude != 0 else { return }
            hasInitialCenter = true
            mapView.userTrackingMode = .none
            mapView.setCenter(coord, zoomLevel: 10, animated: true)
        }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            guard !tileSourceAdded else { return }
            tileSourceAdded = true
            let source = MLNRasterTileSource(
                identifier: "usgs-topo",
                tileURLTemplates: [
                    "https://basemap.nationalmap.gov/arcgis/rest/services/USGSTopo/MapServer/tile/{z}/{y}/{x}"
                ],
                options: [
                    .tileSize: 256,
                    .minimumZoomLevel: 1,
                    .maximumZoomLevel: 16,
                ]
            )
            style.addSource(source)
            style.addLayer(MLNRasterStyleLayer(identifier: "usgs-topo-layer", source: source))
        }

        func mapViewRegionIsChanging(_ mapView: MLNMapView) {
            reportBounds(mapView)
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            reportBounds(mapView)
        }

        private func reportBounds(_ mapView: MLNMapView) {
            // Guard against zero-sized frame during sheet presentation animation
            guard mapView.bounds.width > 48, mapView.bounds.height > 48 else { return }

            let inset: CGFloat = 24
            let rect = mapView.bounds.insetBy(dx: inset, dy: inset)
            let nw = mapView.convert(CGPoint(x: rect.minX, y: rect.minY), toCoordinateFrom: mapView)
            let se = mapView.convert(CGPoint(x: rect.maxX, y: rect.maxY), toCoordinateFrom: mapView)

            // Validate coordinates are sensible
            guard nw.latitude.isFinite, se.latitude.isFinite,
                  nw.longitude.isFinite, se.longitude.isFinite else { return }

            let minLat = min(nw.latitude, se.latitude)
            let maxLat = max(nw.latitude, se.latitude)
            let minLon = min(nw.longitude, se.longitude)
            let maxLon = max(nw.longitude, se.longitude)
            onBoundsChanged((minLat, maxLat, minLon, maxLon))
        }
    }
}

#Preview {
    TileManagerScreen()
        .modelContainer(for: [Tracker.self, Fix.self, TileRegion.self], inMemory: true)
}
