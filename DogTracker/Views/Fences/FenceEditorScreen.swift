import SwiftUI
import SwiftData
import CoreLocation

struct FenceEditorScreen: View {
    enum Mode {
        case create
        case edit(Geofence)
    }

    let mode: Mode

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(MeshService.self) private var mesh
    @Environment(LocationProvider.self) private var location
    @Environment(UnitSettings.self) private var units
    @Query(sort: \Tracker.assignedAt) private var trackers: [Tracker]
    @AppStorage("mapSourceMode") private var mapSourceMode = MapSource.autoModeID

    @State private var name: String = ""
    @State private var centerLatitude: Double = 0
    @State private var centerLongitude: Double = 0
    @State private var radiusMeters: Double = 200
    @State private var colorHex: String = "#FF3B30"
    @State private var appliesToNodeNums: Set<UInt32> = []
    @State private var hasInitialCenter = false
    @State private var showDeleteConfirm = false

    private var existingFence: Geofence? {
        if case .edit(let fence) = mode { return fence }
        return nil
    }

    private var isCenterSet: Bool { hasInitialCenter }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                mapSection
                controlsSection
            }
            .navigationTitle(existingFence == nil ? "New Fence" : "Edit Fence")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
                if existingFence != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }
            .confirmationDialog(
                "Delete this fence?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { delete() }
                Button("Cancel", role: .cancel) { }
            }
            .onAppear(perform: loadInitialState)
        }
    }

    // MARK: - Map

    private var mapSection: some View {
        ZStack(alignment: .top) {
            DogMapView(
                markers: [],
                fences: previewFences,
                centerOn: hasInitialCenter ? CLLocationCoordinate2D(latitude: centerLatitude, longitude: centerLongitude) : nil,
                onlineSource: MapSource.resolve(mode: mapSourceMode, coordinate: location.userLocation?.coordinate),
                onMapTap: { coord in
                    centerLatitude = coord.latitude
                    centerLongitude = coord.longitude
                    hasInitialCenter = true
                }
            )
            .frame(maxHeight: .infinity)
            .overlay(alignment: .bottomLeading) {
                MapAttributionLabel(
                    source: MapSource.resolve(mode: mapSourceMode, coordinate: location.userLocation?.coordinate)
                )
                .padding(.leading, 8)
                .padding(.bottom, 8)
            }

            if !hasInitialCenter {
                Text("Tap the map to place the fence center")
                    .font(.caption.bold())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 8)
            }
        }
    }

    private var previewFences: [FenceOverlay] {
        guard hasInitialCenter else { return [] }
        return [FenceOverlay(
            id: existingFence?.id ?? UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            centerLatitude: centerLatitude,
            centerLongitude: centerLongitude,
            radiusMeters: radiusMeters,
            colorHex: colorHex
        )]
    }

    // MARK: - Controls

    private var controlsSection: some View {
        Form {
            Section("Name") {
                TextField("e.g. Camp", text: $name)
            }

            Section("Radius") {
                VStack(alignment: .leading) {
                    Text(radiusLabel)
                        .font(.subheadline.monospacedDigit())
                    Slider(value: $radiusMeters, in: 15...2000, step: 5)
                }
            }

            Section("Color") {
                colorPicker
            }

            if let fence = existingFence {
                Section("Recent activity") {
                    FenceEventsList(fence: fence)
                }
            }

            Section {
                ForEach(trackers) { tracker in
                    Toggle(isOn: Binding(
                        get: { appliesToNodeNums.isEmpty || appliesToNodeNums.contains(tracker.nodeNum) },
                        set: { isOn in
                            // Empty set means "all". Once the user toggles
                            // any dog off, switch to explicit set.
                            if appliesToNodeNums.isEmpty {
                                appliesToNodeNums = Set(trackers.map(\.nodeNum))
                            }
                            if isOn {
                                appliesToNodeNums.insert(tracker.nodeNum)
                            } else {
                                appliesToNodeNums.remove(tracker.nodeNum)
                            }
                            // If everyone is selected, normalize back to empty
                            // so "applies to all" shows in the list view.
                            if appliesToNodeNums.count == trackers.count {
                                appliesToNodeNums = []
                            }
                        }
                    )) {
                        HStack {
                            Circle()
                                .fill(Color(hex: tracker.colorHex) ?? .gray)
                                .frame(width: 12, height: 12)
                            Text(tracker.name)
                        }
                    }
                }
            } header: {
                Text("Applies to")
            } footer: {
                Text(appliesToNodeNums.isEmpty
                     ? "All dogs are monitored against this fence."
                     : "Only the selected dogs are monitored.")
            }
        }
        .frame(maxHeight: 380)
    }

    private var colorPicker: some View {
        let palette = ["#FF3B30", "#FF9500", "#FFCC00", "#34C759", "#5AC8FA", "#007AFF", "#AF52DE"]
        return HStack(spacing: 12) {
            ForEach(palette, id: \.self) { hex in
                Button {
                    colorHex = hex
                } label: {
                    Circle()
                        .fill(Color(hex: hex) ?? .gray)
                        .frame(width: 26, height: 26)
                        .overlay(
                            Circle()
                                .stroke(Color.primary, lineWidth: colorHex == hex ? 2 : 0)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && hasInitialCenter
    }

    private var radiusLabel: String {
        if units.useMetric {
            return "\(Int(radiusMeters)) m"
        }
        let feet = Int((radiusMeters * 3.28084).rounded())
        return "\(feet) ft"
    }

    // MARK: - Actions

    private func loadInitialState() {
        if let fence = existingFence {
            name = fence.name
            centerLatitude = fence.centerLatitude
            centerLongitude = fence.centerLongitude
            radiusMeters = fence.radiusMeters
            colorHex = fence.colorHex
            appliesToNodeNums = Set(fence.appliesToNodeNums)
            hasInitialCenter = true
        } else if let userLoc = location.userLocation {
            centerLatitude = userLoc.coordinate.latitude
            centerLongitude = userLoc.coordinate.longitude
            hasInitialCenter = true
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let normalizedAppliesTo = appliesToNodeNums.count == trackers.count ? [] : Array(appliesToNodeNums)

        if let fence = existingFence {
            fence.name = trimmedName
            // Reset state if center or radius moved — otherwise we could
            // immediately fire an "exit" against an old in-memory state.
            let centerMoved = fence.centerLatitude != centerLatitude
                || fence.centerLongitude != centerLongitude
                || fence.radiusMeters != radiusMeters
            fence.centerLatitude = centerLatitude
            fence.centerLongitude = centerLongitude
            fence.radiusMeters = radiusMeters
            fence.colorHex = colorHex
            fence.appliesToNodeNums = normalizedAppliesTo
            if centerMoved {
                mesh.geofence.resetState(for: fence.id)
            }
        } else {
            let fence = Geofence(
                name: trimmedName,
                centerLatitude: centerLatitude,
                centerLongitude: centerLongitude,
                radiusMeters: radiusMeters,
                colorHex: colorHex,
                appliesToNodeNums: normalizedAppliesTo
            )
            modelContext.insert(fence)
        }
        try? modelContext.save()

        // Ask for permission the first time the user creates a fence so the
        // request lands in a moment of obvious user intent. Await it before
        // dismissing — otherwise the system prompt appears over the list
        // view, which App Store review flags under guideline 4.5.4.
        Task {
            let status = await NotificationAuthorization.shared.authorizationStatus()
            if status == .notDetermined {
                await NotificationAuthorization.shared.requestAuthorization()
            }
            dismiss()
        }
    }

    private func delete() {
        guard let fence = existingFence else { return }
        mesh.geofence.resetState(for: fence.id)
        modelContext.delete(fence)
        try? modelContext.save()
        dismiss()
    }
}

/// Renders the most recent crossings for a single fence. Lives in its own
/// view so the `@Query` filter can use the fence's stable ID without making
/// the parent re-evaluate on every form change.
private struct FenceEventsList: View {
    let fence: Geofence
    @Query private var events: [GeofenceEvent]
    @Query(sort: \Tracker.assignedAt) private var trackers: [Tracker]

    init(fence: Geofence) {
        self.fence = fence
        let fenceID = fence.id
        _events = Query(
            filter: #Predicate<GeofenceEvent> { $0.fence?.id == fenceID },
            sort: \GeofenceEvent.fixTime,
            order: .reverse
        )
    }

    var body: some View {
        if events.isEmpty {
            Text("No crossings yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(events.prefix(8), id: \.persistentModelID) { event in
                HStack {
                    Image(systemName: event.transition == .exited
                          ? "arrow.up.right.circle.fill"
                          : "arrow.down.left.circle.fill")
                    .foregroundStyle(event.transition == .exited ? .red : .green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(name(for: event.trackerNodeNum)) \(event.transition == .exited ? "left" : "returned")")
                            .font(.subheadline)
                        Text(event.fixTime, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func name(for nodeNum: UInt32) -> String {
        trackers.first(where: { $0.nodeNum == nodeNum })?.name ?? "Unknown"
    }
}
