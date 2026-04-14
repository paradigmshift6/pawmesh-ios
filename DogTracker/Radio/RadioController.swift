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
    /// How many consecutive reconnect attempts have failed.
    private var reconnectAttempts = 0
    /// Max direct UUID reconnect attempts before falling back to scan.
    private static let maxDirectAttempts = 3

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

    // MARK: - Foreground/background

    /// Call when the app returns to the foreground. If the connection dropped
    /// while suspended, resets the retry counter and kicks off a fresh reconnect.
    func handleReturnToForeground() {
        guard !userDisconnected else { return }

        switch connectionState {
        case .connected:
            // Still connected — nothing to do
            break
        case .disconnected, .failed:
            // Connection dropped while suspended — retry from scratch.
            print("[Radio] returned to foreground while disconnected, reconnecting")
            reconnectAttempts = 0
            reconnectTask?.cancel()
            autoReconnect()
        case .connecting, .configuring, .scanning:
            // Already mid-connect. If it's been stuck for a while (timer froze
            // in background), cancel and retry.
            print("[Radio] returned to foreground in state \(connectionState), restarting connect")
            reconnectTask?.cancel()
            reconnectAttempts = 0
            Task {
                await radio.disconnect()
                try? await Task.sleep(for: .milliseconds(500))
                autoReconnect()
            }
        case .bluetoothUnavailable:
            break
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

    /// Disconnect without clearing saved peripheral or suppressing reconnect.
    /// Used during onboarding when switching between companion and tracker.
    func disconnectForSwitch() {
        reconnectTask?.cancel()
        Task { await radio.disconnect() }
    }

    // MARK: - Event handling

    private func handle(_ event: RadioEvent) {
        switch event {
        case .stateChanged(let s):
            connectionState = s

            if case .connected = s {
                reconnectTask?.cancel()
                reconnectAttempts = 0  // reset on successful connection
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

    /// After an unexpected disconnect, wait then try to reconnect.
    /// Uses exponential backoff: 3s → 5s → 10s.
    /// After `maxDirectAttempts` consecutive failures, falls back to scanning
    /// and auto-connecting to the first Meshtastic device found.
    private func scheduleReconnect() {
        guard let uuidString = UserDefaults.standard.string(forKey: Self.savedPeripheralKey),
              let uuid = UUID(uuidString: uuidString) else { return }

        reconnectAttempts += 1
        let attempt = reconnectAttempts

        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            guard let self else { return }

            if attempt <= Self.maxDirectAttempts {
                // Direct UUID reconnect with backoff: 3s, 5s, 10s
                let delay = attempt <= 1 ? 3 : (attempt <= 2 ? 5 : 10)
                print("[Radio] reconnect attempt \(attempt)/\(Self.maxDirectAttempts) in \(delay)s (direct UUID)")
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                await self.radio.connectByUUID(uuid)
            } else {
                // Direct UUID failed repeatedly — fall back to scan-based reconnect.
                // This gets a fresh CBPeripheral reference and avoids stale BLE state.
                print("[Radio] direct reconnect failed \(Self.maxDirectAttempts) times, falling back to scan")
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }

                await self.radio.startScan()

                // Wait up to 15 seconds for the device to appear in scan results
                for _ in 0..<30 {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }

                    // Look for our saved peripheral in discovered list
                    if let found = self.discovered.first(where: { $0.id == uuid }) {
                        print("[Radio] found \(found.name) via scan, reconnecting")
                        self.reconnectAttempts = 0
                        self.connect(uuid)
                        return
                    }
                }

                // Didn't find it — stop scanning, stay disconnected.
                // User can manually tap "Scan for Radios".
                print("[Radio] device not found after scan, giving up auto-reconnect")
                await self.radio.stopScan()
            }
        }
    }
}
