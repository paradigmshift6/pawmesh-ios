import Foundation
import Observation
import UserNotifications
import CoreLocation
import OSLog

/// Thin wrapper over `UNUserNotificationCenter` for permission flow,
/// foreground presentation, and notification-tap deep linking.
@MainActor
@Observable
final class NotificationAuthorization: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationAuthorization()

    /// Set when the user taps a geofence notification. MapScreen observes this
    /// and re-centers + selects the dog. We clear it after consuming.
    var pendingDeepLink: GeofenceDeepLink?

    private let log = Logger(subsystem: "com.levijohnson.DogTracker", category: "Notify")

    override private init() {
        super.init()
    }

    /// Install ourselves as the delegate. Call once at app start.
    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Request alert / sound / badge permission. Returns true if granted.
    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound, .badge]
            )
            log.info("notification authorization granted=\(granted)")
            return granted
        } catch {
            log.error("notification authorization failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Current authorization status.
    func authorizationStatus() async -> UNAuthorizationStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show banner + sound even when the app is open — these alerts are
        // safety-relevant so we never want to silently drop them.
        completionHandler([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Decode the payload synchronously into a Sendable struct so the
        // actor hop captures only value types — avoids the [AnyHashable: Any]
        // Sendable warning under strict concurrency.
        let userInfo = response.notification.request.content.userInfo
        let link = GeofenceDeepLink(userInfo: userInfo)
        Task { @MainActor in
            self.pendingDeepLink = link
        }
        completionHandler()
    }
}

/// Payload extracted from a geofence notification's `userInfo`, used to
/// route the map view to the dog that crossed the fence.
struct GeofenceDeepLink: Equatable, Sendable {
    let nodeNum: UInt32
    let latitude: Double
    let longitude: Double

    init?(userInfo: [AnyHashable: Any]) {
        guard let n = (userInfo["nodeNum"] as? NSNumber)?.uint32Value
                ?? (userInfo["nodeNum"] as? UInt32),
              let lat = userInfo["latitude"] as? Double,
              let lon = userInfo["longitude"] as? Double else { return nil }
        self.nodeNum = n
        self.latitude = lat
        self.longitude = lon
    }
}
