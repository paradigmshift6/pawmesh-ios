import SwiftUI

@main
struct DogTrackerWatchApp: App {
    @State private var session = WatchSession()
    @State private var heading = WatchHeadingProvider()
    /// Deep-link target from the complication tap: a specific tracker
    /// node number, or nil (show the normal list root).
    @State private var pendingDeepLink: UInt32?

    var body: some Scene {
        WindowGroup {
            WatchCompassScreen(deepLinkTarget: $pendingDeepLink)
                .environment(session)
                .environment(heading)
                .onAppear {
                    session.start()
                    heading.start()
                }
                .onOpenURL { url in
                    // Widgets fire `pawmesh://dog/<nodeNum>` URLs when
                    // tapped. Parse and hand off to the root screen which
                    // pushes the appropriate compass page.
                    if url.scheme == "pawmesh",
                       url.host == "dog",
                       let nodeString = url.pathComponents.dropFirst().first,
                       let node = UInt32(nodeString) {
                        pendingDeepLink = node
                    }
                }
        }
    }
}
