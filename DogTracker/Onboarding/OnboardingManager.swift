import Foundation
import Observation
import SwiftData
import OSLog

/// Drives the onboarding wizard state machine. Orchestrates BLE connections
/// to companion and tracker devices, checks existing config, and applies
/// new configuration via `DeviceConfigurator`.
@MainActor
@Observable
final class OnboardingManager {

    // MARK: - Published state

    private(set) var step: OnboardingStep = .welcome
    private(set) var isConfiguring = false
    private(set) var configProgress: [ConfigItem] = []
    private(set) var error: String?

    /// LoRa region chosen by the user during onboarding.
    var selectedRegion: Config.LoRaConfig.RegionCode = .us

    /// Device name entered by the user.
    var deviceName: String = ""

    /// Peripheral UUIDs of configured trackers (for display).
    private(set) var configuredTrackerCount = 0

    // MARK: - Private

    private let radio: RadioController
    private let modelContainer: ModelContainer?
    private let log = Logger(subsystem: "com.levijohnson.DogTracker", category: "Onboarding")

    /// UUID of the companion peripheral, saved so we can reconnect after
    /// temporarily connecting to a tracker.
    private var companionPeripheralUUID: UUID?

    /// The node number of the currently connected device.
    private var connectedNodeNum: UInt32 = 0

    /// Consumer task for radio events.
    private var consumer: Task<Void, Never>?

    init(radio: RadioController, modelContainer: ModelContainer? = nil) {
        self.radio = radio
        self.modelContainer = modelContainer
    }

    // MARK: - Step navigation

    func advance() {
        switch step {
        case .welcome:
            step = .connectCompanion
            radio.startScan()

        case .connectCompanion:
            break // connection triggers advance via event handling

        case .checkingCompanion:
            break // automatic

        case .nameCompanion:
            step = .regionSelect

        case .regionSelect:
            step = .configuringCompanion
            Task { await configureCompanion() }

        case .configuringCompanion:
            break // automatic

        case .companionReady:
            step = .connectTracker
            // Disconnect from companion, start scanning for tracker
            companionPeripheralUUID = savedCompanionUUID
            radio.disconnectForSwitch()
            // Small delay then scan
            Task {
                try? await Task.sleep(for: .seconds(1))
                radio.startScan()
            }

        case .connectTracker:
            break // connection triggers advance

        case .nameTracker:
            step = .configuringTracker
            Task { await configureTracker() }

        case .configuringTracker:
            break // automatic

        case .trackerReady:
            step = .addMoreTrackers

        case .addMoreTrackers:
            break // user chooses

        case .complete:
            break
        }
    }

    /// User chose to add another tracker from the addMoreTrackers step.
    func addAnotherTracker() {
        step = .connectTracker
        radio.disconnectForSwitch()
        Task {
            try? await Task.sleep(for: .seconds(1))
            radio.startScan()
        }
    }

    /// User is done adding trackers.
    func finishOnboarding() {
        step = .complete
        // Restore companion UUID as the auto-reconnect target
        if let uuid = companionPeripheralUUID {
            UserDefaults.standard.set(uuid.uuidString, forKey: "lastConnectedPeripheralUUID")
        }
        // Reconnect to companion
        reconnectCompanion()
        // Mark onboarding as complete
        UserDefaults.standard.set(true, forKey: "onboardingComplete")
    }

    /// Skip onboarding entirely (already configured).
    func skip() {
        step = .complete
        UserDefaults.standard.set(true, forKey: "onboardingComplete")
    }

    // MARK: - Connection handling

    /// Call when user taps a discovered peripheral to connect.
    func connectToDevice(_ id: UUID) {
        error = nil
        radio.connect(id)
    }

    /// Start observing radio events. Call once.
    func startObserving() {
        guard consumer == nil else { return }
        consumer = Task { [weak self] in
            guard let self else { return }
            await self.radio.radio.start()
            let stream = await self.radio.radio.subscribe()
            for await event in stream {
                self.handleEvent(event)
            }
        }
    }

    // MARK: - Event handling

    private func handleEvent(_ event: RadioEvent) {
        switch event {
        case .stateChanged(let state):
            if case .connected = state {
                handleConnected()
            } else if case .disconnected = state {
                // Only treat as error if we're in a connecting step
                if step == .connectCompanion || step == .connectTracker {
                    // Expected during transitions, don't error
                }
            }

        case .configComplete:
            handleConfigComplete()

        case .fromRadio(let msg):
            // Capture node number from myInfo
            if case .myInfo(let info) = msg.payloadVariant {
                connectedNodeNum = info.myNodeNum
            }

        default:
            break
        }
    }

    private func handleConnected() {
        log.info("device connected during onboarding, step=\(String(describing: self.step))")
    }

    private func handleConfigComplete() {
        switch step {
        case .connectCompanion:
            // Save companion UUID before we might connect to a tracker later
            if let uuidStr = UserDefaults.standard.string(forKey: "lastConnectedPeripheralUUID") {
                UserDefaults.standard.set(uuidStr, forKey: Self.companionUUIDKey)
                companionPeripheralUUID = UUID(uuidString: uuidStr)
            }
            step = .checkingCompanion
            checkCompanionConfig()

        case .connectTracker:
            deviceName = ""
            step = .nameTracker

        default:
            break
        }
    }

    // MARK: - Companion config check

    private func checkCompanionConfig() {
        // Read channels from MeshService (populated during handshake)
        // We need to check after a brief delay to let channels populate
        Task {
            try? await Task.sleep(for: .milliseconds(500))

            // Check if already configured with our private channel
            // We check the channels that MeshService captured during handshake
            let channels = await getChannelsFromRadio()
            if ChannelManager.hasPrivateChannel(in: channels) {
                log.info("companion already configured, adopting PSK")
                ChannelManager.adoptPSK(from: channels)
                step = .companionReady
            } else {
                deviceName = ""
                step = .nameCompanion
            }
        }
    }

    /// Read the channels dict. Since MeshService stores them during handshake,
    /// we just need a reference. For onboarding we read from the radio events
    /// that were captured.
    private func getChannelsFromRadio() async -> [Int32: Channel] {
        // The channels were captured by MeshService during the config handshake.
        // We need access to them — for now, we'll check from the radio controller
        // by looking at what came through. We'll use a simple approach: the
        // OnboardingContainerView passes the MeshService so we can read channels.
        // For the manager, we store them ourselves from fromRadio events.
        return capturedChannels
    }

    /// Channels captured from the config handshake.
    private var capturedChannels: [Int32: Channel] = [:]

    /// Call from the view layer to provide channel data from MeshService.
    func setCapturedChannels(_ channels: [Int32: Channel]) {
        capturedChannels = channels
    }

    // MARK: - Configure companion

    private func configureCompanion() async {
        isConfiguring = true
        let hasName = !deviceName.trimmingCharacters(in: .whitespaces).isEmpty
        var items = [ConfigItem]()
        if hasName { items.append(ConfigItem(label: "Device name", done: false)) }
        items.append(contentsOf: [
            ConfigItem(label: "Device role", done: false),
            ConfigItem(label: "Position settings", done: false),
            ConfigItem(label: "LoRa radio", done: false),
            ConfigItem(label: "Private channel (full precision)", done: false),
            ConfigItem(label: "Saving", done: false),
        ])
        configProgress = items

        let configurator = DeviceConfigurator(radio: radio.radio)
        let channel = ChannelManager.makePrivateChannel()
        let nodeNum = connectedNodeNum
        var idx = 0

        do {
            try await configurator.beginEdit(nodeNum: nodeNum)
            try await Task.sleep(for: .milliseconds(500))

            // Device name
            if hasName {
                let name = deviceName.trimmingCharacters(in: .whitespaces)
                let short = String(name.prefix(4))
                try await configurator.setOwner(longName: name, shortName: short, on: nodeNum)
                markProgress(idx); idx += 1
                try await Task.sleep(for: .milliseconds(500))
            }

            // Device role
            var device = Config.DeviceConfig()
            device.role = .client
            try await configurator.setDeviceConfig(device, on: nodeNum)
            markProgress(idx); idx += 1
            try await Task.sleep(for: .milliseconds(500))

            // Position
            var position = Config.PositionConfig()
            position.gpsMode = .notPresent
            position.positionBroadcastSecs = 0
            try await configurator.setPositionConfig(position, on: nodeNum)
            markProgress(idx); idx += 1
            try await Task.sleep(for: .milliseconds(500))

            // LoRa
            var lora = Config.LoRaConfig()
            lora.region = selectedRegion
            lora.usePreset = true
            lora.modemPreset = .longFast
            lora.hopLimit = 3
            lora.txEnabled = true
            try await configurator.setLoRaConfig(lora, on: nodeNum)
            markProgress(idx); idx += 1
            try await Task.sleep(for: .milliseconds(500))

            // Private channel with full 32-bit precision position
            try await configurator.setChannel(channel, on: nodeNum)
            markProgress(idx); idx += 1
            try await Task.sleep(for: .milliseconds(500))

            // Commit
            try await configurator.commitEdit(nodeNum: nodeNum)
            markProgress(idx)

            isConfiguring = false
            log.info("companion configured successfully")

            // Wait for reboot, then move to next step
            try? await Task.sleep(for: .seconds(5))
            step = .companionReady
        } catch {
            self.error = "Failed to configure companion: \(error.localizedDescription)"
            isConfiguring = false
            log.error("companion config failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Configure tracker

    private func configureTracker() async {
        isConfiguring = true
        let hasName = !deviceName.trimmingCharacters(in: .whitespaces).isEmpty
        var items = [ConfigItem]()
        if hasName { items.append(ConfigItem(label: "Device name", done: false)) }
        items.append(contentsOf: [
            ConfigItem(label: "Device role (tracker)", done: false),
            ConfigItem(label: "GPS & position broadcasting", done: false),
            ConfigItem(label: "LoRa radio", done: false),
            ConfigItem(label: "Private channel (full precision)", done: false),
            ConfigItem(label: "Saving", done: false),
        ])
        configProgress = items

        let configurator = DeviceConfigurator(radio: radio.radio)
        guard let channel = ChannelManager.existingPrivateChannel() else {
            error = "No private channel PSK found. Please set up the companion first."
            isConfiguring = false
            return
        }
        let nodeNum = connectedNodeNum
        var idx = 0

        do {
            try await configurator.beginEdit(nodeNum: nodeNum)
            try await Task.sleep(for: .milliseconds(500))

            // Device name
            if hasName {
                let name = deviceName.trimmingCharacters(in: .whitespaces)
                let short = String(name.prefix(4))
                try await configurator.setOwner(longName: name, shortName: short, on: nodeNum)
                markProgress(idx); idx += 1
                try await Task.sleep(for: .milliseconds(500))
            }

            // Device role: tracker
            var device = Config.DeviceConfig()
            device.role = .tracker
            try await configurator.setDeviceConfig(device, on: nodeNum)
            markProgress(idx); idx += 1
            try await Task.sleep(for: .milliseconds(500))

            // Position: GPS on, 2-min broadcast, smart at 10m
            var position = Config.PositionConfig()
            position.gpsMode = .enabled
            position.gpsEnabled = true
            position.positionBroadcastSecs = 120
            position.positionBroadcastSmartEnabled = true
            position.broadcastSmartMinimumDistance = 10
            position.broadcastSmartMinimumIntervalSecs = 30
            position.gpsUpdateInterval = 30
            position.gpsAttemptTime = 120
            position.positionFlags = 1 | 8 | 32 | 64 // altitude|dop|satinview|seqNo
            try await configurator.setPositionConfig(position, on: nodeNum)
            markProgress(idx); idx += 1
            try await Task.sleep(for: .milliseconds(500))

            // LoRa: match companion
            var lora = Config.LoRaConfig()
            lora.region = selectedRegion
            lora.usePreset = true
            lora.modemPreset = .longFast
            lora.hopLimit = 3
            lora.txEnabled = true
            try await configurator.setLoRaConfig(lora, on: nodeNum)
            markProgress(idx); idx += 1
            try await Task.sleep(for: .milliseconds(500))

            // Private channel with full 32-bit precision position
            try await configurator.setChannel(channel, on: nodeNum)
            markProgress(idx); idx += 1
            try await Task.sleep(for: .milliseconds(500))

            // Commit
            try await configurator.commitEdit(nodeNum: nodeNum)
            markProgress(idx)

            isConfiguring = false
            configuredTrackerCount += 1
            log.info("tracker configured successfully")

            // Auto-add tracker to dogs list
            createTrackerEntry(nodeNum: nodeNum, name: deviceName)

            try? await Task.sleep(for: .seconds(3))
            step = .trackerReady
        } catch {
            self.error = "Failed to configure tracker: \(error.localizedDescription)"
            isConfiguring = false
            log.error("tracker config failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private func createTrackerEntry(nodeNum: UInt32, name: String) {
        guard let modelContainer else { return }
        let context = ModelContext(modelContainer)
        // Check if this node is already tracked
        let descriptor = FetchDescriptor<Tracker>(
            predicate: #Predicate { $0.nodeNum == nodeNum }
        )
        if let existing = try? context.fetch(descriptor).first {
            // Update name if it changed
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { existing.name = trimmed }
            try? context.save()
            return
        }
        let colors = ["#E74C3C", "#2ECC71", "#3498DB"]
        let color = colors[(configuredTrackerCount - 1) % colors.count]
        let displayName = name.trimmingCharacters(in: .whitespaces)
        let tracker = Tracker(
            nodeNum: nodeNum,
            name: displayName.isEmpty ? "Dog \(configuredTrackerCount)" : displayName,
            colorHex: color
        )
        context.insert(tracker)
        try? context.save()
        log.info("created tracker entry for \(nodeNum, format: .hex) name=\(tracker.name)")
    }

    private func markProgress(_ index: Int) {
        if index < configProgress.count {
            configProgress[index].done = true
        }
    }

    private static let companionUUIDKey = "companionPeripheralUUID"

    private var savedCompanionUUID: UUID? {
        guard let s = UserDefaults.standard.string(forKey: Self.companionUUIDKey) else {
            return nil
        }
        return UUID(uuidString: s)
    }

    private func reconnectCompanion() {
        guard let uuid = companionPeripheralUUID else { return }
        // Disconnect from tracker first (if still connected), then
        // wait for the companion to finish rebooting before reconnecting.
        radio.disconnectForSwitch()
        Task {
            // Give the companion time to reboot after commitEdit
            try? await Task.sleep(for: .seconds(5))
            // Use autoReconnect which retries if CoreBluetooth can't find it yet
            UserDefaults.standard.set(uuid.uuidString, forKey: "lastConnectedPeripheralUUID")
            radio.autoReconnect()
        }
    }
}

// MARK: - Supporting types

enum OnboardingStep: Equatable {
    case welcome
    case connectCompanion
    case checkingCompanion
    case nameCompanion
    case regionSelect
    case configuringCompanion
    case companionReady
    case connectTracker
    case nameTracker
    case configuringTracker
    case trackerReady
    case addMoreTrackers
    case complete
}

struct ConfigItem: Identifiable {
    let id = UUID()
    let label: String
    var done: Bool
}
