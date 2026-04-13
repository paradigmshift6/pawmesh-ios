import Foundation
import Observation

/// `@MainActor`-isolated UI adapter that wraps a `MeshtasticRadio` actor.
///
/// SwiftUI binds to the `@Observable` properties on this class. All actor
/// hops happen here so that views never have to deal with `await`.
@MainActor
@Observable
final class RadioController {

    // Mirrored radio state — driven by the radio's event stream.
    private(set) var connectionState: RadioConnectionState = .disconnected
    private(set) var discovered: [DiscoveredPeripheral] = []

    /// Most recent decoded `FromRadio` packet. Mesh service observes this to
    /// drive its NodeDB updates. (Phase 4 will swap this for a typed callback,
    /// but for now `lastFromRadio` is the simplest binding surface.)
    private(set) var lastFromRadio: FromRadio?
    private(set) var configComplete: Bool = false

    /// Underlying radio actor. Exposed so feature code (Ping, etc.) can call
    /// `sendToRadio`.
    let radio: MeshtasticRadio

    private var consumer: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    /// Whether the user explicitly disconnected (suppress auto-reconnect).
    private var userDisconnected = false

    private static let savedPeripheralKey = "lastConnectedPeripheralUUID"

    init(transport: RadioTransport) {
        self.radio = MeshtasticRadio(transport: transport)
    }

    /// Convenience init that wires up the real BLE transport. Tests should
    /// use the `transport:` initializer instead.
    convenience init() {
        self.init(transport: BLERadioTransport())
    }

    /// Begin consuming radio events. Call once at app startup.
    func start() {
        guard consumer == nil else { return }
        consumer = Task { [weak self] in
            guard let self else { return }
            await self.radio.start()
            let stream = await self.radio.subscribe()
            for await event in stream {
                self.handle(event)
            }
        }
    }

    /// Try to reconnect to the last-used peripheral. Call on app launch
    /// after `start()`. If BT isn't ready yet we wait briefly for it.
    func autoReconnect() {
        guard let uuidString = UserDefaults.standard.string(forKey: Self.savedPeripheralKey),
              let uuid = UUID(uuidString: uuidString) else { return }

        reconnectTask = Task { [weak self] in
            guard let self else { return }
            // Give CoreBluetooth a moment to power on
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
                let state = self.connectionState
                if case .bluetoothUnavailable = state { continue }
                break
            }
            if Task.isCancelled { return }
            // Ask the radio to connect directly by UUID (retrievePeripherals)
            await self.radio.connectByUUID(uuid)
        }
    }

    // MARK: - Commands

    func startScan()      { Task { await radio.startScan() } }
    func stopScan()       { Task { await radio.stopScan() } }

    func connect(_ id: UUID) {
        userDisconnected = false
        reconnectTask?.cancel()
        // Save for auto-reconnect
        UserDefaults.standard.set(id.uuidString, forKey: Self.savedPeripheralKey)
        Task { await radio.connect(id) }
    }

    func disconnect() {
        userDisconnected = true
        reconnectTask?.cancel()
        // Clear saved peripheral so we don't auto-reconnect
        UserDefaults.standard.removeObject(forKey: Self.savedPeripheralKey)
        Task { await radio.disconnect() }
    }

    // MARK: - Event handling

    private func handle(_ event: RadioEvent) {
        switch event {
        case .stateChanged(let s):
            connectionState = s

            if case .connected = s {
                reconnectTask?.cancel()
            } else if case .disconnected = s {
                configComplete = false
                // Auto-reconnect on unexpected disconnect
                if !userDisconnected {
                    scheduleReconnect()
                }
            }
        case .discovered(let list):
            discovered = list
        case .fromRadio(let msg):
            lastFromRadio = msg
        case .configComplete:
            configComplete = true
        case .logMessage(let s):
            print("[Radio] \(s)")
        }
    }

    /// After an unexpected disconnect, wait a few seconds then try to reconnect.
    private func scheduleReconnect() {
        guard let uuidString = UserDefaults.standard.string(forKey: Self.savedPeripheralKey),
              let uuid = UUID(uuidString: uuidString) else { return }

        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            // Wait before reconnecting to avoid rapid retry loops
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            await self.radio.connectByUUID(uuid)
        }
    }
}
