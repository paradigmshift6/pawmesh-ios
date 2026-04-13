import SwiftUI

struct RadioScreen: View {
    @Environment(RadioController.self) private var radio

    var body: some View {
        List {
            statusSection
            actionsSection
            discoveredSection
        }
        .navigationTitle("Radio")
        .onAppear {
            // Only auto-scan if truly idle (not reconnecting)
            if case .disconnected = radio.connectionState,
               UserDefaults.standard.string(forKey: "lastConnectedPeripheralUUID") == nil {
                radio.startScan()
            }
        }
        .onDisappear {
            if case .scanning = radio.connectionState {
                radio.stopScan()
            }
        }
    }

    private var statusSection: some View {
        Section("Status") {
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(statusText)
            }
        }
    }

    @ViewBuilder private var actionsSection: some View {
        Section {
            switch radio.connectionState {
            case .connected, .configuring:
                Button("Disconnect", role: .destructive) { radio.disconnect() }
            case .scanning:
                Button("Stop scanning") { radio.stopScan() }
            case .bluetoothUnavailable, .failed:
                Button("Retry") { radio.startScan() }
            default:
                Button("Scan for radios") { radio.startScan() }
            }
        }
    }

    @ViewBuilder private var discoveredSection: some View {
        if !radio.discovered.isEmpty {
            Section("Discovered") {
                ForEach(radio.discovered.sorted(by: { $0.rssi > $1.rssi })) { p in
                    PeripheralRow(peripheral: p)
                }
            }
        }
    }

    private var statusText: String {
        switch radio.connectionState {
        case .disconnected: "Disconnected"
        case .bluetoothUnavailable(let r): r
        case .scanning: "Scanning…"
        case .connecting(let n): "Connecting to \(n)…"
        case .configuring(let n): "Configuring \(n)…"
        case .connected(let n): "Connected to \(n)"
        case .failed(let r): "Failed: \(r)"
        }
    }

    private var statusColor: Color {
        switch radio.connectionState {
        case .connected: .green
        case .configuring, .connecting, .scanning: .yellow
        case .failed, .bluetoothUnavailable: .red
        case .disconnected: .gray
        }
    }
}

private struct PeripheralRow: View {
    @Environment(RadioController.self) private var radio
    let peripheral: DiscoveredPeripheral

    var body: some View {
        Button {
            radio.connect(peripheral.id)
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(peripheral.name).font(.body).foregroundStyle(.primary)
                    Text("\(peripheral.rssi) dBm")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isThisConnecting {
                    ProgressView()
                }
            }
        }
        .disabled(!isConnectable)
    }

    private var isThisConnecting: Bool {
        switch radio.connectionState {
        case .connecting(let n), .configuring(let n):
            return n == peripheral.name
        default:
            return false
        }
    }

    private var isConnectable: Bool {
        switch radio.connectionState {
        case .connected, .configuring, .connecting: false
        default: true
        }
    }
}
