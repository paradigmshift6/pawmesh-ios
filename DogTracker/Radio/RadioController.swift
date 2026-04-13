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

    // MARK: - Commands

    func startScan()      { Task { await radio.startScan() } }
    func stopScan()       { Task { await radio.stopScan() } }
    func connect(_ id: UUID) { Task { await radio.connect(id) } }
    func disconnect()     { Task { await radio.disconnect() } }

    // MARK: - Event handling

    private func handle(_ event: RadioEvent) {
        switch event {
        case .stateChanged(let s):
            connectionState = s
            if case .connected = s {} else if s != .configuring(name: "") {
                // configComplete only resets on a fresh connect cycle
                if case .disconnected = s { configComplete = false }
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
}
