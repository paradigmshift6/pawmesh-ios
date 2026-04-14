import Foundation
@preconcurrency import CoreBluetooth
import OSLog

/// CoreBluetooth implementation of `RadioTransport` for Meshtastic radios.
///
/// All UUIDs come from DESIGN.md §3.1. The flow:
///   1. `startScan()` starts a service-filtered scan; matching peripherals are
///      reported via `.discovered`.
///   2. `connect(peripheralID:)` opens a GATT connection.
///   3. On `didDiscoverCharacteristics`, we cache TORADIO/FROMRADIO/FROMNUM,
///      subscribe to FROMNUM notifications, and emit `.characteristicsReady`.
///   4. `MeshtasticRadio` writes a `wantConfigID` ToRadio. After the first
///      write completes, we trigger an initial FROMRADIO read; from that point
///      we drain repeatedly until the radio returns an empty payload, then sit
///      idle until the next FROMNUM notification ticks.
///
/// `@unchecked Sendable` is OK because every mutable property is touched only
/// from `queue` (a serial DispatchQueue) — both directly and via the
/// CBCentralManager/CBPeripheral delegate callbacks, which CoreBluetooth
/// dispatches to that same queue.
final class BLERadioTransport: NSObject, RadioTransport, @unchecked Sendable {

    // MARK: - Meshtastic BLE service / characteristics (DESIGN §3.1)

    static let serviceUUID       = CBUUID(string: "6ba1b218-15a8-461f-9fa8-5dcae273eafd")
    static let toRadioCharUUID   = CBUUID(string: "f75c76d2-129e-4dad-a1dd-7866124401e7")
    static let fromRadioCharUUID = CBUUID(string: "2c55e69e-4993-11ed-b878-0242ac120002")
    static let fromNumCharUUID   = CBUUID(string: "ed9da18c-a800-4f66-a670-aa7547e34453")

    private static let restoreIdentifier = "com.levijohnson.DogTracker.bleRestore"

    // MARK: - Public

    let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation

    // MARK: - Internal state (queue-confined)

    private let log = Logger(subsystem: "com.levijohnson.DogTracker", category: "BLE")
    private let queue = DispatchQueue(label: "com.levijohnson.DogTracker.ble", qos: .userInitiated)
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var toRadioChar: CBCharacteristic?
    private var fromRadioChar: CBCharacteristic?
    private var fromNumChar: CBCharacteristic?
    private var discovered: [UUID: CBPeripheral] = [:]
    private var pendingConnectID: UUID?

    override init() {
        var c: AsyncStream<TransportEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        self.continuation = c
        super.init()
        // Restore identifier enables iOS to wake us when a known peripheral
        // shows up while the app is suspended (phase 10).
        self.central = CBCentralManager(
            delegate: self,
            queue: queue,
            options: [
                CBCentralManagerOptionShowPowerAlertKey: true,
                CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier,
            ]
        )
    }

    // MARK: - RadioTransport

    func startScan() {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.central.state == .poweredOn else {
                self.log.warning("startScan: BT not powered on")
                return
            }
            self.discovered.removeAll()
            self.central.scanForPeripherals(
                withServices: [Self.serviceUUID],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
            self.log.info("scan started")
        }
    }

    func stopScan() {
        queue.async { [weak self] in
            self?.central.stopScan()
        }
    }

    func connect(peripheralID: UUID) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let p = self.discovered[peripheralID] ?? self.central
                    .retrievePeripherals(withIdentifiers: [peripheralID]).first else {
                self.continuation.yield(.error("no such peripheral \(peripheralID)"))
                return
            }
            self.central.stopScan()
            self.peripheral = p
            self.pendingConnectID = peripheralID
            p.delegate = self
            self.continuation.yield(.connecting(peripheralID))
            self.central.connect(p, options: nil)
        }
    }

    func disconnect() {
        queue.async { [weak self] in
            guard let self, let p = self.peripheral else { return }
            self.central.cancelPeripheralConnection(p)
        }
    }

    func writeToRadio(_ data: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let p = self.peripheral, let ch = self.toRadioChar else {
                self.continuation.yield(.error("writeToRadio: not connected"))
                return
            }
            // Use .withResponse so didWriteValueFor fires reliably; that callback
            // is what kicks off the initial FROMRADIO drain after handshake.
            p.writeValue(data, for: ch, type: .withResponse)
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLERadioTransport: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let on = central.state == .poweredOn
        let reason: String
        switch central.state {
        case .poweredOn:    reason = "powered on"
        case .poweredOff:   reason = "Bluetooth is off"
        case .unauthorized: reason = "Bluetooth permission denied"
        case .unsupported:  reason = "Bluetooth not supported on this device"
        case .resetting:    reason = "Bluetooth is resetting"
        case .unknown:      reason = "Bluetooth state unknown"
        @unknown default:   reason = "Bluetooth in an unknown state"
        }
        continuation.yield(.bluetoothStateChanged(isPoweredOn: on, reason: reason))
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        discovered[peripheral.identifier] = peripheral
        let advertised = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? advertised ?? "Meshtastic"
        continuation.yield(.discovered(DiscoveredPeripheral(
            id: peripheral.identifier,
            name: name,
            rssi: RSSI.intValue,
            lastSeen: Date()
        )))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log.info("BLE connected: \(peripheral.identifier)")
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        log.info("BLE disconnected: \(error?.localizedDescription ?? "ok")")
        self.peripheral = nil
        self.toRadioChar = nil
        self.fromRadioChar = nil
        self.fromNumChar = nil
        continuation.yield(.disconnected(reason: error?.localizedDescription))
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        let msg = error?.localizedDescription ?? "failed to connect"
        log.error("BLE failed to connect: \(msg)")
        // Clean up state exactly like didDisconnect so the reconnect
        // logic can proceed — without this the state machine gets stuck
        // at .connecting and no reconnect ever fires.
        self.peripheral = nil
        self.toRadioChar = nil
        self.fromRadioChar = nil
        self.fromNumChar = nil
        continuation.yield(.disconnected(reason: msg))
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        // Phase 10 hook. iOS may hand us back peripherals it was holding for us
        // when the app was suspended. We just adopt them so the regular
        // didConnect/didDiscover flow can resume.
        if let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            for p in restored {
                discovered[p.identifier] = p
                if peripheral == nil {
                    peripheral = p
                    p.delegate = self
                }
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLERadioTransport: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for s in services where s.uuid == Self.serviceUUID {
            peripheral.discoverCharacteristics(
                [Self.toRadioCharUUID, Self.fromRadioCharUUID, Self.fromNumCharUUID],
                for: s
            )
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard let chars = service.characteristics else { return }
        for c in chars {
            switch c.uuid {
            case Self.toRadioCharUUID:
                toRadioChar = c
            case Self.fromRadioCharUUID:
                fromRadioChar = c
            case Self.fromNumCharUUID:
                fromNumChar = c
                peripheral.setNotifyValue(true, for: c)
            default:
                break
            }
        }
        if toRadioChar != nil, fromRadioChar != nil, fromNumChar != nil {
            let name = peripheral.name ?? "Meshtastic"
            continuation.yield(.characteristicsReady(peripheral.identifier, name: name))
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            continuation.yield(.error("read error: \(error.localizedDescription)"))
            return
        }
        if characteristic.uuid == Self.fromNumCharUUID {
            // Notification tick → drain FROMRADIO from the top.
            if let ch = fromRadioChar {
                peripheral.readValue(for: ch)
            }
        } else if characteristic.uuid == Self.fromRadioCharUUID {
            if let value = characteristic.value, !value.isEmpty {
                continuation.yield(.fromRadioPayload(value))
                // Keep draining until the radio returns an empty payload.
                peripheral.readValue(for: characteristic)
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            continuation.yield(.error("write error: \(error.localizedDescription)"))
            return
        }
        // First write after characteristics are ready is the wantConfigID
        // handshake. Trigger an initial FROMRADIO drain to start receiving
        // the radio's NodeDB dump.
        if characteristic.uuid == Self.toRadioCharUUID, let ch = fromRadioChar {
            peripheral.readValue(for: ch)
        }
    }
}
