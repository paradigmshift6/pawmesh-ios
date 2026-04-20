import WidgetKit
import Foundation
import CoreLocation

/// A single point in the complication's timeline. We expose the closest
/// dog (by straight-line distance to the last-known phone location) plus
/// all trackers so rectangular complications can list multiple.
struct ComplicationEntry: TimelineEntry {
    let date: Date
    let snapshot: FleetSnapshot
    /// The tracker with the shortest great-circle distance to the user,
    /// or nil if no trackers have a fix or no user location is available.
    let closest: TrackerSnapshot?
    let closestMeters: Double?

    static let placeholder = ComplicationEntry(
        date: .now,
        snapshot: .empty,
        closest: nil,
        closestMeters: nil
    )
}

enum ComplicationSelector {
    /// Pick the tracker with the smallest distance from the user that has
    /// a valid fix. Returns nil if there's no user location, or no
    /// tracker has reported a position yet.
    static func closest(in snapshot: FleetSnapshot) -> (TrackerSnapshot, Double)? {
        guard let user = snapshot.userLocation else { return nil }
        let userCoord = CLLocationCoordinate2D(
            latitude: user.latitude,
            longitude: user.longitude
        )
        var best: (TrackerSnapshot, Double)?
        for t in snapshot.trackers {
            guard let fix = t.lastFix else { continue }
            let meters = BearingMath.distance(
                from: userCoord,
                to: CLLocationCoordinate2D(latitude: fix.latitude, longitude: fix.longitude)
            )
            if best == nil || meters < best!.1 {
                best = (t, meters)
            }
        }
        return best
    }
}
