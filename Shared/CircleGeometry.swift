import Foundation
import CoreLocation

/// Generate a closed polygon approximating a circle in meters around a
/// center coordinate. Used for rendering geofences on MapLibre, which has
/// no native meter-radius circle layer.
enum CircleGeometry {
    /// Returns `segments + 1` points (first and last equal) so the polygon
    /// closes cleanly. 64 segments is smooth enough at typical zoom levels.
    static func polygon(
        center: CLLocationCoordinate2D,
        radiusMeters: Double,
        segments: Int = 64
    ) -> [CLLocationCoordinate2D] {
        let earthRadius = 6_371_000.0
        let lat = center.latitude * .pi / 180
        let lon = center.longitude * .pi / 180
        let angularDistance = radiusMeters / earthRadius

        var points: [CLLocationCoordinate2D] = []
        points.reserveCapacity(segments + 1)

        for i in 0...segments {
            let bearing = Double(i) / Double(segments) * 2 * .pi
            let lat2 = asin(
                sin(lat) * cos(angularDistance)
                + cos(lat) * sin(angularDistance) * cos(bearing)
            )
            let lon2 = lon + atan2(
                sin(bearing) * sin(angularDistance) * cos(lat),
                cos(angularDistance) - sin(lat) * sin(lat2)
            )
            points.append(CLLocationCoordinate2D(
                latitude: lat2 * 180 / .pi,
                longitude: lon2 * 180 / .pi
            ))
        }
        return points
    }
}
