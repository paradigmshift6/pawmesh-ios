import SwiftUI
import SwiftData

@main
struct DogTrackerApp: App {
    let modelContainer: ModelContainer
    @State private var radio: RadioController
    @State private var mesh: MeshService
    @State private var location = LocationProvider()
    @State private var units = UnitSettings()
    @State private var phoneWatch: PhoneWatchSession
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    @AppStorage("demoMode") private var demoMode = false
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Check for demo mode: either the UserDefaults flag or a launch argument
        let isDemo = UserDefaults.standard.bool(forKey: "demoMode")
            || ProcessInfo.processInfo.arguments.contains("DEMO_MODE")

        do {
            let mc = try ModelContainer(
                for: Tracker.self, Fix.self, TileRegion.self,
                Geofence.self, GeofenceEvent.self
            )
            self.modelContainer = mc

            let transport: RadioTransport = isDemo ? DemoRadioTransport() : BLERadioTransport()
            let r = RadioController(transport: transport)
            let m = MeshService(radio: r, modelContainer: mc)
            let loc = LocationProvider()
            let u = UnitSettings()
            self._radio = State(initialValue: r)
            self._mesh = State(initialValue: m)
            self._location = State(initialValue: loc)
            self._units = State(initialValue: u)
            self._phoneWatch = State(initialValue: PhoneWatchSession(
                mesh: m, radio: r, location: loc, units: u, modelContainer: mc
            ))

            // Start the radio + mesh consumers immediately so an iOS
            // background launch (e.g. CoreBluetooth state restoration that
            // delivers a position while the UI hasn't been created yet) is
            // still observed by the geofence monitor. `.start()` is
            // idempotent — onAppear's call below is a no-op the second time.
            NotificationAuthorization.shared.install()
            r.start()
            m.start()

            if isDemo {
                DemoSeeder.seedIfNeeded(modelContainer: mc)
            }
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            if demoMode || onboardingComplete {
                ContentView()
                    .onAppear {
                        phoneWatch.start()
                        if demoMode {
                            // In demo mode, auto-connect to the fake radio
                            startDemoConnection()
                        } else {
                            location.requestPermission()
                            radio.autoReconnect()
                        }
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
            if phase == .active && !demoMode {
                radio.handleReturnToForeground()
            }
        }
    }

    /// Kick off the demo transport's simulated connection.
    private func startDemoConnection() {
        let demoUUID = UUID(uuidString: "00000000-DE00-DE00-DE00-000000000000")!
        Task {
            await radio.radio.start()
            try? await Task.sleep(for: .milliseconds(200))
            await radio.radio.connectByUUID(demoUUID)
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
