import Foundation
import OSLog
import SwiftProtobuf

/// High-level Meshtastic radio actor: owns a `RadioTransport`, runs the
/// `wantConfigID` handshake (DESIGN §3.2), decodes inbound `FromRadio`
/// protobufs, and republishes them as `RadioEvent`s.
///
/// This is the layer the rest of the app talks to. UI code touches it through
/// `RadioController` (a `@MainActor @Observable` thin adapter).
actor MeshtasticRadio {

    // MARK: - Public state

    /// Current connection state. Mirrored into `RadioController` for SwiftUI.
    private(set) var state: RadioConnectionState = .disconnected
    /// Most recent scan results.
    private(set) var discovered: [DiscoveredPeripheral] = []

    // MARK: - Private state

    private let transport: RadioTransport
    private let log = Logger(subsystem: "com.example.DogTracker", category: "Radio")
    private var consumer: Task<Void, Never>?
    private var pendingWantConfigID: UInt32 = 0
    private var subscribers: [AsyncStream<RadioEvent>.Continuation] = []

    init(transport: RadioTransport) {
        self.transport = transport
    }

    /// Create a new event stream. Each subscriber receives ALL events
    /// independently — AsyncStream is single-consumer, so each caller
    /// gets its own stream and continuation.
    func subscribe() -> AsyncStream<RadioEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: RadioEvent.self, bufferingPolicy: .unbounded)
        subscribers.append(continuation)
        return stream
    }

    /// Begin consuming transport events. Idempotent.
    func start() {
        guard consumer == nil else { return }
        let stream = transport.events
        consumer = Task { [weak self] in
            for await event in stream {
                await self?.handle(event)
            }
        }
    }

    // MARK: - Public commands

    func startScan() {
        discovered.removeAll()
        emit(.discovered([]))
        setState(.scanning)
        transport.startScan()
    }

    func stopScan() {
        transport.stopScan()
    }

    func connect(_ id: UUID) {
        guard let dp = discovered.first(where: { $0.id == id }) else {
            log.warning("connect: unknown peripheral \(id)")
            return
        }
        setState(.connecting(name: dp.name))
        transport.connect(peripheralID: id)
    }

    func disconnect() {
        transport.disconnect()
    }

    /// Connect directly by UUID without a prior scan. Used for auto-reconnect
    /// to a previously paired peripheral.
    func connectByUUID(_ id: UUID) {
        setState(.connecting(name: "Reconnecting…"))
        transport.connect(peripheralID: id)
    }

    /// Send a fully-formed `ToRadio` to the radio. Used by phase 7 (Ping) and
    /// any future feature that wants to talk back upstream.
    func sendToRadio(_ message: ToRadio) throws {
        let data = try message.serializedData()
        transport.writeToRadio(data)
    }

    // MARK: - Transport event handling

    private func handle(_ event: TransportEvent) {
        switch event {

        case .bluetoothStateChanged(let on, let reason):
            if !on {
                setState(.bluetoothUnavailable(reason: reason))
            } else if state == .bluetoothUnavailable(reason: reason) || state == .disconnected {
                setState(.disconnected)
            }

        case .discovered(let p):
            if let idx = discovered.firstIndex(where: { $0.id == p.id }) {
                discovered[idx] = p
            } else {
                discovered.append(p)
            }
            emit(.discovered(discovered))

        case .connecting:
            // Already reflected by our own setState in connect(); transport
            // sends this for cases where it began connecting on its own
            // (e.g. state restoration).
            break

        case .characteristicsReady(_, let name):
            setState(.configuring(name: name))
            beginHandshake()

        case .disconnected(let reason):
            if let r = reason {
                log.info("disconnected: \(r)")
            }
            setState(.disconnected)

        case .fromRadioPayload(let data):
            decodeFromRadio(data)

        case .error(let msg):
            log.error("transport error: \(msg)")
            emit(.logMessage("error: \(msg)"))
        }
    }

    // MARK: - Handshake & decode

    private func beginHandshake() {
        let id = UInt32.random(in: 1...UInt32.max)
        pendingWantConfigID = id

        var toRadio = ToRadio()
        toRadio.wantConfigID = id

        do {
            let data = try toRadio.serializedData()
            transport.writeToRadio(data)
            log.info("sent wantConfigID=\(id, format: .hex)")
        } catch {
            log.error("encode wantConfigID failed: \(error.localizedDescription)")
            setState(.failed(reason: "handshake encode failed"))
        }
    }

    private func decodeFromRadio(_ data: Data) {
        do {
            let msg = try FromRadio(serializedBytes: data)
            emit(.fromRadio(msg))

            switch msg.payloadVariant {
            case .configCompleteID(let id) where id == pendingWantConfigID:
                if case .configuring(let name) = state {
                    setState(.connected(name: name))
                } else {
                    setState(.connected(name: "Meshtastic"))
                }
                emit(.configComplete)
                pendingWantConfigID = 0
            default:
                break
            }
        } catch {
            log.error("FromRadio decode error: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private func setState(_ new: RadioConnectionState) {
        guard new != state else { return }
        state = new
        emit(.stateChanged(new))
    }

    private func emit(_ event: RadioEvent) {
        for c in subscribers { c.yield(event) }
    }
}

/// Events emitted by `MeshtasticRadio` for upstream consumers (UI, MeshService).
enum RadioEvent: Sendable {
    case stateChanged(RadioConnectionState)
    case discovered([DiscoveredPeripheral])
    /// Decoded `FromRadio` packet. Mesh service consumes these to update NodeDB
    /// and route position updates.
    case fromRadio(FromRadio)
    /// Initial NodeDB dump is complete; the radio is now reporting live mesh
    /// traffic. Useful for "skip the splash" UI transitions.
    case configComplete
    case logMessage(String)
}
