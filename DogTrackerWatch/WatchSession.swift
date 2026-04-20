import Foundation
import Observation
import WatchConnectivity
import OSLog
#if canImport(WidgetKit)
import WidgetKit
#endif

/// watchOS side of the WatchConnectivity bridge.
///
/// Holds the latest `FleetSnapshot` received from the phone and exposes
/// `sendPing(to:)` for the watch UI. All state is `@Observable` so SwiftUI
/// views re-render automatically.
@MainActor
@Observable
final class WatchSession: NSObject {

    /// Latest snapshot received from the phone. Persists across watch app
    /// launches via `WCSession.receivedApplicationContext`.
    private(set) var snapshot: FleetSnapshot = .empty
    /// True once `WCSession.activate()` has reported success.
    private(set) var isActivated = false
    /// True when the phone is reachable (foreground / active).
    private(set) var isReachable = false
    /// Most recent ping outcome — drives the compass page UI.
    private(set) var pingState: PingState = .idle

    enum PingState: Equatable {
        case idle
        case sending(nodeNum: UInt32)
        case waitingForFix(nodeNum: UInt32, since: Date)
        case success(nodeNum: UInt32)
        case error(String)
    }

    private let log = Logger(subsystem: "com.levijohnson.DogTracker.watchkitapp",
                             category: "WatchSession")

    /// Active local timer for the "waiting for fix" countdown — gets
    /// cancelled when a fresh fix arrives.
    private var pingTimeoutTask: Task<Void, Never>?

    func start() {
        guard WCSession.isSupported() else {
            log.error("WCSession not supported (unexpected on watchOS)")
            return
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()

        // Apply any cached context that may have been delivered before we
        // attached the delegate.
        applyContext(session.receivedApplicationContext)
    }

    // MARK: - Ping

    /// Send a ping request to the phone. Watches for a fresh fix in the
    /// next 60 seconds and updates `pingState` accordingly.
    func sendPing(to nodeNum: UInt32) {
        let session = WCSession.default
        guard session.activationState == .activated else {
            pingState = .error("Watch not paired yet")
            return
        }

        pingState = .sending(nodeNum: nodeNum)
        let message: [String: Any] = [
            WatchWireKey.op: WatchWireOp.ping,
            WatchWireKey.nodeNum: nodeNum,
        ]
        // Try sendMessage first — it's interactive and wakes the iOS app in
        // the background. If unreachable it errors immediately; fall through
        // to transferUserInfo so the request queues until the phone comes
        // back online.
        session.sendMessage(message, replyHandler: { [weak self] reply in
            Task { @MainActor in
                guard let self else { return }
                let queued = (reply[WatchWireKey.queued] as? Bool) ?? false
                if queued {
                    self.startWaitingForFix(nodeNum: nodeNum)
                } else {
                    let err = (reply[WatchWireKey.error] as? String) ?? "ping rejected"
                    self.pingState = .error(err)
                }
            }
        }, errorHandler: { [weak self] _ in
            // sendMessage failed (usually phone unreachable). Queue via
            // transferUserInfo as a fallback so the ping still fires next
            // time the phone wakes.
            Task { @MainActor in
                guard let self else { return }
                _ = session.transferUserInfo(message)
                self.pingState = .error("Phone asleep — queued, will retry")
            }
        })
    }

    private func startWaitingForFix(nodeNum: UInt32) {
        let started = Date()
        let baseline = snapshot.trackers.first(where: { $0.nodeNum == nodeNum })?.lastFix?.fixTime
        pingState = .waitingForFix(nodeNum: nodeNum, since: started)

        pingTimeoutTask?.cancel()
        pingTimeoutTask = Task { [weak self] in
            // Poll the snapshot for a fresher fix than the baseline.
            for _ in 0..<60 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                guard let self else { return }
                let current = self.snapshot.trackers.first { $0.nodeNum == nodeNum }?.lastFix?.fixTime
                let isFresher: Bool = {
                    if let current, let baseline { return current > baseline }
                    return current != nil && baseline == nil
                }()
                if isFresher {
                    self.pingState = .success(nodeNum: nodeNum)
                    // Auto-revert after 3 seconds so the button is usable again.
                    try? await Task.sleep(for: .seconds(3))
                    if case .success = self.pingState { self.pingState = .idle }
                    return
                }
            }
            await MainActor.run {
                self?.pingState = .error("No response (60s)")
            }
        }
    }

    // MARK: - Snapshot handling

    private func applyContext(_ context: [String: Any]) {
        guard let data = context[WatchWireKey.snapshot] as? Data else { return }
        do {
            let decoded = try JSONDecoder.snapshot.decode(FleetSnapshot.self, from: data)
            snapshot = decoded
            log.info("snapshot applied — \(decoded.trackers.count) trackers, link=\(decoded.linkState.rawValue)")

            // Mirror to the shared App Group so the watch complication
            // extension can render off the same state, then kick
            // WidgetKit to refresh right away.
            SharedSnapshotStore.write(decoded)
            #if canImport(WidgetKit)
            WidgetCenter.shared.reloadAllTimelines()
            #endif
        } catch {
            log.error("snapshot decode failed: \(error.localizedDescription)")
        }
    }
}

extension WatchSession: WCSessionDelegate {

    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in
            self.isActivated = (activationState == .activated)
            if let error {
                self.log.error("activation error: \(error.localizedDescription)")
            } else {
                self.log.info("activated")
                self.applyContext(session.receivedApplicationContext)
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.isReachable = session.isReachable
        }
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in
            self.applyContext(applicationContext)
        }
    }
}

// JSONDecoder.snapshot lives in Shared/SnapshotCoders.swift
