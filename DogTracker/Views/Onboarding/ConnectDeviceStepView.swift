import SwiftUI

/// BLE scan and connect view, used for both companion and tracker connections.
struct ConnectDeviceStepView: View {
    let manager: OnboardingManager
    let radio: RadioController
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 0) {
            header
            deviceList
        }
        .onAppear {
            if case .disconnected = radio.connectionState {
                radio.startScan()
            }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text(title)
                .font(.title2.bold())
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 32)
        .padding(.horizontal, 24)
    }

    private var deviceList: some View {
        List {
            connectionStatus

            if !radio.discovered.isEmpty {
                Section("Available Devices") {
                    ForEach(radio.discovered.sorted(by: { $0.rssi > $1.rssi })) { p in
                        Button {
                            manager.connectToDevice(p.id)
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(p.name)
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                    Text("\(p.rssi) dBm")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if isConnecting(to: p) {
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(isConnectingAny)
                    }
                }
            }

            if radio.discovered.isEmpty {
                Section {
                    HStack {
                        ProgressView()
                        Text("Scanning for devices...")
                            .foregroundStyle(.secondary)
                            .padding(.leading, 8)
                    }
                }
            }
        }
    }

    @ViewBuilder private var connectionStatus: some View {
        switch radio.connectionState {
        case .connecting(let name):
            Section {
                HStack {
                    ProgressView()
                    Text("Connecting to \(name)...")
                        .padding(.leading, 8)
                }
            }
        case .configuring(let name):
            Section {
                HStack {
                    ProgressView()
                    Text("Configuring \(name)...")
                        .padding(.leading, 8)
                }
            }
        default:
            EmptyView()
        }
    }

    private func isConnecting(to p: DiscoveredPeripheral) -> Bool {
        switch radio.connectionState {
        case .connecting(let n), .configuring(let n):
            return n == p.name
        default:
            return false
        }
    }

    private var isConnectingAny: Bool {
        switch radio.connectionState {
        case .connecting, .configuring, .connected:
            return true
        default:
            return false
        }
    }
}
