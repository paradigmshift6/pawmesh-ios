import SwiftUI
import MapLibre

/// Posted before an mbtiles file is deleted so the map can release its SQLite handle.
extension Notification.Name {
    static let willDeleteTileRegion = Notification.Name("willDeleteTileRegion")
    static let didDeleteTileRegion = Notification.Name("didDeleteTileRegion")
}

/// SwiftUI wrapper around MapLibre's `MLNMapView`. Shows:
///   - USGS topo tiles: offline MBTiles when available, online fallback otherwise.
///   - The user's current location (built-in blue dot).
///   - Dog tracker markers as colored circles with photo or initial.
struct DogMapView: UIViewRepresentable {

    let markers: [DogMarker]
    var trails: [DogTrail] = []
    var centerOn: CLLocationCoordinate2D?
    /// Optional path to an MBTiles file for offline topo tiles.
    var offlineTilePath: String?

    func makeUIView(context: Context) -> MLNMapView {
        let mapView = MLNMapView(frame: .zero)
        mapView.delegate = context.coordinator

        // Show user location (blue dot)
        mapView.showsUserLocation = true
        mapView.userTrackingMode = .follow
        mapView.setZoomLevel(13, animated: false)

        return mapView
    }

    func updateUIView(_ mapView: MLNMapView, context: Context) {
        context.coordinator.updateMarkers(on: mapView, markers: markers)
        context.coordinator.updateTrails(on: mapView, trails: trails)

        if let center = centerOn {
            mapView.setCenter(center, zoomLevel: max(mapView.zoomLevel, 14), animated: true)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, MLNMapViewDelegate {
        private var currentAnnotations: [String: MLNPointAnnotation] = [:]
        private var markerColors: [String: String] = [:]
        private var markerPhotos: [String: UIImage] = [:]
        private var currentTrails: [UInt32: MLNPolyline] = [:]
        private var trailColors: [UInt32: String] = [:]
        private var tileSourceAdded = false
        /// Path of the currently loaded mbtiles file, so we know if it changed.
        private var loadedMBTilesPath: String?
        private weak var mapViewRef: MLNMapView?

        override init() {
            super.init()
            NotificationCenter.default.addObserver(
                self, selector: #selector(handleWillDeleteTiles),
                name: .willDeleteTileRegion, object: nil
            )
        }

        /// Remove the tile source before the mbtiles file is deleted to prevent
        /// MapLibre's SQLite handle from crashing on a deleted vnode.
        @objc private func handleWillDeleteTiles() {
            guard let style = mapViewRef?.style else { return }
            if let layer = style.layer(withIdentifier: "usgs-topo-layer") {
                style.removeLayer(layer)
            }
            if let source = style.source(withIdentifier: "usgs-topo") {
                style.removeSource(source)
            }
            loadedMBTilesPath = nil
            tileSourceAdded = false
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
            var nextIDs = Set<UInt32>()

            for trail in trails {
                guard trail.coordinates.count >= 2 else { continue }
                nextIDs.insert(trail.nodeNum)
                trailColors[trail.nodeNum] = trail.colorHex

                var coords = trail.coordinates.map {
                    CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
                }

                // Remove old polyline if coordinate count changed
                if let existing = currentTrails[trail.nodeNum] {
                    if existing.pointCount != UInt(coords.count) {
                        mapView.removeAnnotation(existing)
                        let polyline = MLNPolyline(coordinates: &coords, count: UInt(coords.count))
                        mapView.addAnnotation(polyline)
                        currentTrails[trail.nodeNum] = polyline
                    } else {
                        // Update coordinates in place
                        mapView.removeAnnotation(existing)
                        let polyline = MLNPolyline(coordinates: &coords, count: UInt(coords.count))
                        mapView.addAnnotation(polyline)
                        currentTrails[trail.nodeNum] = polyline
                    }
                } else {
                    let polyline = MLNPolyline(coordinates: &coords, count: UInt(coords.count))
                    mapView.addAnnotation(polyline)
                    currentTrails[trail.nodeNum] = polyline
                }
            }

            // Remove trails for trackers no longer present
            for (nodeNum, polyline) in currentTrails where !nextIDs.contains(nodeNum) {
                mapView.removeAnnotation(polyline)
                currentTrails.removeValue(forKey: nodeNum)
                trailColors.removeValue(forKey: nodeNum)
            }
        }

        func mapView(_ mapView: MLNMapView, strokeColorForShapeAnnotation annotation: MLNShape) -> UIColor {
            if let polyline = annotation as? MLNPolyline {
                // Find matching trail color
                for (nodeNum, trail) in currentTrails where trail === polyline {
                    if let hex = trailColors[nodeNum] {
                        return UIColor(hex: hex)?.withAlphaComponent(0.7) ?? .systemBlue
                    }
                }
            }
            return .systemBlue
        }

        func mapView(_ mapView: MLNMapView, lineWidthForPolylineAnnotation annotation: MLNPolyline) -> CGFloat {
            3.0
        }

        func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            guard !(annotation is MLNUserLocation) else { return nil }

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
            true
        }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            mapViewRef = mapView
            guard !tileSourceAdded else { return }
            tileSourceAdded = true
            addTileSource(to: style)

            // Re-add tile source after a deletion
            NotificationCenter.default.addObserver(
                forName: .didDeleteTileRegion, object: nil, queue: .main
            ) { [weak self] _ in
                guard let self, !self.tileSourceAdded else { return }
                self.tileSourceAdded = true
                self.addTileSource(to: style)
            }
        }

        private func addTileSource(to style: MLNStyle) {
            // Try offline MBTiles first
            guard let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
                .appendingPathComponent("TileRegions") else {
                addOnlineSource(to: style)
                return
            }
            if let files = try? FileManager.default.contentsOfDirectory(at: docsDir, includingPropertiesForKeys: nil),
               let first = files.first(where: { $0.pathExtension == "mbtiles" }) {
                let mbtURL = first.absoluteString
                let source = MLNRasterTileSource(
                    identifier: "usgs-topo",
                    tileURLTemplates: ["mbtiles://\(mbtURL)"],
                    options: [.tileSize: 256]
                )
                style.addSource(source)
                style.addLayer(MLNRasterStyleLayer(identifier: "usgs-topo-layer", source: source))
                return
            }

            // Online fallback
            addOnlineSource(to: style)
        }

        private func addOnlineSource(to style: MLNStyle) {
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
