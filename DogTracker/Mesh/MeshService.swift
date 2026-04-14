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
    /// Channel configs received during handshake, keyed by index.
    private(set) var channels: [Int32: Channel] = [:]

    // MARK: - Private

    private let radio: RadioController
    private let modelContainer: ModelContainer
    private let log = Logger(subsystem: "com.levijohnson.DogTracker", category: "Mesh")
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

        // Use the private/secondary channel if one exists, otherwise primary
        let channelIndex = preferredChannelIndex

        var packet = MeshPacket()
        packet.from = myNodeNum
        packet.to = nodeNum
        packet.channel = UInt32(channelIndex)
        packet.wantAck = true
        packet.hopLimit = 3
        packet.id = packetID
        packet.decoded = data

        var toRadio = ToRadio()
        toRadio.packet = packet

        try await radio.radio.sendToRadio(toRadio)
        log.info("ping sent to \(nodeNum, format: .hex), id=\(packetID), ch=\(channelIndex), hopLimit=3")
        return packetID
    }

    /// The channel index to use for pings. Prefers a secondary (private)
    /// channel if one exists, otherwise falls back to the primary channel.
    private var preferredChannelIndex: Int32 {
        // If there's a secondary channel with a PSK, use it
        if let secondary = channels.values.first(where: {
            $0.role == .secondary && !$0.settings.psk.isEmpty
        }) {
            return secondary.index
        }
        // Otherwise use primary
        return 0
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

        case .channel(let ch):
            channels[ch.index] = ch
            let name = ch.settings.name.isEmpty ? "(default)" : ch.settings.name
            let hasPSK = !ch.settings.psk.isEmpty
            log.info("channel[\(ch.index)] role=\(ch.role.rawValue) name=\(name) hasPSK=\(hasPSK)")

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
            num: num, longName: "", shortName: "",
            hexID: String(format: "!%08x", num),
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

        switch packet.payloadVariant {
        case .decoded(let data):
            log.info("packet from \(from, format: .hex) portnum=\(data.portnum.rawValue) to=\(packet.to, format: .hex) bytes=\(data.payload.count)")

            switch data.portnum {
            case .positionApp:
                handlePositionPacket(from: from, payload: data.payload, isResponse: packet.to == myNodeNum)
            case .nodeinfoApp:
                // nodeinfoApp packets contain User objects (not NodeInfo)
                if let user = try? User(serializedBytes: data.payload) {
                    var node = nodes[from] ?? MeshNode(
                        num: from, longName: "", shortName: "",
                        hexID: String(format: "!%08x", from),
                        hwModel: .unset, hopsAway: 0
                    )
                    node.longName = user.longName
                    node.shortName = user.shortName
                    if !user.id.isEmpty { node.hexID = user.id }
                    node.hwModel = user.hwModel
                    nodes[from] = node
                }
            case .routingApp:
                handleRoutingPacket(from: from, payload: data.payload, to: packet.to)
            default:
                break
            }

        case .encrypted(let data):
            log.info("encrypted packet from \(from, format: .hex), \(data.count) bytes (cannot decode)")

        default:
            log.info("packet from \(from, format: .hex) with unknown payload variant")
        }
    }

    private func handleRoutingPacket(from nodeNum: UInt32, payload: Data, to: UInt32) {
        if let routing = try? Routing(serializedBytes: payload) {
            let errName: String
            switch routing.variant {
            case .errorReason(let err):
                errName = "\(err)"
            default:
                errName = "ack"
            }
            log.info("routing from \(nodeNum, format: .hex) to \(to, format: .hex): \(errName)")
        }
    }

    private func handlePositionPacket(from nodeNum: UInt32, payload: Data, isResponse: Bool) {
        guard let position = try? Position(serializedBytes: payload) else {
            log.warning("failed to decode Position from \(nodeNum, format: .hex), payload=\(payload.count) bytes")
            return
        }

        let lat = Double(position.latitudeI) * 1e-7
        let lon = Double(position.longitudeI) * 1e-7
        log.info("position from \(nodeNum, format: .hex): \(lat),\(lon) alt=\(position.altitude) time=\(position.time) sats=\(position.satsInView) precBits=\(position.precisionBits) isResponse=\(isResponse)")

        if lat == 0 && lon == 0 {
            log.info("position from \(nodeNum, format: .hex) is 0,0 (no GPS fix)")
            // Still update lastHeard and mark that the node responded
            if var node = nodes[nodeNum] {
                node.lastHeard = Date()
                node.lastPositionUpdate = Date()
                nodes[nodeNum] = node
            }
            return
        }

        // Update in-memory NodeDB — create the node if it doesn't exist yet
        var node = nodes[nodeNum] ?? MeshNode(
            num: nodeNum, longName: "", shortName: "",
            hexID: String(format: "!%08x", nodeNum),
            hwModel: .unset, hopsAway: 0
        )
        applyPosition(position, to: &node)
        node.lastHeard = Date()
        nodes[nodeNum] = node

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
        node.lastPositionUpdate = Date()
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

        // Prune old fixes: cap at 2000 per tracker
        pruneOldFixes(trackerNodeNum: nodeNum, context: context)
    }

    /// Delete oldest fixes when a tracker exceeds 2000 stored fixes.
    private func pruneOldFixes(trackerNodeNum: UInt32, context: ModelContext) {
        let descriptor = FetchDescriptor<Fix>(
            predicate: #Predicate { $0.tracker?.nodeNum == trackerNodeNum },
            sortBy: [SortDescriptor(\.fixTime, order: .reverse)]
        )
        do {
            let allFixes = try context.fetch(descriptor)
            let maxFixes = 2000
            guard allFixes.count > maxFixes else { return }
            for fix in allFixes[maxFixes...] {
                context.delete(fix)
            }
            try context.save()
            log.info("pruned \(allFixes.count - maxFixes) old fixes for node \(trackerNodeNum, format: .hex)")
        } catch {
            log.error("failed to prune fixes: \(error.localizedDescription)")
        }
    }
}
