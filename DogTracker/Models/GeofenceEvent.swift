import Foundation
import SwiftData

/// Kind of geofence transition. We only persist exit events for now; entries
/// are recorded too so the UI can show "returned at hh:mm" history.
enum GeofenceTransition: String, Codable {
    case exited
    case entered
}

/// One geofence crossing for one tracker. Used both as history (visible in
/// the fence detail UI) and to throttle duplicate notifications.
@Model
final class GeofenceEvent {
    var fence: Geofence?
    var trackerNodeNum: UInt32
    var transition: GeofenceTransition
    /// GPS time of the fix that triggered the event.
    var fixTime: Date
    var latitude: Double
    var longitude: Double

    init(
        fence: Geofence? = nil,
        trackerNodeNum: UInt32,
        transition: GeofenceTransition,
        fixTime: Date,
        latitude: Double,
        longitude: Double
    ) {
        self.fence = fence
        self.trackerNodeNum = trackerNodeNum
        self.transition = transition
        self.fixTime = fixTime
        self.latitude = latitude
        self.longitude = longitude
    }
}
