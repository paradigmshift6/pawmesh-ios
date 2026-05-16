import SwiftUI
import SwiftData
import UserNotifications

struct FencesListScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(MeshService.self) private var mesh
    @Environment(UnitSettings.self) private var units
    @Query(sort: \Geofence.createdAt) private var fences: [Geofence]
    @Query(sort: \Tracker.assignedAt) private var trackers: [Tracker]
    @State private var editingFence: Geofence?
    @State private var creating = false
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        List {
            if notificationStatus == .denied && fences.contains(where: \.isEnabled) {
                Section {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "bell.slash")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Notifications are off")
                                .font(.subheadline.bold())
                            Text("Open Settings to allow alerts when a dog leaves a fence.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                }
            }

            if fences.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No fences",
                        systemImage: "mappin.and.ellipse",
                        description: Text("Tap + to draw a circle around an area. You'll get a push notification when a dog leaves it.")
                    )
                    .listRowBackground(Color.clear)
                }
            } else {
                ForEach(fences) { fence in
                    fenceRow(fence)
                }
                .onDelete(perform: deleteFences)
            }
        }
        .navigationTitle("Fences")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    creating = true
                } label: {
                    Label("Add fence", systemImage: "plus")
                }
            }
        }
        .sheet(item: $editingFence) { fence in
            FenceEditorScreen(mode: .edit(fence))
        }
        .sheet(isPresented: $creating) {
            FenceEditorScreen(mode: .create)
        }
        .task {
            notificationStatus = await NotificationAuthorization.shared.authorizationStatus()
        }
    }

    private func fenceRow(_ fence: Geofence) -> some View {
        Button {
            editingFence = fence
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(Color(hex: fence.colorHex) ?? .red)
                    .frame(width: 14, height: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(fence.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(subtitle(for: fence))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { fence.isEnabled },
                    set: { newValue in
                        fence.isEnabled = newValue
                        try? modelContext.save()
                        if newValue {
                            Task { await ensureNotificationsAllowed() }
                        }
                    }
                ))
                .labelsHidden()
            }
        }
        .buttonStyle(.plain)
    }

    private func subtitle(for fence: Geofence) -> String {
        let radius = units.useMetric
            ? "\(Int(fence.radiusMeters))m"
            : "\(Int(fence.radiusMeters * 3.28084))ft"
        let scope: String
        if fence.appliesToNodeNums.isEmpty {
            scope = "all dogs"
        } else {
            let names = trackers
                .filter { fence.appliesToNodeNums.contains($0.nodeNum) }
                .map(\.name)
            scope = names.isEmpty ? "no dogs" : names.joined(separator: ", ")
        }
        return "\(radius) · \(scope)"
    }

    private func deleteFences(at offsets: IndexSet) {
        for index in offsets {
            let fence = fences[index]
            mesh.geofence.resetState(for: fence.id)
            modelContext.delete(fence)
        }
        try? modelContext.save()
    }

    private func ensureNotificationsAllowed() async {
        let status = await NotificationAuthorization.shared.authorizationStatus()
        switch status {
        case .notDetermined:
            await NotificationAuthorization.shared.requestAuthorization()
        default:
            break
        }
        notificationStatus = await NotificationAuthorization.shared.authorizationStatus()
    }
}
