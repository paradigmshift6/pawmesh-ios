import SwiftUI

/// Top-level watch UI. Navigation root: a list of assigned dogs. Tapping
/// one pushes the full-screen compass page for that tracker.
///
/// Also handles deep links from the watch complication: when the user
/// taps the complication on the watch face, `DogTrackerWatchApp` sets
/// `deepLinkTarget` to the tracker's node number, and we push the
/// corresponding compass page automatically.
struct WatchCompassScreen: View {
    @Binding var deepLinkTarget: UInt32?
    @Environment(WatchSession.self) private var session

    @State private var path: [UInt32] = []

    var body: some View {
        NavigationStack(path: $path) {
            if session.snapshot.trackers.isEmpty {
                WatchEmptyState(linkState: session.snapshot.linkState,
                                isActivated: session.isActivated)
            } else {
                WatchDogsListScreen(path: $path)
            }
        }
        .onChange(of: deepLinkTarget) { _, newValue in
            // Push the target tracker's compass page, then clear the
            // pending link so a back-swipe doesn't re-push it.
            if let node = newValue,
               session.snapshot.trackers.contains(where: { $0.nodeNum == node }) {
                path = [node]
                deepLinkTarget = nil
            }
        }
    }
}
