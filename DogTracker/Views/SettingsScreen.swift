import SwiftUI
import SwiftData

struct SettingsScreen: View {
    @Environment(RadioController.self) private var radio
    @Environment(MeshService.self) private var mesh
    @Environment(UnitSettings.self) private var units
    @Environment(\.modelContext) private var modelContext
    @Query private var fixes: [Fix]
    @Query(sort: \Tracker.assignedAt) private var trackers: [Tracker]
    @State private var showTrackerSetup = false
    @State private var resetTarget: ResetTarget?
    @State private var showResetConfirm = false
    @State private var isResetting = false
    @State private var resetResult: String?

    var body: some View {
        NavigationStack {
            Form {
                radioSection
                unitsSection
                deviceSetupSection
                factoryResetSection
                meshSection
                historySection
                aboutSection
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showTrackerSetup) {
                TrackerSetupSheet(radio: radio, modelContainer: modelContext.container)
            }
            .confirmationDialog(
                "Factory Reset \(resetTarget?.label ?? "Device")?",
                isPresented: $showResetConfirm,
                titleVisibility: .visible
            ) {
                Button("Reset Config (keep BLE bonds)", role: .destructive) {
                    performReset(preserveBLE: true)
                }
                Button("Full Factory Reset", role: .destructive) {
                    performReset(preserveBLE: false)
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This will erase all configuration on the device and restore factory defaults. The device will reboot.")
            }
            .alert("Factory Reset", isPresented: .init(
                get: { resetResult != nil },
                set: { if !$0 { resetResult = nil } }
            )) {
                Button("OK") { resetResult = nil }
            } message: {
                Text(resetResult ?? "")
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

    // MARK: - Factory Reset

    private var factoryResetSection: some View {
        Section {
            if isConnected {
                // Companion (currently connected device)
                let nodeNum = mesh.myNodeNum
                let companionName = mesh.nodes[nodeNum]?.longName
                    ?? String(format: "!%08x", nodeNum)

                resetButton(
                    label: "Companion",
                    name: companionName,
                    nodeNum: nodeNum,
                    systemImage: "antenna.radiowaves.left.and.right",
                    detail: "connected"
                )

                // Tracked dogs only (not all mesh nodes)
                ForEach(trackers) { tracker in
                    let trackerName = mesh.nodes[tracker.nodeNum]?.longName ?? tracker.name
                    resetButton(
                        label: tracker.name,
                        name: trackerName,
                        nodeNum: tracker.nodeNum,
                        systemImage: "pawprint.fill",
                        detail: "via mesh"
                    )
                }
            } else {
                Text("Connect to a device to factory reset it.")
                    .foregroundStyle(.secondary)
            }

            if isResetting {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Sending reset command…")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Factory Reset")
        } footer: {
            Text("Resets all configuration to factory defaults. The device will reboot and need to be set up again.")
        }
    }

    private func resetButton(label: String, name: String, nodeNum: UInt32, systemImage: String, detail: String) -> some View {
        Button(role: .destructive) {
            resetTarget = ResetTarget(nodeNum: nodeNum, label: label)
            showResetConfirm = true
        } label: {
            HStack {
                Label("Reset \(label)", systemImage: systemImage)
                Spacer()
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(isResetting)
    }

    private var isConnected: Bool {
        if case .connected = radio.connectionState { return true }
        return false
    }

    private func performReset(preserveBLE: Bool) {
        guard let target = resetTarget else { return }
        isResetting = true
        let configurator = DeviceConfigurator(radio: radio.radio)
        Task {
            do {
                // For remote nodes, use a hop limit > 0
                let isLocal = target.nodeNum == mesh.myNodeNum
                if isLocal {
                    try await configurator.factoryReset(nodeNum: target.nodeNum, preserveBLE: preserveBLE)
                } else {
                    try await configurator.factoryResetRemote(nodeNum: target.nodeNum, preserveBLE: preserveBLE)
                }
                isResetting = false
                resetResult = "\(target.label) has been sent a factory reset command. It will reboot momentarily."
                // If we reset the connected device, it will disconnect on its own
            } catch {
                isResetting = false
                resetResult = "Reset failed: \(error.localizedDescription)"
            }
        }
    }

    private func clearHistory() {
        for fix in fixes {
            modelContext.delete(fix)
        }
        try? modelContext.save()
    }
}

private struct ResetTarget {
    let nodeNum: UInt32
    let label: String
}

// MARK: - Tracker setup sheet (add tracker after onboarding)

struct TrackerSetupSheet: View {
    let radio: RadioController
    let modelContainer: ModelContainer
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
                let m = OnboardingManager(radio: radio, modelContainer: modelContainer)
                // Jump straight to tracker setup
                m.startObserving()
                manager = m
            }
        }
    }

    @ViewBuilder
    private func trackerFlow(_ manager: OnboardingManager) -> some View {
        switch manager.step {
        case .welcome, .connectCompanion, .checkingCompanion, .nameCompanion,
             .regionSelect, .configuringCompanion, .companionReady, .connectTracker:
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

        case .nameTracker:
            NameDeviceView(
                manager: manager,
                title: "Name This Tracker",
                subtitle: "Enter your dog's name.",
                systemImage: "pawprint.fill",
                placeholder: "e.g. Buddy",
                isRequired: true
            )

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
