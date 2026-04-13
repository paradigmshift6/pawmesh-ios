import Foundation
import OSLog

/// Sends Meshtastic admin commands over BLE to configure a connected device.
/// Used during onboarding to set up companion and tracker nodes without
/// requiring the official Meshtastic app.
actor DeviceConfigurator {

    private let radio: MeshtasticRadio
    private let log = Logger(subsystem: "com.levijohnson.DogTracker", category: "Config")

    init(radio: MeshtasticRadio) {
        self.radio = radio
    }

    // MARK: - Edit transaction

    /// Begin an edit transaction. Delays saves/reboots until commitEdit().
    func beginEdit(nodeNum: UInt32) async throws {
        var admin = AdminMessage()
        admin.payloadVariant = .beginEditSettings(true)
        try await sendAdmin(admin, to: nodeNum, hopLimit: 0)
        log.info("beginEditSettings sent to \(nodeNum, format: .hex)")
    }

    /// Commit all pending config changes. The device will save and reboot.
    func commitEdit(nodeNum: UInt32) async throws {
        var admin = AdminMessage()
        admin.payloadVariant = .commitEditSettings(true)
        try await sendAdmin(admin, to: nodeNum, hopLimit: 0)
        log.info("commitEditSettings sent to \(nodeNum, format: .hex)")
    }

    // MARK: - Set config

    func setDeviceConfig(_ config: Config.DeviceConfig, on nodeNum: UInt32) async throws {
        var c = Config()
        c.payloadVariant = .device(config)
        var admin = AdminMessage()
        admin.payloadVariant = .setConfig(c)
        try await sendAdmin(admin, to: nodeNum, hopLimit: 0)
        log.info("setConfig(device) sent to \(nodeNum, format: .hex)")
    }

    func setPositionConfig(_ config: Config.PositionConfig, on nodeNum: UInt32) async throws {
        var c = Config()
        c.payloadVariant = .position(config)
        var admin = AdminMessage()
        admin.payloadVariant = .setConfig(c)
        try await sendAdmin(admin, to: nodeNum, hopLimit: 0)
        log.info("setConfig(position) sent to \(nodeNum, format: .hex)")
    }

    func setLoRaConfig(_ config: Config.LoRaConfig, on nodeNum: UInt32) async throws {
        var c = Config()
        c.payloadVariant = .lora(config)
        var admin = AdminMessage()
        admin.payloadVariant = .setConfig(c)
        try await sendAdmin(admin, to: nodeNum, hopLimit: 0)
        log.info("setConfig(lora) sent to \(nodeNum, format: .hex)")
    }

    // MARK: - Set channel

    func setChannel(_ channel: Channel, on nodeNum: UInt32) async throws {
        var admin = AdminMessage()
        admin.payloadVariant = .setChannel(channel)
        try await sendAdmin(admin, to: nodeNum, hopLimit: 0)
        log.info("setChannel[\(channel.index)] sent to \(nodeNum, format: .hex)")
    }

    // MARK: - Full device configuration

    /// Configure a device as the companion (phone's BLE bridge).
    func configureCompanion(
        nodeNum: UInt32,
        region: Config.LoRaConfig.RegionCode,
        privateChannel: Channel
    ) async throws {
        try await beginEdit(nodeNum: nodeNum)
        try await Task.sleep(for: .milliseconds(200))

        // Device role: client (can rebroadcast as a bridge)
        var device = Config.DeviceConfig()
        device.role = .client
        try await setDeviceConfig(device, on: nodeNum)
        try await Task.sleep(for: .milliseconds(200))

        // Position: GPS not present, no broadcasting
        var position = Config.PositionConfig()
        position.gpsMode = .notPresent
        position.positionBroadcastSecs = 0
        position.fixedPosition = false
        try await setPositionConfig(position, on: nodeNum)
        try await Task.sleep(for: .milliseconds(200))

        // LoRa: user-selected region, longFast preset
        var lora = Config.LoRaConfig()
        lora.region = region
        lora.usePreset = true
        lora.modemPreset = .longFast
        lora.hopLimit = 3
        lora.txEnabled = true
        try await setLoRaConfig(lora, on: nodeNum)
        try await Task.sleep(for: .milliseconds(200))

        // Private channel for dog tracking
        try await setChannel(privateChannel, on: nodeNum)
        try await Task.sleep(for: .milliseconds(200))

        try await commitEdit(nodeNum: nodeNum)
        log.info("companion configuration committed on \(nodeNum, format: .hex)")
    }

    /// Configure a device as a dog tracker.
    func configureTracker(
        nodeNum: UInt32,
        region: Config.LoRaConfig.RegionCode,
        privateChannel: Channel
    ) async throws {
        try await beginEdit(nodeNum: nodeNum)
        try await Task.sleep(for: .milliseconds(200))

        // Device role: tracker
        var device = Config.DeviceConfig()
        device.role = .tracker
        try await setDeviceConfig(device, on: nodeNum)
        try await Task.sleep(for: .milliseconds(200))

        // Position: GPS enabled, broadcast every 2 min, smart broadcast at 10m
        var position = Config.PositionConfig()
        position.gpsMode = .enabled
        position.positionBroadcastSecs = 120
        position.positionBroadcastSmartEnabled = true
        position.broadcastSmartMinimumDistance = 10
        position.broadcastSmartMinimumIntervalSecs = 30
        position.gpsUpdateInterval = 60
        position.fixedPosition = false
        // Flags: altitude | satinview | dop | seqNo
        position.positionFlags = 1 | 32 | 8 | 64
        try await setPositionConfig(position, on: nodeNum)
        try await Task.sleep(for: .milliseconds(200))

        // LoRa: must match companion
        var lora = Config.LoRaConfig()
        lora.region = region
        lora.usePreset = true
        lora.modemPreset = .longFast
        lora.hopLimit = 3
        lora.txEnabled = true
        try await setLoRaConfig(lora, on: nodeNum)
        try await Task.sleep(for: .milliseconds(200))

        // Same private channel as companion
        try await setChannel(privateChannel, on: nodeNum)
        try await Task.sleep(for: .milliseconds(200))

        try await commitEdit(nodeNum: nodeNum)
        log.info("tracker configuration committed on \(nodeNum, format: .hex)")
    }

    // MARK: - Private

    private func sendAdmin(_ admin: AdminMessage, to nodeNum: UInt32, hopLimit: UInt32) async throws {
        let myNum = await radio.state == .disconnected ? nodeNum : nodeNum // addressed to target
        let payload = try admin.serializedData()

        var data = DataMessage()
        data.portnum = .adminApp
        data.payload = payload
        data.wantResponse = true

        var packet = MeshPacket()
        packet.to = nodeNum
        packet.from = 0  // firmware fills in our nodeNum
        packet.hopLimit = hopLimit
        packet.wantAck = true
        packet.decoded = data

        var toRadio = ToRadio()
        toRadio.packet = packet

        try await radio.sendToRadio(toRadio)
    }
}
