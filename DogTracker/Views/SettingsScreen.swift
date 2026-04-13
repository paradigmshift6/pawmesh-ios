import SwiftUI
import SwiftData

struct SettingsScreen: View {
    @Environment(RadioController.self) private var radio
    @Environment(MeshService.self) private var mesh
    @Environment(UnitSettings.self) private var units
    @Environment(\.modelContext) private var modelContext
    @Query private var fixes: [Fix]
    @State private var showTrackerSetup = false

    var body: some View {
        NavigationStack {
            Form {
                radioSection
                unitsSection
                deviceSetupSection
                meshSection
                historySection
                aboutSection
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showTrackerSetup) {
                TrackerSetupSheet(radio: radio)
            }
        }
    }

    private var radioSection: some View {
        Section("Radio") {
            NavigationLink {
                RadioScreen()
            } label: {
                LabeledContent("Meshtastic radio", value: shortStatus)
            }
        }
    }

    private var unitsSection: some View {
        Section("Units") {
            @Bindable var units = units
            Toggle("Use metric (km / m)", isOn: $units.useMetric)
            Text(units.useMetric ? "Distances in meters / kilometers" : "Distances in feet / miles")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var meshSection: some View {
        Section("Mesh") {
            LabeledContent("Nodes seen", value: "\(mesh.nodes.count)")
            if mesh.myNodeNum > 0 {
                LabeledContent("My node", value: String(format: "!%08x", mesh.myNodeNum))
            }
        }
    }

    private var historySection: some View {
        Section("History") {
            LabeledContent("Position fixes stored", value: "\(fixes.count)")
            if !fixes.isEmpty {
                Button("Clear all position history", role: .destructive) {
                    clearHistory()
                }
            }
        }
    }

    private var deviceSetupSection: some View {
        Section("Device Setup") {
            Button {
                showTrackerSetup = true
            } label: {
                Label("Set Up New Tracker", systemImage: "pawprint.fill")
            }
            Button("Re-run Onboarding") {
                UserDefaults.standard.set(false, forKey: "onboardingComplete")
                // Force a UI refresh by posting a notification or restarting
                // For now, the user needs to restart the app
            }
            .foregroundStyle(.secondary)
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: "0.1.0")
            LabeledContent("Map data", value: "USGS US Topo (public domain)")
            LabeledContent("Meshtastic protos", value: "v2.7.21")
            LabeledContent("License", value: "GPL-3.0")
        }
    }

    private var shortStatus: String {
        switch radio.connectionState {
        case .disconnected: "Not connected"
        case .bluetoothUnavailable: "BT off"
        case .scanning: "Scanning"
        case .connecting(let n): "Connecting \(n)"
        case .configuring(let n): "Configuring \(n)"
        case .connected(let n): n
        case .failed: "Failed"
        }
    }

    private func clearHistory() {
        for fix in fixes {
            modelContext.delete(fix)
        }
        try? modelContext.save()
    }
}

// MARK: - Tracker setup sheet (add tracker after onboarding)

private struct TrackerSetupSheet: View {
    let radio: RadioController
    @Environment(\.dismiss) private var dismiss
    @State private var manager: OnboardingManager?

    var body: some View {
        NavigationStack {
            ZStack {
                if let manager {
                    trackerFlow(manager)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Set Up Tracker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onAppear {
            if manager == nil {
                let m = OnboardingManager(radio: radio)
                // Jump straight to tracker setup
                m.startObserving()
                manager = m
            }
        }
    }

    @ViewBuilder
    private func trackerFlow(_ manager: OnboardingManager) -> some View {
        switch manager.step {
        case .welcome, .connectCompanion, .checkingCompanion, .regionSelect,
             .configuringCompanion, .companionReady, .connectTracker:
            ConnectDeviceStepView(
                manager: manager,
                radio: radio,
                title: "Connect Tracker",
                subtitle: "Power on the tracker and select it below.",
                systemImage: "pawprint.fill"
            )
            .onAppear {
                // Disconnect from companion to connect to tracker
                radio.disconnect()
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    radio.startScan()
                }
            }

        case .configuringTracker:
            ConfiguringDeviceView(
                title: "Setting Up Tracker",
                items: manager.configProgress,
                error: manager.error
            )

        case .trackerReady, .addMoreTrackers, .complete:
            DeviceReadyStepView(
                title: "Tracker Ready",
                message: "The tracker is configured.\nIt will reconnect to your companion automatically.",
                systemImage: "checkmark.circle.fill",
                buttonLabel: "Done",
                action: {
                    // Reconnect to companion
                    if let uuid = UUID(uuidString: UserDefaults.standard.string(forKey: "lastConnectedPeripheralUUID") ?? "") {
                        radio.connect(uuid)
                    }
                    dismiss()
                }
            )
        }
    }
}
