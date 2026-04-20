import Foundation
import WatchKit
import WidgetKit

/// Handles watchOS background refresh tasks so the cached FleetSnapshot
/// + complication stay warm when the user lifts their wrist.
///
/// watchOS only gives background apps a handful of short bursts per
/// hour; we use each one to (a) ask WatchConnectivity for any queued
/// applicationContext updates and (b) reload the widget timelines so
/// the fix-age color tier on the complication stays accurate.
@MainActor
final class WatchBackgroundRefreshHandler: NSObject, WKApplicationDelegate {

    /// Scheduler keeps one pending task in flight at any time. ~15 min
    /// gives us four refreshes per hour in the worst case (Apple may
    /// slip this based on battery / usage).
    private static let refreshInterval: TimeInterval = 15 * 60

    func applicationDidFinishLaunching() {
        scheduleNextRefresh()
    }

    nonisolated func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            switch task {
            case let refresh as WKApplicationRefreshBackgroundTask:
                Task { @MainActor in
                    // Widget timeline recalc picks up the latest snapshot
                    // from SharedSnapshotStore (written by WatchSession
                    // whenever a WC applicationContext arrives).
                    WidgetCenter.shared.reloadAllTimelines()
                    self.scheduleNextRefresh()
                    refresh.setTaskCompletedWithSnapshot(false)
                }
            default:
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }

    func scheduleNextRefresh() {
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: Date().addingTimeInterval(Self.refreshInterval),
            userInfo: nil
        ) { error in
            if let error {
                print("[WatchBackgroundRefresh] schedule failed: \(error.localizedDescription)")
            }
        }
    }
}
