import SwiftUI
import MapLibre

/// SwiftUI wrapper around MapLibre's `MLNMapView`. Shows:
///   - USGS topo tiles: offline MBTiles when available, online fallback otherwise.
///   - The user's current location (built-in blue dot).
///   - Dog tracker markers as colored circles with photo or initial.
struct DogMapView: UIViewRepresentable {

    let markers: [DogMarker]
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

        if let center = centerOn {
            mapView.setCenter(center, zoomLevel: max(mapView.zoomLevel, 14), animated: true)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, MLNMapViewDelegate {
        private var currentAnnotations: [String: MLNPointAnnotation] = [:]
        private var markerColors: [String: String] = [:]
        private var tileSourceAdded = false

        func updateMarkers(on mapView: MLNMapView, markers: [DogMarker]) {
            var nextIDs = Set<String>()

            for marker in markers {
                let key = "\(marker.nodeNum)"
                nextIDs.insert(key)
                markerColors[key] = marker.colorHex

                let coord = CLLocationCoordinate2D(latitude: marker.latitude, longitude: marker.longitude)

                if let existing = currentAnnotations[key] {
                    existing.coordinate = coord
                    existing.title = marker.name
                    existing.subtitle = marker.subtitle
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
            }
        }

        func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            guard !(annotation is MLNUserLocation) else { return nil }

            let view = mapView.dequeueReusableAnnotationView(withIdentifier: "dog")
                ?? MLNAnnotationView(reuseIdentifier: "dog")
            view.frame = CGRect(x: 0, y: 0, width: 36, height: 36)

            let color = annotationColor(annotation)

            let circle = UIView(frame: view.bounds)
            circle.backgroundColor = color
            circle.layer.cornerRadius = 18
            circle.layer.borderColor = UIColor.white.cgColor
            circle.layer.borderWidth = 2

            let label = UILabel(frame: view.bounds)
            label.text = String((annotation.title ?? "?")?.prefix(1) ?? "?")
            label.textAlignment = .center
            label.textColor = .white
            label.font = .boldSystemFont(ofSize: 16)

            view.subviews.forEach { $0.removeFromSuperview() }
            view.addSubview(circle)
            view.addSubview(label)

            return view
        }

        func mapView(_ mapView: MLNMapView, annotationCanShowCallout annotation: MLNAnnotation) -> Bool {
            true
        }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            guard !tileSourceAdded else { return }
            tileSourceAdded = true
            addTileSource(to: style)
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
            // Find by matching annotation key in our marker colors map
            for (key, ann) in currentAnnotations {
                if ann === annotation, let hex = markerColors[key] {
                    return UIColor(hex: hex) ?? .systemGreen
                }
            }
            return .systemGreen
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
