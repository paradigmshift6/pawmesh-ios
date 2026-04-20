import Foundation

/// Lightweight persistence bridge between the watch app (which receives
/// FleetSnapshot via WatchConnectivity) and the watch complication
/// extension (which needs to read the same data from a separate process).
///
/// Uses the App Group's shared UserDefaults suite. Snapshots are encoded
/// with the same ISO-8601 JSON format used on the wire so there's only
/// ever one serialization format in the codebase.
enum SharedSnapshotStore {

    /// App Group identifier — must match the entitlement on every target
    /// that reads or writes snapshots (iOS app, watch app, widget extension).
    static let appGroup = "group.com.levijohnson.DogTracker"

    private static let key = "latestFleetSnapshot"

    /// Shared UserDefaults suite. Returns nil on simulators without the
    /// entitlement configured — callers must tolerate that.
    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroup)
    }

    /// Write the latest snapshot so the widget can read it. Called from
    /// the watch app whenever a fresh FleetSnapshot arrives.
    static func write(_ snapshot: FleetSnapshot) {
        guard let defaults else { return }
        do {
            let data = try JSONEncoder.snapshot.encode(snapshot)
            defaults.set(data, forKey: key)
        } catch {
            // Intentionally swallow — we don't want encoding errors to
            // block the live UI rendering on the watch.
        }
    }

    /// Read the most recent snapshot, or `.empty` if none stored yet.
    static func read() -> FleetSnapshot {
        guard let defaults, let data = defaults.data(forKey: key) else {
            return .empty
        }
        return (try? JSONDecoder.snapshot.decode(FleetSnapshot.self, from: data)) ?? .empty
    }
}
