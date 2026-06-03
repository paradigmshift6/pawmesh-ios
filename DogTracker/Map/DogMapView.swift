import SwiftUI
@preconcurrency import MapLibre
import OSLog

private let mapLog = Logger(subsystem: "com.levijohnson.DogTracker", category: "Map")

/// Posted before an mbtiles file is deleted so the map can release its SQLite handle.
extension Notification.Name {
    static let willDeleteTileRegion = Notification.Name("willDeleteTileRegion")
    static let didDeleteTileRegion = Notification.Name("didDeleteTileRegion")
}

/// SwiftUI wrapper around MapLibre's `MLNMapView`. Shows:
///   - Topo tiles: the offline MBTiles file at `offlineTilePath` when set,
///     otherwise the online `onlineSource` (USGS / basemap.at / BKG).
///   - The user's current location (built-in blue dot).
///   - Dog tracker markers as colored circles with photo or initial.
struct DogMapView: UIViewRepresentable {

    let markers: [DogMarker]
    var trails: [DogTrail] = []
    var fences: [FenceOverlay] = []
    var centerOn: CLLocationCoordinate2D?
    /// When this ID changes, the map re-fits the viewport to show the user
    /// plus every marker. Pass a fresh UUID from the parent to trigger a
    /// recenter (e.g. when the user taps a "fit all" button).
    var fitToMarkersID: UUID?
    /// Online tile source to render when no offline file is supplied. Resolved
    /// by the parent from the user's location + the Settings override.
    var onlineSource: MapSource = .bkgTopPlus
    /// Optional path to an MBTiles file for offline topo tiles. When set it
    /// takes priority over `onlineSource`.
    var offlineTilePath: String?
    /// If set, single-taps on the map invoke this callback with the tapped
    /// coordinate (used by the fence editor to place the center).
    var onMapTap: ((CLLocationCoordinate2D) -> Void)?

    /// An empty MapLibre style (neutral background only). Without this, an
    /// MLNMapView with no styleURL loads MapLibre's default *demo* world style,
    /// whose opaque `countries-fill` layer sits on top of our raster basemap and
    /// hides it (the map shows a flat green world). With an empty style our tile
    /// layers are the only basemap, so z-ordering is clean and predictable.
    private static let emptyStyleURL: URL = {
        let json = ##"{"version":8,"name":"pawmesh-empty","sources":{},"layers":[{"id":"bg","type":"background","paint":{"background-color":"#e8eae6"}}]}"##
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pawmesh-empty-style.json")
        try? json.data(using: .utf8)?.write(to: url)
        return url
    }()

    func makeUIView(context: Context) -> MLNMapView {
        let mapView = MLNMapView(frame: .zero)
        mapView.styleURL = Self.emptyStyleURL
        mapView.delegate = context.coordinator

        // Show user location (blue dot). We disable follow mode so the user
        // stays in control of the camera; the "recenter" button explicitly
        // fits everything when the user wants it.
        mapView.showsUserLocation = true
        mapView.userTrackingMode = .none
        mapView.setZoomLevel(13, animated: false)

        // Single-tap gesture for editor mode. Always installed; the
        // coordinator decides whether to forward based on `onMapTap`.
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleMapTap(_:))
        )
        // Don't let our tap recogniser swallow taps that belong to the
        // built-in callout / annotation handling.
        tap.cancelsTouchesInView = false
        mapView.addGestureRecognizer(tap)

        return mapView
    }

    func updateUIView(_ mapView: MLNMapView, context: Context) {
        context.coordinator.onMapTap = onMapTap
        context.coordinator.applyTileSource(
            on: mapView, onlineSource: onlineSource, offlineTilePath: offlineTilePath
        )
        context.coordinator.updateMarkers(on: mapView, markers: markers)
        context.coordinator.updateTrails(on: mapView, trails: trails)
        context.coordinator.updateFences(on: mapView, fences: fences)

        if let center = centerOn {
            mapView.setCenter(center, zoomLevel: max(mapView.zoomLevel, 14), animated: true)
        }

        context.coordinator.handleFitRequest(
            on: mapView,
            id: fitToMarkersID,
            markers: markers
        )
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor class Coordinator: NSObject, @preconcurrency MLNMapViewDelegate {
        var onMapTap: ((CLLocationCoordinate2D) -> Void)?
        private var currentAnnotations: [String: MLNPointAnnotation] = [:]
        private var markerColors: [String: String] = [:]
        private var markerPhotos: [String: UIImage] = [:]
        // Trails are rendered as style layers (MLNShapeSource + MLNLineStyleLayer)
        // rather than legacy annotations, because annotation polylines can be
        // hidden by manually-added raster style layers due to z-order quirks.
        // One source + one line layer per tracker so each trail can have its
        // own color expression.
        private var trailSources: [UInt32: MLNShapeSource] = [:]
        private var trailLayers: [UInt32: MLNLineStyleLayer] = [:]
        private var fenceSources: [UUID: MLNShapeSource] = [:]
        private var fenceFillLayers: [UUID: MLNFillStyleLayer] = [:]
        private var fenceLineLayers: [UUID: MLNLineStyleLayer] = [:]
        /// Identifies the currently-rendered tiles: an offline file path or
        /// "online:<source id>". We only rebuild the raster stack when it changes.
        private var appliedTileKey: String?
        /// Style ids of the raster source(s)/layer(s) we added, so we remove
        /// exactly those on the next swap. Made unique per swap (via the counter)
        /// so MapLibre never serves stale tiles cached under a recycled id.
        private var currentSourceIDs: [String] = []
        private var currentLayerIDs: [String] = []
        private var tileSwapCounter = 0
        /// Latest source/path requested by the parent, re-applied once the
        /// style finishes loading (updateUIView can run before that).
        private var desiredOnlineSource: MapSource = .bkgTopPlus
        private var desiredOfflinePath: String?
        private weak var mapViewRef: MLNMapView?
        /// Last fit-to-bounds request honored. We only act when the ID changes.
        private var lastFitID: UUID?

        override init() {
            super.init()
            NotificationCenter.default.addObserver(
                self, selector: #selector(handleWillDeleteTiles),
                name: .willDeleteTileRegion, object: nil
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        /// Remove the tile source before the mbtiles file is deleted to prevent
        /// MapLibre's SQLite handle from crashing on a deleted vnode. We also
        /// clear `desiredOfflinePath` so any immediate re-apply falls back to
        /// the online source rather than the file that's about to vanish; the
        /// parent's next `updateUIView` supplies the correct replacement.
        @objc private func handleWillDeleteTiles() {
            desiredOfflinePath = nil
            appliedTileKey = nil
            guard let style = mapViewRef?.style else { return }
            removeTileLayers(from: style)
        }

        private func removeTileLayers(from style: MLNStyle) {
            for id in currentLayerIDs where style.layer(withIdentifier: id) != nil {
                style.removeLayer(style.layer(withIdentifier: id)!)
            }
            for id in currentSourceIDs {
                if let source = style.source(withIdentifier: id) { style.removeSource(source) }
            }
            currentLayerIDs.removeAll()
            currentSourceIDs.removeAll()
        }

        /// Fit the viewport to include the user location + every marker.
        /// No-op if the request ID matches the last one we honored, or if
        /// we have nothing to show.
        func handleFitRequest(on mapView: MLNMapView, id: UUID?, markers: [DogMarker]) {
            guard let id, id != lastFitID else { return }

            var coords = markers.map {
                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            }
            if let userLoc = mapView.userLocation?.coordinate,
               CLLocationCoordinate2DIsValid(userLoc),
               !(userLoc.latitude == 0 && userLoc.longitude == 0) {
                coords.append(userLoc)
            }
            guard !coords.isEmpty else { return }
            lastFitID = id

            if coords.count == 1 {
                // One point — just center, keep current zoom (or jump to 14 if fully out)
                mapView.setCenter(coords[0],
                                  zoomLevel: max(mapView.zoomLevel, 13),
                                  animated: true)
                return
            }

            var minLat = coords[0].latitude, maxLat = coords[0].latitude
            var minLon = coords[0].longitude, maxLon = coords[0].longitude
            for c in coords.dropFirst() {
                minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
                minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
            }
            let sw = CLLocationCoordinate2D(latitude: minLat, longitude: minLon)
            let ne = CLLocationCoordinate2D(latitude: maxLat, longitude: maxLon)
            let bounds = MLNCoordinateBounds(sw: sw, ne: ne)
            // Generous padding so markers don't sit under the status bar or FAB.
            let insets = UIEdgeInsets(top: 100, left: 60, bottom: 120, right: 60)
            mapView.setVisibleCoordinateBounds(bounds, edgePadding: insets, animated: true)
        }

        func updateMarkers(on mapView: MLNMapView, markers: [DogMarker]) {
            mapViewRef = mapView
            var nextIDs = Set<String>()

            for marker in markers {
                let key = "\(marker.nodeNum)"
                nextIDs.insert(key)
                markerColors[key] = marker.colorHex

                // Cache photo image (decode once)
                let hadPhoto = markerPhotos[key] != nil
                if let data = marker.photoData, let img = UIImage(data: data) {
                    markerPhotos[key] = img
                } else {
                    markerPhotos.removeValue(forKey: key)
                }
                let hasPhoto = markerPhotos[key] != nil
                let photoChanged = hadPhoto != hasPhoto

                let coord = CLLocationCoordinate2D(latitude: marker.latitude, longitude: marker.longitude)

                if let existing = currentAnnotations[key] {
                    existing.coordinate = coord
                    existing.title = marker.name
                    existing.subtitle = marker.subtitle

                    // Force annotation view refresh if photo was added/removed
                    if photoChanged {
                        mapView.removeAnnotation(existing)
                        mapView.addAnnotation(existing)
                    }
                } else {
                    let ann = MLNPointAnnotation()
                    ann.coordinate = coord
                    ann.title = marker.name
                    ann.subtitle = marker.subtitle
                    mapView.addAnnotation(ann)
                    currentAnnotations[key] = ann
                }
            }

            for (key, ann) in currentAnnotations where !nextIDs.contains(key) {
                mapView.removeAnnotation(ann)
                currentAnnotations.removeValue(forKey: key)
                markerColors.removeValue(forKey: key)
                markerPhotos.removeValue(forKey: key)
            }
        }

        func updateTrails(on mapView: MLNMapView, trails: [DogTrail]) {
            guard let style = mapView.style else { return }
            var nextIDs = Set<UInt32>()

            for trail in trails {
                guard trail.coordinates.count >= 2 else { continue }
                nextIDs.insert(trail.nodeNum)

                var coords = trail.coordinates.map {
                    CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
                }

                // Diagnostic: log span so we can tell "invisible trail" from
                // "trail too short to see" at a glance.
                let lats = coords.map(\.latitude)
                let lons = coords.map(\.longitude)
                let latSpan = (lats.max() ?? 0) - (lats.min() ?? 0)
                let lonSpan = (lons.max() ?? 0) - (lons.min() ?? 0)
                let approxMeters = max(latSpan, lonSpan) * 111_000
                mapLog.info("[Trail] node=\(String(format: "%08x", trail.nodeNum)) points=\(coords.count) span≈\(Int(approxMeters))m")

                let polyline = MLNPolylineFeature(coordinates: &coords, count: UInt(coords.count))

                if let source = trailSources[trail.nodeNum] {
                    source.shape = polyline
                } else {
                    // First time we've seen this tracker — create source + layer.
                    let sourceID = "trail-src-\(trail.nodeNum)"
                    let layerID = "trail-lyr-\(trail.nodeNum)"
                    let source = MLNShapeSource(identifier: sourceID,
                                                shape: polyline,
                                                options: nil)
                    style.addSource(source)
                    trailSources[trail.nodeNum] = source

                    let layer = MLNLineStyleLayer(identifier: layerID, source: source)
                    layer.lineColor = NSExpression(
                        forConstantValue: UIColor(hex: trail.colorHex) ?? .systemRed
                    )
                    layer.lineWidth = NSExpression(forConstantValue: 5)
                    layer.lineOpacity = NSExpression(forConstantValue: 0.9)
                    layer.lineCap = NSExpression(forConstantValue: "round")
                    layer.lineJoin = NSExpression(forConstantValue: "round")
                    style.addLayer(layer)
                    trailLayers[trail.nodeNum] = layer
                }
            }

            // Remove sources + layers for trackers no longer present.
            for (nodeNum, layer) in trailLayers where !nextIDs.contains(nodeNum) {
                style.removeLayer(layer)
                trailLayers.removeValue(forKey: nodeNum)
            }
            for (nodeNum, source) in trailSources where !nextIDs.contains(nodeNum) {
                style.removeSource(source)
                trailSources.removeValue(forKey: nodeNum)
            }
        }

        func updateFences(on mapView: MLNMapView, fences: [FenceOverlay]) {
            guard let style = mapView.style else { return }
            var nextIDs = Set<UUID>()

            for fence in fences {
                nextIDs.insert(fence.id)

                var coords = CircleGeometry.polygon(
                    center: CLLocationCoordinate2D(latitude: fence.centerLatitude,
                                                   longitude: fence.centerLongitude),
                    radiusMeters: fence.radiusMeters
                )
                let polygon = MLNPolygonFeature(coordinates: &coords, count: UInt(coords.count))
                let color = UIColor(hex: fence.colorHex) ?? .systemRed

                if let source = fenceSources[fence.id] {
                    source.shape = polygon
                    if let fill = fenceFillLayers[fence.id] {
                        fill.fillColor = NSExpression(forConstantValue: color.withAlphaComponent(0.15))
                    }
                    if let line = fenceLineLayers[fence.id] {
                        line.lineColor = NSExpression(forConstantValue: color)
                    }
                } else {
                    let sourceID = "fence-src-\(fence.id.uuidString)"
                    let fillID = "fence-fill-\(fence.id.uuidString)"
                    let lineID = "fence-line-\(fence.id.uuidString)"
                    let source = MLNShapeSource(identifier: sourceID, shape: polygon, options: nil)
                    style.addSource(source)
                    fenceSources[fence.id] = source

                    let fill = MLNFillStyleLayer(identifier: fillID, source: source)
                    fill.fillColor = NSExpression(forConstantValue: color.withAlphaComponent(0.15))
                    fill.fillOutlineColor = NSExpression(forConstantValue: color)
                    style.addLayer(fill)
                    fenceFillLayers[fence.id] = fill

                    let line = MLNLineStyleLayer(identifier: lineID, source: source)
                    line.lineColor = NSExpression(forConstantValue: color)
                    line.lineWidth = NSExpression(forConstantValue: 2.5)
                    line.lineDashPattern = NSExpression(forConstantValue: [4, 2])
                    style.addLayer(line)
                    fenceLineLayers[fence.id] = line
                }
            }

            for (id, layer) in fenceFillLayers where !nextIDs.contains(id) {
                style.removeLayer(layer)
                fenceFillLayers.removeValue(forKey: id)
            }
            for (id, layer) in fenceLineLayers where !nextIDs.contains(id) {
                style.removeLayer(layer)
                fenceLineLayers.removeValue(forKey: id)
            }
            for (id, source) in fenceSources where !nextIDs.contains(id) {
                style.removeSource(source)
                fenceSources.removeValue(forKey: id)
            }
        }

        @objc func handleMapTap(_ gesture: UITapGestureRecognizer) {
            guard let onMapTap, let mapView = gesture.view as? MLNMapView,
                  gesture.state == .ended else { return }
            let point = gesture.location(in: mapView)
            let coord = mapView.convert(point, toCoordinateFrom: mapView)
            onMapTap(coord)
        }

        // Trail polylines are rendered via MLNShapeSource + MLNLineStyleLayer
        // (see updateTrails). Colors / widths are set on the style layer
        // directly; no shape-annotation delegate methods are needed.

        func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            // Returning a view for a multi-point shape (polylines, polygons)
            // makes MapLibre treat the shape as a single-point view
            // annotation pinned to its first coordinate, which silently
            // suppresses the line/fill rendering. Bail out for those —
            // they go through the strokeColor / lineWidth delegate path
            // instead. NOTE: do NOT filter on MLNShape here, because
            // MLNPointAnnotation is also a subclass of MLNShape — that
            // would suppress the dog markers themselves.
            guard !(annotation is MLNUserLocation),
                  !(annotation is MLNMultiPoint) else { return nil }

            let size: CGFloat = 40
            let view = MLNAnnotationView(reuseIdentifier: nil) // no reuse, photos differ
            view.frame = CGRect(x: 0, y: 0, width: size, height: size)
            view.subviews.forEach { $0.removeFromSuperview() }

            let color = annotationColor(annotation)
            let photo = annotationPhoto(annotation)

            let circle = UIView(frame: view.bounds)
            circle.layer.cornerRadius = size / 2
            circle.clipsToBounds = true
            circle.layer.borderColor = UIColor.white.cgColor
            circle.layer.borderWidth = 2.5

            if let photo {
                // Dog photo as marker
                let imageView = UIImageView(frame: circle.bounds)
                imageView.image = photo
                imageView.contentMode = .scaleAspectFill
                imageView.clipsToBounds = true
                circle.addSubview(imageView)
                // Tinted border from tracker color
                circle.layer.borderColor = color.cgColor
            } else {
                // Colored circle with initial
                circle.backgroundColor = color

                let label = UILabel(frame: circle.bounds)
                label.text = String((annotation.title ?? "?")?.prefix(1) ?? "?")
                label.textAlignment = .center
                label.textColor = .white
                label.font = .boldSystemFont(ofSize: 16)
                circle.addSubview(label)
            }

            view.addSubview(circle)
            return view
        }

        func mapView(_ mapView: MLNMapView, annotationCanShowCallout annotation: MLNAnnotation) -> Bool {
            // Only point annotations should show callouts. Polylines /
            // polygons get tapped along their geometry which would yield
            // a confusing callout location. Use MLNMultiPoint here, not
            // MLNShape — MLNPointAnnotation is also a MLNShape.
            !(annotation is MLNMultiPoint)
        }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            mapViewRef = mapView
            // The style is now ready — (re)apply whatever the parent last asked
            // for. `appliedTileKey` is nil here on first load, so this always
            // adds the layer.
            applyResolvedTileSource(to: style)
        }

        /// Render `offlineTilePath` if set, otherwise `onlineSource`. Rebuilds
        /// the raster source/layer only when the effective tiles change. Safe to
        /// call before the style loads — it stores the request and no-ops until
        /// `didFinishLoading` applies it.
        func applyTileSource(on mapView: MLNMapView, onlineSource: MapSource, offlineTilePath: String?) {
            mapViewRef = mapView
            desiredOnlineSource = onlineSource
            desiredOfflinePath = offlineTilePath
            guard let style = mapView.style else { return }
            applyResolvedTileSource(to: style)
        }

        private func applyResolvedTileSource(to style: MLNStyle) {
            let key = desiredOfflinePath.map { "offline:\($0)" } ?? "online:\(desiredOnlineSource.id)"
            guard key != appliedTileKey else { return }
            appliedTileKey = key

            removeTileLayers(from: style)
            tileSwapCounter += 1
            let gen = tileSwapCounter

            // Build the raster stack, bottom-first. For an online source that
            // only partially covers the map (basemap.at = Austria only), draw its
            // worldwide underlay (BKG) beneath it so there are never blank tiles.
            var specs: [(templates: [String], minZoom: Int?, maxZoom: Int?)] = []
            if let path = desiredOfflinePath {
                specs.append((["mbtiles://\(path)"], nil, nil))
            } else {
                if let under = desiredOnlineSource.underlay {
                    specs.append(([under.tileURLTemplate], under.minZoom, under.maxZoom))
                }
                specs.append(([desiredOnlineSource.tileURLTemplate],
                              desiredOnlineSource.minZoom, desiredOnlineSource.maxZoom))
            }

            // Keep the whole basemap stack beneath trails / fences (markers are
            // annotation views and always render on top). On first load there are
            // no content layers, so the stack is added on top of the background.
            let anchor = style.layers.first { !($0 is MLNBackgroundStyleLayer) }
            var previous: MLNStyleLayer?
            for (i, spec) in specs.enumerated() {
                let sid = "topo-src-\(gen)-\(i)"
                let lid = "topo-lyr-\(gen)-\(i)"
                var options: [MLNTileSourceOption: Any] = [.tileSize: 256]
                if let mn = spec.minZoom { options[.minimumZoomLevel] = mn }
                if let mx = spec.maxZoom { options[.maximumZoomLevel] = mx }
                let src = MLNRasterTileSource(identifier: sid, tileURLTemplates: spec.templates, options: options)
                style.addSource(src)
                currentSourceIDs.append(sid)

                let layer = MLNRasterStyleLayer(identifier: lid, source: src)
                if let previous {
                    style.insertLayer(layer, above: previous)   // stack upward
                } else if let anchor {
                    style.insertLayer(layer, below: anchor)      // bottom of content
                } else {
                    style.addLayer(layer)
                }
                currentLayerIDs.append(lid)
                previous = layer
            }
        }

        private func annotationColor(_ annotation: MLNAnnotation) -> UIColor {
            for (key, ann) in currentAnnotations {
                if ann === annotation, let hex = markerColors[key] {
                    return UIColor(hex: hex) ?? .systemGreen
                }
            }
            return .systemGreen
        }

        private func annotationPhoto(_ annotation: MLNAnnotation) -> UIImage? {
            for (key, ann) in currentAnnotations {
                if ann === annotation {
                    return markerPhotos[key]
                }
            }
            return nil
        }
    }
}

/// Data for one dog marker on the map.
struct DogMarker: Equatable {
    let nodeNum: UInt32
    let name: String
    let colorHex: String
    let latitude: Double
    let longitude: Double
    let subtitle: String
    let photoData: Data?
}

/// Drawable representation of a geofence on the map.
struct FenceOverlay: Equatable, Identifiable {
    let id: UUID
    let centerLatitude: Double
    let centerLongitude: Double
    let radiusMeters: Double
    let colorHex: String
}

/// Trail data for drawing movement history polylines.
struct DogTrail: Equatable {
    let nodeNum: UInt32
    let colorHex: String
    let coordinates: [(lat: Double, lon: Double)]

    static func == (lhs: DogTrail, rhs: DogTrail) -> Bool {
        lhs.nodeNum == rhs.nodeNum && lhs.colorHex == rhs.colorHex
            && lhs.coordinates.count == rhs.coordinates.count
    }
}

// MARK: - Attribution

/// Small tappable attribution chip shown over the map. Crediting the tile
/// provider is required by the basemap.at (CC-BY 4.0) and BKG (dl-de/by-2-0)
/// licenses; we credit USGS too.
struct MapAttributionLabel: View {
    let source: MapSource
    /// Whether to also credit the underlay provider (true for the live map,
    /// which renders the underlay; false for single-source views like the
    /// download picker and offline tiles).
    var includeUnderlay = true
    @Environment(\.openURL) private var openURL

    private var text: String { includeUnderlay ? source.attributionLine : source.attribution }

    var body: some View {
        Button {
            if let url = source.attributionURL { openURL(url) }
        } label: {
            Text(text)
                .font(.caption2)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Map data: \(text)")
    }
}

// MARK: - UIColor hex parsing

extension UIColor {
    convenience init?(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(
            red: CGFloat((v >> 16) & 0xff) / 255,
            green: CGFloat((v >> 8) & 0xff) / 255,
            blue: CGFloat(v & 0xff) / 255,
            alpha: 1
        )
    }
}
