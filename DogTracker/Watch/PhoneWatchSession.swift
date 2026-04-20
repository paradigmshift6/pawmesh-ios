import Foundation
import Observation
import SwiftData
import WatchConnectivity
import CoreLocation
import UIKit
import OSLog

/// iOS side of the WatchConnectivity bridge.
///
/// Responsibilities:
///   - Activate `WCSession` on launch.
///   - Build a `FleetSnapshot` from `MeshService` + `LocationProvider` +
///     `RadioController` + `UnitSettings` + the SwiftData `Tracker` table.
///   - Push the snapshot to the watch via `updateApplicationContext` whenever
///     anything changes — the system coalesces, so the watch always sees the
///     latest state.
///   - Handle inbound `sendMessage` requests from the watch (currently only
///     "ping a tracker") and reply immediately so the watch isn't waiting on
///     the mesh round-trip.
@MainActor
@Observable
final class PhoneWatchSession: NSObject {

    private let mesh: MeshService
    private let radio: RadioController
    private let location: LocationProvider
    private let units: UnitSettings
    private let modelContainer: ModelContainer
    private let log = Logger(subsystem: "com.levijohnson.DogTracker", category: "WatchSession")

    /// Last snapshot we successfully pushed. Compared against the next build
    /// to skip no-op WC updates.
    private var lastPushed: FleetSnapshot = .empty
    /// Last error from `updateApplicationContext`, surfaced for debugging.
    private(set) var lastError: String?
    private(set) var isActivated = false
    private(set) var isReachable = false

    /// Coalescing timer for pushSnapshotSoon().
    private var pendingPushTask: Task<Void, Never>?
    /// Background task that periodically rebuilds the snapshot and pushes
    /// only when something actually changed. Cheap because the equality
    /// check skips no-op pushes.
    private var pollTask: Task<Void, Never>?

    init(
        mesh: MeshService,
        radio: RadioController,
        location: LocationProvider,
        units: UnitSettings,
        modelContainer: ModelContainer
    ) {
        self.mesh = mesh
        self.radio = radio
        self.location = location
        self.units = units
        self.modelContainer = modelContainer
        super.init()
    }

    // MARK: - Lifecycle

    func start() {
        guard WCSession.isSupported() else {
            log.info("WCSession not supported on this device")
            return
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        log.info("WCSession activate requested")

        // Poll every 5s for changes; pushSnapshotIfChanged is a no-op when the
        // snapshot hasn't actually changed, so this is cheap.
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { return }
                await MainActor.run {
                    self?.pushSnapshotIfChanged()
                }
            }
        }
    }

    /// Coalesce rapid changes — multiple callers can request a push and we
    /// only do one ~250ms later. Cheap because applicationContext already
    /// coalesces on its own; this just keeps us from rebuilding the snapshot
    /// every time MeshService nudges nodes during a config drain.
    func pushSnapshotSoon() {
        pendingPushTask?.cancel()
        pendingPushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
            self?.pushSnapshotIfChanged()
        }
    }

    // MARK: - Snapshot building

    private func pushSnapshotIfChanged() {
        let snapshot = buildSnapshot()
        // Compare excluding generatedAt (which always differs).
        if snapshotsEquivalent(snapshot, lastPushed) { return }
        push(snapshot)
    }

    private func snapshotsEquivalent(_ a: FleetSnapshot, _ b: FleetSnapshot) -> Bool {
        a.trackers == b.trackers
            && a.userLocation == b.userLocation
            && a.linkState == b.linkState
            && a.useMetric == b.useMetric
    }

    private func buildSnapshot() -> FleetSnapshot {
        let trackers = currentTrackers()
        let snapshots: [TrackerSnapshot] = trackers.map { tracker in
            let node = mesh.nodes[tracker.nodeNum]
            let fix: FixSnapshot? = {
                guard let node, node.hasPosition,
                      let lat = node.latitude, let lon = node.longitude,
                      let fixTime = node.positionTime else { return nil }
                return FixSnapshot(
                    latitude: lat,
                    longitude: lon,
                    altitude: node.altitude,
                    fixTime: fixTime,
                    receivedAt: node.lastPositionUpdate ?? fixTime
                )
            }()
            return TrackerSnapshot(
                nodeNum: tracker.nodeNum,
                name: tracker.name,
                colorHex: tracker.colorHex,
                photoThumbnail: Self.watchThumbnail(from: tracker.photoData),
                lastFix: fix,
                batteryPercent: node?.batteryLevel,
                isBatteryLow: node?.isBatteryLow ?? false
            )
        }

        let userLoc: UserLocation? = {
            guard let loc = location.userLocation else { return nil }
            return UserLocation(
                latitude: loc.coordinate.latitude,
                longitude: loc.coordinate.longitude,
                trueHeading: location.heading?.trueHeading,
                capturedAt: loc.timestamp
            )
        }()

        return FleetSnapshot(
            trackers: snapshots,
            userLocation: userLoc,
            linkState: mapLinkState(radio.connectionState),
            useMetric: units.useMetric,
            generatedAt: .now
        )
    }

    private func currentTrackers() -> [Tracker] {
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<Tracker>(sortBy: [SortDescriptor(\.assignedAt)])
        return (try? context.fetch(descriptor)) ?? []
    }

    private func mapLinkState(_ state: RadioConnectionState) -> RadioLinkState {
        switch state {
        case .connected: .connected
        case .connecting, .configuring, .scanning: .connecting
        case .disconnected, .failed, .bluetoothUnavailable: .disconnected
        }
    }

    // MARK: - Push

    private func push(_ snapshot: FleetSnapshot) {
        let session = WCSession.default
        guard session.activationState == .activated else {
            log.info("skipping push — WCSession not activated yet")
            return
        }
        do {
            let data = try JSONEncoder.snapshot.encode(snapshot)
            try session.updateApplicationContext([WatchWireKey.snapshot: data])
            lastPushed = snapshot
            lastError = nil
            log.info("pushed snapshot — trackers=\(snapshot.trackers.count) link=\(snapshot.linkState.rawValue)")
        } catch {
            lastError = error.localizedDescription
            log.error("push failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - WCSessionDelegate

extension PhoneWatchSession: WCSessionDelegate {

    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in
            self.isActivated = (activationState == .activated)
            if let error {
                self.log.error("activation error: \(error.localizedDescription)")
            } else {
                self.log.info("WCSession activated, paired=\(session.isPaired) installed=\(session.isWatchAppInstalled)")
            }
            // Push initial state once activated
            if activationState == .activated {
                self.pushSnapshotIfChanged()
            }
        }
    }

    // iOS-only delegate methods — required to compile but no-ops for our
    // use case (single watch, no need to multiplex sessions).
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // After deactivation re-activate so the next paired watch can connect.
        WCSession.default.activate()
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        // Reachability flaps constantly as the watch goes in/out of
        // foreground, so only record the flag — no log line, otherwise
        // the console fills up with noise during normal use.
        Task { @MainActor in
            self.isReachable = session.isReachable
        }
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        // WCSession bridges Swift integers as NSNumber on the wire, so
        // accept any numeric form and coerce to UInt32.
        let op = message[WatchWireKey.op] as? String
        let nodeNum = Self.parseNodeNum(message)

        Task { @MainActor in
            switch op {
            case WatchWireOp.ping where nodeNum != 0:
                do {
                    _ = try await self.mesh.requestPosition(from: nodeNum)
                    replyHandler([WatchWireKey.queued: true])
                    self.log.info("ping queued for \(nodeNum, format: .hex) (from watch)")
                } catch {
                    replyHandler([
                        WatchWireKey.queued: false,
                        WatchWireKey.error: error.localizedDescription
                    ])
                    self.log.error("ping for \(nodeNum, format: .hex) failed: \(error.localizedDescription)")
                }
            default:
                replyHandler([
                    WatchWireKey.queued: false,
                    WatchWireKey.error: "unknown op: \(op ?? "nil")"
                ])
            }
        }
    }

    /// Handles the queued fallback from the watch: when the phone was asleep
    /// and the watch couldn't use `sendMessage`, it falls back to
    /// `transferUserInfo`, which lands here whenever the iOS app wakes up.
    nonisolated func session(_ session: WCSession,
                             didReceiveUserInfo userInfo: [String: Any] = [:]) {
        let op = userInfo[WatchWireKey.op] as? String
        let nodeNum = Self.parseNodeNum(userInfo)

        Task { @MainActor in
            if op == WatchWireOp.ping && nodeNum != 0 {
                do {
                    _ = try await self.mesh.requestPosition(from: nodeNum)
                    self.log.info("queued ping replayed for \(nodeNum, format: .hex)")
                } catch {
                    self.log.error("queued ping replay for \(nodeNum, format: .hex) failed: \(error.localizedDescription)")
                }
            }
        }
    }

    nonisolated private static func parseNodeNum(_ message: [String: Any]) -> UInt32 {
        if let n = message[WatchWireKey.nodeNum] as? NSNumber {
            return n.uint32Value
        }
        return 0
    }

    /// Produces a ~64x64 JPEG from the tracker's full-res photo so it can
    /// be shipped in the FleetSnapshot dictionary without blowing past the
    /// 64KB applicationContext cap. Returns nil on failure or no input.
    nonisolated private static func watchThumbnail(from photoData: Data?) -> Data? {
        guard let photoData, let src = UIImage(data: photoData) else { return nil }
        let target: CGFloat = 64
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: target, height: target),
            format: {
                let f = UIGraphicsImageRendererFormat()
                f.scale = 1
                f.opaque = true
                return f
            }()
        )
        let resized = renderer.image { _ in
            // Aspect-fill crop to a square so the watch can render as a circle.
            let aspect = src.size.width / src.size.height
            let drawSize: CGSize
            if aspect > 1 {
                drawSize = CGSize(width: target * aspect, height: target)
            } else {
                drawSize = CGSize(width: target, height: target / aspect)
            }
            let x = (target - drawSize.width) / 2
            let y = (target - drawSize.height) / 2
            src.draw(in: CGRect(x: x, y: y, width: drawSize.width, height: drawSize.height))
        }
        return resized.jpegData(compressionQuality: 0.65)
    }
}

// JSONEncoder.snapshot / JSONDecoder.snapshot live in Shared/SnapshotCoders.swift
