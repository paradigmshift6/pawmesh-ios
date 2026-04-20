import WidgetKit
import Foundation
import CoreLocation

/// A single point in the complication's timeline. We expose the closest
/// dog (by straight-line distance to the last-known phone location) plus
/// the bearing/heading-relative arrow angle so the complication can
/// render a direction indicator, not just a number.
struct ComplicationEntry: TimelineEntry {
    let date: Date
    let snapshot: FleetSnapshot
    /// The tracker with the shortest great-circle distance to the user,
    /// or nil if no trackers have a fix or no user location is available.
    let closest: TrackerSnapshot?
    let closestMeters: Double?
    /// True compass bearing from user → closest dog, 0..360 (0 = north).
    /// nil if we don't have a user location or fix.
    let closestBearing: Double?
    /// Display angle for the arrow on the complication. = bearing minus the
    /// phone's heading at last snapshot, so the arrow points "the way the
    /// dog is" relative to the user's last-known facing direction. nil if
    /// no heading was published with the snapshot — in that case
    /// `closestBearing` is the absolute compass bearing and views can
    /// fall back to that with a "N" indicator.
    let arrowAngle: Double?

    static let placeholder = ComplicationEntry(
        date: .now,
        snapshot: .empty,
        closest: nil,
        closestMeters: nil,
        closestBearing: nil,
        arrowAngle: nil
    )
}

enum ComplicationSelector {
    /// Pick the tracker with the smallest distance from the user that has
    /// a valid fix. Returns nil if there's no user location, or no
    /// tracker has reported a position yet.
    ///
    /// Returns: (tracker, distance in meters, bearing 0-360, arrow angle).
    /// `arrowAngle` is bearing minus the phone's heading; if the phone
    /// hasn't published a heading with the snapshot it'll be nil and
    /// callers should fall back to the absolute `bearing`.
    static func closest(in snapshot: FleetSnapshot)
        -> (tracker: TrackerSnapshot, meters: Double, bearing: Double, arrowAngle: Double?)?
    {
        guard let user = snapshot.userLocation else { return nil }
        let userCoord = CLLocationCoordinate2D(
            latitude: user.latitude,
            longitude: user.longitude
        )
        var best: (TrackerSnapshot, Double, Double, Double?)?
        for t in snapshot.trackers {
            guard let fix = t.lastFix else { continue }
            let dogCoord = CLLocationCoordinate2D(
                latitude: fix.latitude,
                longitude: fix.longitude
            )
            let meters = BearingMath.distance(from: userCoord, to: dogCoord)
            let bearing = BearingMath.bearing(from: userCoord, to: dogCoord)
            let arrow = user.trueHeading.map { bearing - $0 }
            if best == nil || meters < best!.1 {
                best = (t, meters, bearing, arrow)
            }
        }
        return best
    }
}
