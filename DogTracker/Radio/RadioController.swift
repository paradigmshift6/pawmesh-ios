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

    /// Timestamp of the most recent `.connecting`/`.configuring` transition.
    /// Used by `handleReturnToForeground` to decide whether an in-progress
    /// connect has been stuck long enough to warrant interruption.
    private var connectingSince: Date?

    /// Underlying radio actor. Exposed so feature code (Ping, etc.) can call
    /// `sendToRadio`.
    let radio: MeshtasticRadio

    private var consumer: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    /// Whether the user explicitly disconnected (suppress auto-reconnect).
    private var userDisconnected = false
    /// When true, disconnect events do NOT trigger automatic reconnection.
    /// Used by OnboardingManager while switching between companion and tracker
    /// so we don't bounce back to the companion during tracker scan.
    var suppressAutoReconnect: Bool = false
    /// How many consecutive reconnect attempts have failed. Reset only on
    /// a successful `.connected` transition (NOT on "found via scan" —
    /// finding the peripheral doesn't guarantee the connect succeeds, and
    /// resetting there meant we never escalated backoff on encryption
    /// failures).
    private var reconnectAttempts = 0
    /// Whether the last failure was an encryption/connect error (stale peripheral).
    private var lastFailWasEncryption = false
    /// Max direct UUID reconnect attempts before falling back to scan.
    private static let maxDirectAttempts = 2
    /// Upper bound on consecutive reconnect attempts before we stop trying
    /// and surface the error. Picked so that a wedged BLE link gets roughly
    /// 60 seconds of recovery before the user has to intervene.
    private static let maxReconnectAttempts = 8

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
            // Already mid-connect. Only interrupt if the state has been
            // stuck for more than 20s — otherwise we'd kill a handshake
            // that's actively progressing and cause a reconnect loop.
            let stuckFor = connectingSince.map { -$0.timeIntervalSinceNow } ?? 0
            guard stuckFor > 20 else {
                print("[Radio] foreground in \(connectionState), \(Int(stuckFor))s in — letting it finish")
                return
            }
            print("[Radio] foreground in \(connectionState), stuck \(Int(stuckFor))s — restarting connect")
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
            let prev = connectionState
            connectionState = s

            // Track when we entered a connect-in-progress state so
            // handleReturnToForeground can tell a fresh handshake from a
            // stuck one.
            switch s {
            case .connecting, .scanning:
                if connectingSince == nil { connectingSince = Date() }
            case .configuring:
                // configuring is the longer phase — reset the timer so we
                // give it a fresh 20s window before considering it stuck.
                connectingSince = Date()
            case .connected, .disconnected, .failed, .bluetoothUnavailable:
                connectingSince = nil
            }

            if case .connected = s {
                reconnectTask?.cancel()
                reconnectAttempts = 0
                lastFailWasEncryption = false
            } else if case .disconnected = s {
                // Why iOS fails the first direct reconnect almost every time:
                // after a mid-session drop CoreBluetooth's cached CBPeripheral
                // reference often goes stale — the next connect attempt fails
                // with an encryption error. Detect those cases up front so we
                // skip the wasted 3s direct attempt and go straight to scan,
                // which yields a fresh peripheral.
                if case .connecting = prev {
                    // Failed during initial connect phase = encryption issue.
                    lastFailWasEncryption = true
                } else if case .connected = prev {
                    // Mid-session drop — the peripheral reference on this
                    // side is now stale. Scan-based recovery is reliable;
                    // direct UUID is almost always going to fail encryption.
                    lastFailWasEncryption = true
                    print("[Radio] mid-session drop — skipping direct UUID, using scan")
                } else if case .configuring = prev {
                    // Same reasoning — if the link dropped during the
                    // handshake drain, the peripheral is stale too.
                    lastFailWasEncryption = true
                    print("[Radio] drop during configuring — skipping direct UUID, using scan")
                }
                configComplete = false
                if !userDisconnected && !suppressAutoReconnect {
                    scheduleReconnect()
                } else if suppressAutoReconnect {
                    print("[Radio] disconnect with auto-reconnect suppressed (onboarding)")
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
    ///
    /// Strategy:
    /// - Normal disconnect (e.g., timeout during config): try direct UUID reconnect
    ///   up to `maxDirectAttempts` times with backoff.
    /// - Encryption failure (stale BLE peripheral): skip directly to scan-based
    ///   reconnect to get a fresh `CBPeripheral` reference.
    /// - Scan-based: scans for the saved UUID, waits up to 15s, auto-connects
    ///   if found.
    private func scheduleReconnect() {
        guard let uuidString = UserDefaults.standard.string(forKey: Self.savedPeripheralKey),
              let uuid = UUID(uuidString: uuidString) else { return }

        reconnectAttempts += 1
        let attempt = reconnectAttempts

        // Hard ceiling. If we've retried this many times without success,
        // BLE is genuinely wedged (almost always iOS↔Heltec bonding state
        // drift) and hammering it more just wastes battery + log spam.
        // The user needs to Forget the device in iOS Bluetooth settings
        // and re-pair via the onboarding flow.
        guard attempt <= Self.maxReconnectAttempts else {
            print("[Radio] giving up after \(attempt - 1) reconnect attempts — " +
                  "the BLE link is wedged. Try: Settings → Bluetooth → Forget " +
                  "this device, then re-pair via PawMesh onboarding.")
            return
        }

        let needsScan = lastFailWasEncryption || attempt > Self.maxDirectAttempts

        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            guard let self else { return }

            if !needsScan {
                // Direct UUID reconnect with backoff: 3s, 6s
                let delay = attempt <= 1 ? 3 : 6
                print("[Radio] reconnect attempt \(attempt)/\(Self.maxReconnectAttempts) in \(delay)s (direct UUID)")
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                await self.radio.connectByUUID(uuid)
            } else {
                // Scan-based reconnect — gets a fresh CBPeripheral reference
                // which fixes stale encryption state.
                //
                // Exponential backoff for scan retries. Short delays don't
                // give iOS's BLE stack and the Heltec firmware enough time
                // to clean up after an encryption failure, so we end up
                // failing encryption on the next attempt too. Cap at 30s.
                let scanBackoff = min(30, 2 << min(attempt, 4))  // 4, 8, 16, 32→30, 30, 30…
                print("[Radio] scan-based reconnect (attempt \(attempt)/\(Self.maxReconnectAttempts), " +
                      "backoff \(scanBackoff)s, encryption fail: \(self.lastFailWasEncryption))")
                try? await Task.sleep(for: .seconds(scanBackoff))
                guard !Task.isCancelled else { return }

                self.lastFailWasEncryption = false
                await self.radio.startScan()

                // Wait up to 15 seconds for our specific device to appear
                for _ in 0..<30 {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }

                    if let found = self.discovered.first(where: { $0.id == uuid }) {
                        print("[Radio] found \(found.name) via scan, reconnecting")
                        await self.radio.stopScan()
                        // NOTE: do NOT reset reconnectAttempts here. Finding
                        // the peripheral doesn't mean we'll successfully
                        // connect. Reset only fires on an actual .connected
                        // event in handle(_:). Otherwise an encryption
                        // failure after a successful scan restarts the
                        // backoff at attempt 1, and we loop fast forever.
                        self.connect(uuid)
                        return
                    }
                }

                // Didn't find it — stop scanning, stay disconnected.
                print("[Radio] device not found after scan, giving up auto-reconnect")
                await self.radio.stopScan()
            }
        }
    }
}
