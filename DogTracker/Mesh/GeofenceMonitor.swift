import Foundation
import CoreLocation
import SwiftData
import UserNotifications
import OSLog

/// Evaluates incoming dog positions against the user's geofences and fires a
/// local notification on each inside → outside transition.
///
/// We can't use CoreLocation's `CLCircularRegion` monitoring because that API
/// watches the *device's* own location — the dog positions arrive over BLE
/// from the mesh. Instead the check runs inline whenever `MeshService`
/// receives a new position.
@MainActor
final class GeofenceMonitor {
    private let modelContainer: ModelContainer
    private let log = Logger(subsystem: "com.levijohnson.DogTracker", category: "Geofence")

    /// Last known inside/outside state, keyed by `(fenceID, trackerNodeNum)`.
    /// `nil` means we haven't evaluated this pair yet — the first fix seeds
    /// the state without firing a notification.
    private var states: [StateKey: Bool] = [:]

    /// Don't notify on a fix older than this — avoids a stale catch-up packet
    /// firing an alert when the dog is actually back inside the fence.
    /// Generous enough for multi-hop mesh retries (trackers broadcast every
    /// 2 min, but a packet can take a while to find the user through a hop).
    private let staleFixCutoff: TimeInterval = 15 * 60

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// Evaluate the new fix against every enabled fence that applies to this
    /// tracker. Safe to call from `MeshService` on the main actor.
    func evaluate(
        nodeNum: UInt32,
        latitude: Double,
        longitude: Double,
        fixTime: Date,
        trackerName: String
    ) {
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<Geofence>(
            predicate: #Predicate { $0.isEnabled }
        )
        guard let fences = try? context.fetch(descriptor), !fences.isEmpty else {
            return
        }

        let now = Date()
        let fixIsStale = now.timeIntervalSince(fixTime) > staleFixCutoff
        let fixLocation = CLLocation(latitude: latitude, longitude: longitude)

        for fence in fences where fence.applies(to: nodeNum) {
            let center = CLLocation(latitude: fence.centerLatitude,
                                    longitude: fence.centerLongitude)
            let distance = fixLocation.distance(from: center)

            // Hysteresis: a dog has to come back in by `hysteresis` meters
            // beyond the radius before we consider them re-entered. Avoids
            // flapping notifications when GPS noise sits the dog right on
            // the boundary. Scales with radius (10%) but capped so the
            // deadband never dominates a small fence or grows unbounded
            // on a huge one. Floor of 3m matches roughly the best-case
            // GPS noise we'll see from a clear-sky tracker fix.
            let hysteresis = max(3.0, min(fence.radiusMeters * 0.1, 50.0))
            let key = StateKey(fenceID: fence.id, nodeNum: nodeNum)
            let wasInside = states[key]

            let isInside: Bool
            switch wasInside {
            case .some(true):
                isInside = distance <= fence.radiusMeters + hysteresis
            case .some(false):
                isInside = distance <= fence.radiusMeters - hysteresis
            case .none:
                // First evaluation — strict boundary, no notification.
                isInside = distance <= fence.radiusMeters
            }

            states[key] = isInside

            guard let wasInside else {
                log.info("seeded state for fence=\(fence.name) tracker=\(nodeNum, format: .hex) inside=\(isInside)")
                continue
            }

            if wasInside && !isInside {
                log.info("EXIT fence=\(fence.name) tracker=\(trackerName) dist=\(Int(distance))m radius=\(Int(fence.radiusMeters))m")
                recordEvent(
                    fence: fence, nodeNum: nodeNum, transition: .exited,
                    fixTime: fixTime, latitude: latitude, longitude: longitude,
                    context: context
                )
                if !fixIsStale {
                    scheduleNotification(
                        fence: fence, trackerName: trackerName,
                        distance: distance, fixTime: fixTime,
                        nodeNum: nodeNum, latitude: latitude, longitude: longitude
                    )
                }
            } else if !wasInside && isInside {
                log.info("ENTRY fence=\(fence.name) tracker=\(trackerName) dist=\(Int(distance))m")
                recordEvent(
                    fence: fence, nodeNum: nodeNum, transition: .entered,
                    fixTime: fixTime, latitude: latitude, longitude: longitude,
                    context: context
                )
            }
        }
    }

    /// Clear cached state for a fence (called when the fence is edited or
    /// deleted so the next fix re-seeds rather than firing on a center change).
    func resetState(for fenceID: UUID) {
        states = states.filter { $0.key.fenceID != fenceID }
    }

    // MARK: - Private

    private func recordEvent(
        fence: Geofence,
        nodeNum: UInt32,
        transition: GeofenceTransition,
        fixTime: Date,
        latitude: Double,
        longitude: Double,
        context: ModelContext
    ) {
        let event = GeofenceEvent(
            fence: fence,
            trackerNodeNum: nodeNum,
            transition: transition,
            fixTime: fixTime,
            latitude: latitude,
            longitude: longitude
        )
        context.insert(event)
        do {
            try context.save()
        } catch {
            log.error("failed to save geofence event: \(error.localizedDescription)")
        }
    }

    private func scheduleNotification(
        fence: Geofence,
        trackerName: String,
        distance: Double,
        fixTime: Date,
        nodeNum: UInt32,
        latitude: Double,
        longitude: Double
    ) {
        let content = UNMutableNotificationContent()
        content.title = "\(trackerName) left \(fence.name)"
        content.body = notificationBody(distance: distance, fixTime: fixTime, radius: fence.radiusMeters)
        content.sound = .default
        content.categoryIdentifier = NotificationCategory.geofenceExit
        content.userInfo = [
            "nodeNum": NSNumber(value: nodeNum),
            "latitude": latitude,
            "longitude": longitude,
            "fenceID": fence.id.uuidString,
        ]

        let request = UNNotificationRequest(
            identifier: "geofence-exit-\(fence.id.uuidString)-\(Int(fixTime.timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { [log] error in
            if let error {
                log.error("failed to schedule notification: \(error.localizedDescription)")
            }
        }
    }

    private func notificationBody(distance: Double, fixTime: Date, radius: Double) -> String {
        let metersOut = Int(distance - radius)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let when = formatter.localizedString(for: fixTime, relativeTo: Date())
        if metersOut > 0 {
            return "\(metersOut)m beyond the fence (\(when))"
        }
        return "Crossed the fence boundary (\(when))"
    }

    private struct StateKey: Hashable {
        let fenceID: UUID
        let nodeNum: UInt32
    }
}

/// Notification categories used by the app. Kept here so the app delegate
/// and the monitor agree on the identifier.
enum NotificationCategory {
    static let geofenceExit = "geofence-exit"
}
