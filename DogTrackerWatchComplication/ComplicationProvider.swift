import WidgetKit
import Foundation

/// TimelineProvider that reads the latest FleetSnapshot from the App
/// Group's shared UserDefaults. The watch app calls
/// `WidgetCenter.shared.reloadAllTimelines()` whenever a new snapshot
/// lands, so the provider mostly just re-reads what's already there.
/// Fallback refresh every 15 minutes so the fix-age color tier advances
/// even if the watch app never launches.
struct ComplicationProvider: TimelineProvider {

    func placeholder(in context: Context) -> ComplicationEntry {
        .placeholder
    }

    func getSnapshot(in context: Context,
                     completion: @escaping (ComplicationEntry) -> Void) {
        completion(entry(from: SharedSnapshotStore.read()))
    }

    func getTimeline(in context: Context,
                     completion: @escaping (Timeline<ComplicationEntry>) -> Void) {
        let fleet = SharedSnapshotStore.read()
        let current = entry(from: fleet, at: .now)
        // Fallback refresh 15 min from now so the fix-age tier progresses
        // (green → yellow → red) even without a fresh phone push.
        let next = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [current], policy: .after(next)))
    }

    private func entry(from fleet: FleetSnapshot, at date: Date = .now) -> ComplicationEntry {
        let pick = ComplicationSelector.closest(in: fleet)
        return ComplicationEntry(
            date: date,
            snapshot: fleet,
            closest: pick?.0,
            closestMeters: pick?.1
        )
    }
}
