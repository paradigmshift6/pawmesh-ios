import SwiftUI
import SwiftData

@main
struct DogTrackerApp: App {
    let modelContainer: ModelContainer
    @State private var radio: RadioController
    @State private var mesh: MeshService
    @State private var location = LocationProvider()
    @State private var units = UnitSettings()
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    @Environment(\.scenePhase) private var scenePhase

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
            if onboardingComplete {
                ContentView()
                    .onAppear {
                        radio.start()
                        mesh.start()
                        location.requestPermission()
                        radio.autoReconnect()
                    }
            } else {
                OnboardingRootView(radio: radio, mesh: mesh, modelContainer: modelContainer)
            }
        }
        .modelContainer(modelContainer)
        .environment(radio)
        .environment(mesh)
        .environment(location)
        .environment(units)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                radio.handleReturnToForeground()
            }
        }
    }
}

/// Wrapper that creates and owns the OnboardingManager.
private struct OnboardingRootView: View {
    let radio: RadioController
    let mesh: MeshService
    let modelContainer: ModelContainer
    @State private var manager: OnboardingManager?

    var body: some View {
        ZStack {
            if let manager {
                OnboardingContainerView(manager: manager)
            } else {
                ProgressView()
            }
        }
        .onAppear {
            if manager == nil {
                let m = OnboardingManager(radio: radio, modelContainer: modelContainer)
                m.startObserving()
                radio.start()
                mesh.start()
                manager = m
            }
        }
    }
}
