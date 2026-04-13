import Foundation
import CoreLocation

enum BearingMath {

    /// Great-circle bearing from `from` to `to`, in degrees (0 = north, 90 = east).
    static func bearing(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let lat1 = from.latitude.radians
        let lat2 = to.latitude.radians
        let dLon = (to.longitude - from.longitude).radians

        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let rad = atan2(y, x)
        return (rad.degrees + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Haversine distance in meters between two coordinates.
    static func distance(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let R = 6_371_000.0 // Earth radius in meters
        let lat1 = from.latitude.radians
        let lat2 = to.latitude.radians
        let dLat = lat2 - lat1
        let dLon = (to.longitude - from.longitude).radians

        let a = sin(dLat / 2) * sin(dLat / 2) +
                cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return R * c
    }

    /// Human-readable distance string in metric units.
    static func distanceString(_ meters: Double, useMetric: Bool = true) -> String {
        if useMetric {
            if meters < 1000 {
                return "\(Int(meters)) m"
            } else {
                return String(format: "%.1f km", meters / 1000)
            }
        } else {
            let feet = meters * 3.28084
            if feet < 1000 {
                return "\(Int(feet)) ft"
            } else {
                let miles = meters / 1609.344
                return String(format: "%.1f mi", miles)
            }
        }
    }

    /// Human-readable altitude string.
    static func altitudeString(_ meters: Double, useMetric: Bool = true) -> String {
        if useMetric {
            return "\(Int(meters)) m"
        } else {
            return "\(Int(meters * 3.28084)) ft"
        }
    }
}

private extension Double {
    var radians: Double { self * .pi / 180 }
    var degrees: Double { self * 180 / .pi }
}
