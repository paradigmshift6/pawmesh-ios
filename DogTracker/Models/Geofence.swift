import Foundation
import SwiftData

/// A circular geofence the user has drawn on the map. When a tracked dog's
/// position crosses outside the radius we fire a local notification.
@Model
final class Geofence {
    @Attribute(.unique) var id: UUID

    var name: String
    var centerLatitude: Double
    var centerLongitude: Double
    /// Radius in meters. UI clamps to a sensible range (~50…2000).
    var radiusMeters: Double

    var isEnabled: Bool
    /// Hex color for map rendering ("#RRGGBB").
    var colorHex: String
    var createdAt: Date

    /// Tracker node numbers this fence applies to. Empty array means
    /// "applies to every tracked dog" (the default).
    var appliesToNodeNums: [UInt32]

    /// Crossing history. Cascade so deleting a fence drops its events —
    /// otherwise stale event rows linger and the editor's FenceEventsList
    /// query can read deleted objects.
    @Relationship(deleteRule: .cascade, inverse: \GeofenceEvent.fence)
    var events: [GeofenceEvent] = []

    init(
        id: UUID = UUID(),
        name: String,
        centerLatitude: Double,
        centerLongitude: Double,
        radiusMeters: Double,
        isEnabled: Bool = true,
        colorHex: String = "#FF3B30",
        createdAt: Date = .now,
        appliesToNodeNums: [UInt32] = []
    ) {
        self.id = id
        self.name = name
        self.centerLatitude = centerLatitude
        self.centerLongitude = centerLongitude
        self.radiusMeters = radiusMeters
        self.isEnabled = isEnabled
        self.colorHex = colorHex
        self.createdAt = createdAt
        self.appliesToNodeNums = appliesToNodeNums
    }

    /// True if this fence applies to the given tracker. Empty applies-to list
    /// means "all dogs".
    func applies(to nodeNum: UInt32) -> Bool {
        appliesToNodeNums.isEmpty || appliesToNodeNums.contains(nodeNum)
    }
}
