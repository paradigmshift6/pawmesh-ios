import Foundation
import Observation
import SwiftData
import OSLog

/// Central mesh state manager. Consumes `RadioEvent`s from `RadioController`,
/// maintains the in-memory NodeDB, and writes position fixes into SwiftData
/// for tracked dogs.
@MainActor
@Observable
final class MeshService {

    // MARK: - Published state

    /// All nodes the mesh knows about, keyed by node number.
    private(set) var nodes: [UInt32: MeshNode] = [:]
    /// Our own node number, learned from `MyNodeInfo`.
    private(set) var myNodeNum: UInt32 = 0

    // MARK: - Private

    private let radio: RadioController
    private let modelContainer: ModelContainer
    private let log = Logger(subsystem: "com.example.DogTracker", category: "Mesh")
    private var consumer: Task<Void, Never>?

    init(radio: RadioController, modelContainer: ModelContainer) {
        self.radio = radio
        self.modelContainer = modelContainer
    }


    /// Start consuming radio events. Call once at app startup, after
    /// `radio.start()`.
    func start() {
        guard consumer == nil else { return }
        consumer = Task { [weak self] in
            guard let self else { return }
            let stream = await self.radio.radio.subscribe()
            for await event in stream {
                self.handle(event)
            }
        }
    }

    // MARK: - Ping support (phase 7)

    /// Send a position request to a tracker. Returns the packet ID for
    /// correlation. The tracker should reply with a fresh Position.
    func requestPosition(from nodeNum: UInt32) async throws -> UInt32 {
        let packetID = UInt32.random(in: 1...UInt32.max)

        var data = DataMessage()
        data.portnum = .positionApp
        data.payload = Data()
        data.wantResponse = true

        var packet = MeshPacket()
        packet.to = nodeNum
        packet.wantAck = true
        packet.id = packetID
        packet.decoded = data

        var toRadio = ToRadio()
        toRadio.packet = packet

        try await radio.radio.sendToRadio(toRadio)
        log.info("ping sent to \(nodeNum, format: .hex), id=\(packetID)")
        return packetID
    }

    // MARK: - Event handling

    private func handle(_ event: RadioEvent) {
        switch event {
        case .fromRadio(let msg):
            processFromRadio(msg)
        case .stateChanged(let state):
            if case .disconnected = state {
                // Keep NodeDB — it's useful for the "last seen" display.
                // Just note we lost the link.
            }
        case .configComplete:
            log.info("config complete, NodeDB has \(self.nodes.count) nodes")
        default:
            break
        }
    }

    private func processFromRadio(_ msg: FromRadio) {
        guard let variant = msg.payloadVariant else { return }

        switch variant {
        case .myInfo(let info):
            myNodeNum = info.myNodeNum
            log.info("my node num = \(info.myNodeNum, format: .hex)")

        case .nodeInfo(let info):
            upsertNodeInfo(info)

        case .packet(let packet):
            processPacket(packet)

        default:
            break
        }
    }

    // MARK: - NodeDB updates

    private func upsertNodeInfo(_ info: NodeInfo) {
        let num = info.num
        var node = nodes[num] ?? MeshNode(
            num: num, longName: "", shortName: "", hexID: "",
            hwModel: .unset, hopsAway: 0
        )
        if info.hasUser {
            node.longName = info.user.longName
            node.shortName = info.user.shortName
            node.hexID = info.user.id
            node.hwModel = info.user.hwModel
        }
        if info.hasPosition {
            applyPosition(info.position, to: &node)
        }
        node.snr = info.snr
        if info.lastHeard > 0 {
            node.lastHeard = Date(timeIntervalSince1970: Double(info.lastHeard))
        }
        node.hopsAway = info.hopsAway
        nodes[num] = node
    }

    private func processPacket(_ packet: MeshPacket) {
        let from = packet.from
        // Update lastHeard for any inbound packet
        if var node = nodes[from] {
            node.lastHeard = Date()
            if packet.rxSnr != 0 { node.snr = packet.rxSnr }
            nodes[from] = node
        }

        guard case .decoded(let data) = packet.payloadVariant else { return }

        switch data.portnum {
        case .positionApp:
            handlePositionPacket(from: from, payload: data.payload, isResponse: data.wantResponse == false && packet.to == myNodeNum)
        case .nodeinfoApp:
            if let info = try? NodeInfo(serializedBytes: data.payload) {
                upsertNodeInfo(info)
            }
        default:
            break
        }
    }

    private func handlePositionPacket(from nodeNum: UInt32, payload: Data, isResponse: Bool) {
        guard let position = try? Position(serializedBytes: payload) else {
            log.warning("failed to decode Position from \(nodeNum, format: .hex)")
            return
        }

        // Update in-memory NodeDB
        if var node = nodes[nodeNum] {
            applyPosition(position, to: &node)
            nodes[nodeNum] = node
        }

        // Persist to SwiftData if this node is a tracked dog
        persistFix(nodeNum: nodeNum, position: position, source: isResponse ? .requested : .scheduled)
    }

    private func applyPosition(_ pos: Position, to node: inout MeshNode) {
        let lat = Double(pos.latitudeI) * 1e-7
        let lon = Double(pos.longitudeI) * 1e-7
        // Filter out 0,0 "no fix" convention
        guard !(lat == 0 && lon == 0) else { return }
        node.latitude = lat
        node.longitude = lon
        if pos.altitude != 0 { node.altitude = Double(pos.altitude) }
        if pos.time > 0 {
            node.positionTime = Date(timeIntervalSince1970: Double(pos.time))
        }
    }

    // MARK: - SwiftData persistence

    private func persistFix(nodeNum: UInt32, position: Position, source: FixSource) {
        let lat = Double(position.latitudeI) * 1e-7
        let lon = Double(position.longitudeI) * 1e-7
        guard !(lat == 0 && lon == 0) else { return }

        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<Tracker>(
            predicate: #Predicate { $0.nodeNum == nodeNum }
        )
        guard let tracker = try? context.fetch(descriptor).first else {
            return // Not a tracked dog — skip
        }

        let fixTime: Date
        if position.time > 0 {
            fixTime = Date(timeIntervalSince1970: Double(position.time))
        } else {
            fixTime = Date()
        }

        let fix = Fix(
            tracker: tracker,
            latitude: lat,
            longitude: lon,
            altitude: position.altitude != 0 ? Double(position.altitude) : nil,
            fixTime: fixTime,
            sats: position.satsInView > 0 ? Int(position.satsInView) : nil,
            precisionBits: position.precisionBits > 0 ? Int(position.precisionBits) : nil,
            source: source
        )
        context.insert(fix)
        do {
            try context.save()
        } catch {
            log.error("failed to save fix: \(error.localizedDescription)")
        }
    }
}
