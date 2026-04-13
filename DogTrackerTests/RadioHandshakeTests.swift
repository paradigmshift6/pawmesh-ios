import XCTest
import SwiftProtobuf
@testable import DogTracker

/// Drives `MeshtasticRadio` against a `FakeRadioTransport` to verify the
/// connection state machine and the `wantConfigID` handshake.
final class RadioHandshakeTests: XCTestCase {

    func testHandshakeReachesConnectedState() async throws {
        let fake = FakeRadioTransport()
        let radio = MeshtasticRadio(transport: fake)

        // Subscribe to events BEFORE driving the transport so we don't miss
        // the configComplete signal.
        let stream = await radio.subscribe()
        await radio.start()

        // Phase 1: scan + discover
        await radio.startScan()
        let pid = UUID()
        fake.feed(.discovered(DiscoveredPeripheral(
            id: pid, name: "Heltec_TEST", rssi: -55, lastSeen: .now
        )))

        // Yield to let the consumer pick up the discovered event
        try await Task.sleep(for: .milliseconds(20))

        // Phase 2: connect + characteristics ready
        await radio.connect(pid)
        fake.feed(.characteristicsReady(pid, name: "Heltec_TEST"))

        // Phase 3: wait for the radio to write its handshake
        let wantConfigID = try await waitForHandshakeWrite(fake)

        // Phase 4: simulate the radio replying with configCompleteID
        var fr = FromRadio()
        fr.configCompleteID = wantConfigID
        fake.feed(.fromRadioPayload(try fr.serializedData()))

        // Phase 5: wait for the radio to transition to .connected
        try await waitFor(stream: stream, timeout: .seconds(2)) { event in
            if case .stateChanged(.connected(let name)) = event, name == "Heltec_TEST" {
                return true
            }
            return false
        }

        let finalState = await radio.state
        XCTAssertEqual(finalState, .connected(name: "Heltec_TEST"))
    }

    func testInboundFromRadioIsRepublished() async throws {
        let fake = FakeRadioTransport()
        let radio = MeshtasticRadio(transport: fake)
        let stream = await radio.subscribe()
        await radio.start()

        // Manufacture a Position-bearing FromRadio packet
        var position = Position()
        position.latitudeI = 444_280_000
        position.longitudeI = -1_105_885_000
        position.altitude = 2_400

        var data = DataMessage()
        data.portnum = .positionApp
        data.payload = try position.serializedData()

        var packet = MeshPacket()
        packet.from = 0xa1b2c3d4
        packet.id = 1
        packet.decoded = data

        var fr = FromRadio()
        fr.id = 1
        fr.packet = packet

        fake.feed(.fromRadioPayload(try fr.serializedData()))

        try await waitFor(stream: stream, timeout: .seconds(2)) { event in
            if case .fromRadio(let msg) = event,
               case .packet(let p) = msg.payloadVariant,
               p.from == 0xa1b2c3d4 {
                return true
            }
            return false
        }
    }

    // MARK: - Helpers

    /// Polls the fake transport's `writes` until it sees a `ToRadio` carrying
    /// a `wantConfigID`. Returns that ID.
    private func waitForHandshakeWrite(
        _ fake: FakeRadioTransport,
        timeout: Duration = .seconds(2)
    ) async throws -> UInt32 {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            for data in fake.writes {
                if let toRadio = try? ToRadio(serializedBytes: data),
                   case .wantConfigID(let id) = toRadio.payloadVariant {
                    return id
                }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("never saw a wantConfigID write")
        return 0
    }

    /// Awaits until `predicate` returns true for some event from `stream`,
    /// or the timeout elapses (in which case the test fails).
    private func waitFor(
        stream: AsyncStream<RadioEvent>,
        timeout: Duration,
        predicate: @escaping (RadioEvent) -> Bool
    ) async throws {
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await event in stream {
                    if predicate(event) { return true }
                }
                return false
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return false
            }
            if let first = try await group.next(), first {
                group.cancelAll()
                return
            }
            group.cancelAll()
            XCTFail("waitFor: predicate never matched within \(timeout)")
        }
    }
}
