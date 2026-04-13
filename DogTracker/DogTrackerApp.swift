import SwiftUI
import SwiftData

@main
struct DogTrackerApp: App {
    let modelContainer: ModelContainer
    @State private var radio: RadioController
    @State private var mesh: MeshService
    @State private var location = LocationProvider()
    @State private var units = UnitSettings()

    init() {
        do {
            let mc = try ModelContainer(
                for: Tracker.self, Fix.self, TileRegion.self
            )
            self.modelContainer = mc
            let r = RadioController()
            self._radio = State(initialValue: r)
            self._mesh = State(initialValue: MeshService(radio: r, modelContainer: mc))
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    radio.start()
                    mesh.start()
                    location.requestPermission()
                    radio.autoReconnect()
                }
        }
        .modelContainer(modelContainer)
        .environment(radio)
        .environment(mesh)
        .environment(location)
        .environment(units)
    }
}
