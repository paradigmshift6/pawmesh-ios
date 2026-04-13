import Foundation
import Observation
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

    /// Peripheral UUIDs of configured trackers (for display).
    private(set) var configuredTrackerCount = 0

    // MARK: - Private

    private let radio: RadioController
    private let log = Logger(subsystem: "com.levijohnson.DogTracker", category: "Onboarding")

    /// UUID of the companion peripheral, saved so we can reconnect after
    /// temporarily connecting to a tracker.
    private var companionPeripheralUUID: UUID?

    /// The node number of the currently connected device.
    private var connectedNodeNum: UInt32 = 0

    /// Consumer task for radio events.
    private var consumer: Task<Void, Never>?

    init(radio: RadioController) {
        self.radio = radio
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

        case .regionSelect:
            step = .configuringCompanion
            Task { await configureCompanion() }

        case .configuringCompanion:
            break // automatic

        case .companionReady:
            step = .connectTracker
            // Disconnect from companion, start scanning for tracker
            companionPeripheralUUID = savedCompanionUUID
            radio.disconnect()
            // Small delay then scan
            Task {
                try? await Task.sleep(for: .seconds(1))
                radio.startScan()
            }

        case .connectTracker:
            break // connection triggers advance

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
        radio.disconnect()
        Task {
            try? await Task.sleep(for: .seconds(1))
            radio.startScan()
        }
    }

    /// User is done adding trackers.
    func finishOnboarding() {
        step = .complete
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
            step = .checkingCompanion
            checkCompanionConfig()

        case .connectTracker:
            step = .configuringTracker
            Task { await configureTracker() }

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
                step = .regionSelect
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
        configProgress = [
            ConfigItem(label: "Device role", done: false),
            ConfigItem(label: "Position settings", done: false),
            ConfigItem(label: "LoRa radio", done: false),
            ConfigItem(label: "Private channel", done: false),
            ConfigItem(label: "Saving", done: false),
        ]

        let configurator = DeviceConfigurator(radio: radio.radio)
        let channel = ChannelManager.makePrivateChannel()
        let nodeNum = connectedNodeNum

        do {
            try await configurator.beginEdit(nodeNum: nodeNum)
            try await Task.sleep(for: .milliseconds(200))

            // Device role
            var device = Config.DeviceConfig()
            device.role = .client
            try await configurator.setDeviceConfig(device, on: nodeNum)
            markProgress(0)
            try await Task.sleep(for: .milliseconds(200))

            // Position
            var position = Config.PositionConfig()
            position.gpsMode = .notPresent
            position.positionBroadcastSecs = 0
            try await configurator.setPositionConfig(position, on: nodeNum)
            markProgress(1)
            try await Task.sleep(for: .milliseconds(200))

            // LoRa
            var lora = Config.LoRaConfig()
            lora.region = selectedRegion
            lora.usePreset = true
            lora.modemPreset = .longFast
            lora.hopLimit = 3
            lora.txEnabled = true
            try await configurator.setLoRaConfig(lora, on: nodeNum)
            markProgress(2)
            try await Task.sleep(for: .milliseconds(200))

            // Channel
            try await configurator.setChannel(channel, on: nodeNum)
            markProgress(3)
            try await Task.sleep(for: .milliseconds(200))

            // Commit
            try await configurator.commitEdit(nodeNum: nodeNum)
            markProgress(4)

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
        configProgress = [
            ConfigItem(label: "Device role (tracker)", done: false),
            ConfigItem(label: "GPS & position broadcasting", done: false),
            ConfigItem(label: "LoRa radio", done: false),
            ConfigItem(label: "Private channel", done: false),
            ConfigItem(label: "Saving", done: false),
        ]

        let configurator = DeviceConfigurator(radio: radio.radio)
        guard let channel = ChannelManager.existingPrivateChannel() else {
            error = "No private channel PSK found. Please set up the companion first."
            isConfiguring = false
            return
        }
        let nodeNum = connectedNodeNum

        do {
            try await configurator.beginEdit(nodeNum: nodeNum)
            try await Task.sleep(for: .milliseconds(200))

            // Device role: tracker
            var device = Config.DeviceConfig()
            device.role = .tracker
            try await configurator.setDeviceConfig(device, on: nodeNum)
            markProgress(0)
            try await Task.sleep(for: .milliseconds(200))

            // Position: GPS on, 2-min broadcast, smart at 10m
            var position = Config.PositionConfig()
            position.gpsMode = .enabled
            position.positionBroadcastSecs = 120
            position.positionBroadcastSmartEnabled = true
            position.broadcastSmartMinimumDistance = 10
            position.broadcastSmartMinimumIntervalSecs = 30
            position.gpsUpdateInterval = 60
            position.positionFlags = 1 | 8 | 32 | 64 // altitude|dop|satinview|seqNo
            try await configurator.setPositionConfig(position, on: nodeNum)
            markProgress(1)
            try await Task.sleep(for: .milliseconds(200))

            // LoRa: match companion
            var lora = Config.LoRaConfig()
            lora.region = selectedRegion
            lora.usePreset = true
            lora.modemPreset = .longFast
            lora.hopLimit = 3
            lora.txEnabled = true
            try await configurator.setLoRaConfig(lora, on: nodeNum)
            markProgress(2)
            try await Task.sleep(for: .milliseconds(200))

            // Same private channel
            try await configurator.setChannel(channel, on: nodeNum)
            markProgress(3)
            try await Task.sleep(for: .milliseconds(200))

            // Commit
            try await configurator.commitEdit(nodeNum: nodeNum)
            markProgress(4)

            isConfiguring = false
            configuredTrackerCount += 1
            log.info("tracker configured successfully")

            try? await Task.sleep(for: .seconds(3))
            step = .trackerReady
        } catch {
            self.error = "Failed to configure tracker: \(error.localizedDescription)"
            isConfiguring = false
            log.error("tracker config failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private func markProgress(_ index: Int) {
        if index < configProgress.count {
            configProgress[index].done = true
        }
    }

    private var savedCompanionUUID: UUID? {
        guard let s = UserDefaults.standard.string(forKey: "lastConnectedPeripheralUUID") else {
            return nil
        }
        return UUID(uuidString: s)
    }

    private func reconnectCompanion() {
        guard let uuid = companionPeripheralUUID else { return }
        radio.connect(uuid)
    }
}

// MARK: - Supporting types

enum OnboardingStep: Equatable {
    case welcome
    case connectCompanion
    case checkingCompanion
    case regionSelect
    case configuringCompanion
    case companionReady
    case connectTracker
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
