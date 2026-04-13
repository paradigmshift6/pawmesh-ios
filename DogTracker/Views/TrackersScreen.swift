import SwiftUI
import SwiftData
import PhotosUI

struct TrackersScreen: View {
    @Environment(MeshService.self) private var mesh
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Tracker.assignedAt) private var trackers: [Tracker]
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Dogs")
                .searchable(text: $searchText, prompt: "Search nodes")
        }
    }

    @ViewBuilder private var content: some View {
        List {
            assignedSection
            availableSection
        }
    }

    // MARK: - Assigned dogs

    @ViewBuilder private var assignedSection: some View {
        if !trackers.isEmpty {
            Section("Tracked Dogs (\(trackers.count)/3)") {
                ForEach(trackers) { tracker in
                    NavigationLink {
                        TrackerDetailScreen(tracker: tracker)
                    } label: {
                        AssignedRow(tracker: tracker, mesh: mesh)
                    }
                }
                .onDelete(perform: deleteTrackers)
            }
        }
    }

    // MARK: - Available mesh nodes

    @ViewBuilder private var availableSection: some View {
        let unassigned = unassignedNodes
        Section(trackers.isEmpty ? "Assign a Dog" : "Other Mesh Nodes") {
            if unassigned.isEmpty && trackers.isEmpty {
                ContentUnavailableView(
                    "No nodes seen",
                    systemImage: "antenna.radiowaves.left.and.right",
                    description: Text("Connect to your Meshtastic radio first, then mesh nodes will appear here.")
                )
            } else {
                ForEach(unassigned, id: \.num) { node in
                    MeshNodeRow(node: node, canAssign: trackers.count < 3) {
                        assignNode(node)
                    }
                }
            }
        }
    }

    private var unassignedNodes: [MeshNode] {
        let assignedNums = Set(trackers.map(\.nodeNum))
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return mesh.nodes.values
            .filter { node in
                guard !assignedNums.contains(node.num), node.num != mesh.myNodeNum else {
                    return false
                }
                guard !query.isEmpty else { return true }
                return node.longName.lowercased().contains(query)
                    || node.shortName.lowercased().contains(query)
                    || node.hexID.lowercased().contains(query)
            }
            .sorted { ($0.lastHeard ?? .distantPast) > ($1.lastHeard ?? .distantPast) }
    }

    // MARK: - Actions

    private func assignNode(_ node: MeshNode) {
        guard trackers.count < 3 else { return }
        let colors = ["#E74C3C", "#2ECC71", "#3498DB"]
        let color = colors[trackers.count % colors.count]
        let name = node.longName.isEmpty ? "Dog \(trackers.count + 1)" : node.longName
        let tracker = Tracker(nodeNum: node.num, name: name, colorHex: color)
        modelContext.insert(tracker)
        try? modelContext.save()
    }

    private func deleteTrackers(at offsets: IndexSet) {
        for i in offsets {
            modelContext.delete(trackers[i])
        }
        try? modelContext.save()
    }
}

// MARK: - Subviews

private struct AssignedRow: View {
    let tracker: Tracker
    let mesh: MeshService

    var body: some View {
        HStack(spacing: 12) {
            trackerPhoto
            VStack(alignment: .leading) {
                Text(tracker.name).font(.headline)
                Text(lastFixText).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var trackerPhoto: some View {
        if let data = tracker.photoData, let img = UIImage(data: data) {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
                .frame(width: 40, height: 40)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color(hex: tracker.colorHex) ?? .gray, lineWidth: 3))
        } else {
            Circle()
                .fill(Color(hex: tracker.colorHex) ?? .gray)
                .frame(width: 40, height: 40)
                .overlay(
                    Text(String(tracker.name.prefix(1)))
                        .font(.headline).foregroundStyle(.white)
                )
        }
    }

    private var lastFixText: String {
        guard let node = mesh.nodes[tracker.nodeNum], let t = node.positionTime else {
            return "No position yet"
        }
        return "Fix \(t.formatted(.relative(presentation: .named)))"
    }
}

private struct MeshNodeRow: View {
    let node: MeshNode
    let canAssign: Bool
    let onAssign: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(node.longName.isEmpty ? node.hexID : node.longName)
                    .font(.body)
                HStack(spacing: 8) {
                    Text(node.hexID)
                    if let lh = node.lastHeard {
                        Text(lh.formatted(.relative(presentation: .named)))
                    }
                    if let snr = node.snr {
                        Text("\(snr, specifier: "%.1f") dB")
                    }
                }
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            }
            Spacer()
            if canAssign {
                Button("Track") { onAssign() }
                    .buttonStyle(.bordered)
                    .tint(.accentColor)
            }
        }
    }
}

// MARK: - Tracker Detail

struct TrackerDetailScreen: View {
    @Bindable var tracker: Tracker
    @State private var photoItem: PhotosPickerItem?
    @State private var rawPhotoImage: UIImage?
    @State private var showCropSheet = false

    var body: some View {
        Form {
            Section("Identity") {
                TextField("Name", text: $tracker.name)
                ColorHexPicker(hex: $tracker.colorHex)
            }
            Section("Photo") {
                photoSection
            }
            Section("Info") {
                LabeledContent("Node", value: String(format: "!%08x", tracker.nodeNum))
                LabeledContent("Assigned", value: tracker.assignedAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Fixes recorded", value: "\(tracker.fixes.count)")
            }
        }
        .navigationTitle(tracker.name)
        .sheet(isPresented: $showCropSheet) {
            if let img = rawPhotoImage {
                PhotoCropView(image: img) { cropped in
                    tracker.photoData = cropped.jpegData(compressionQuality: 0.8)
                    showCropSheet = false
                }
            }
        }
    }

    @ViewBuilder private var photoSection: some View {
        if let data = tracker.photoData, let img = UIImage(data: data) {
            Image(uiImage: img)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 200)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        PhotosPicker("Choose photo", selection: $photoItem, matching: .images)
            .onChange(of: photoItem) { _, item in
                Task {
                    if let data = try? await item?.loadTransferable(type: Data.self),
                       let img = UIImage(data: data) {
                        rawPhotoImage = img
                        showCropSheet = true
                    }
                }
            }
        if tracker.photoData != nil {
            Button("Remove photo", role: .destructive) {
                tracker.photoData = nil
            }
        }
    }
}

// MARK: - Photo crop view (move & scale)

/// A simple move-and-scale photo cropper. The user drags and pinches the image
/// inside a circular crop area, then taps Use Photo.
private struct PhotoCropView: View {
    let image: UIImage
    let onCrop: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private let outputSize: CGFloat = 256
    private let cropDiameter: CGFloat = 280

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer()
                ZStack {
                    // Image behind the crop circle
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: cropDiameter, height: cropDiameter)
                        .scaleEffect(scale)
                        .offset(offset)
                        .clipShape(Circle())
                        .gesture(dragGesture)
                        .gesture(pinchGesture)

                    // Circle border
                    Circle()
                        .stroke(Color.white, lineWidth: 3)
                        .frame(width: cropDiameter, height: cropDiameter)
                        .allowsHitTesting(false)
                }
                Text("Move and Scale")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 16)
                Spacer()
            }
            .background(Color.black)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.white)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use Photo") { cropAndFinish() }
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
            }
            .onEnded { _ in lastOffset = offset }
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = max(0.5, lastScale * value.magnification)
            }
            .onEnded { _ in
                scale = max(0.5, scale)
                lastScale = scale
            }
    }

    private func cropAndFinish() {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: outputSize, height: outputSize))
        let cropped = renderer.image { ctx in
            let drawSize = cropDiameter * scale
            let imgAspect = image.size.width / image.size.height
            let drawW: CGFloat
            let drawH: CGFloat
            if imgAspect > 1 {
                drawH = drawSize
                drawW = drawSize * imgAspect
            } else {
                drawW = drawSize
                drawH = drawSize / imgAspect
            }

            // Map the offset from view coordinates to the render output
            let scaleFactor = outputSize / cropDiameter
            let x = (outputSize - drawW * scaleFactor) / 2 + offset.width * scaleFactor
            let y = (outputSize - drawH * scaleFactor) / 2 + offset.height * scaleFactor

            // Clip to circle
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: outputSize, height: outputSize)).addClip()
            image.draw(in: CGRect(x: x, y: y, width: drawW * scaleFactor, height: drawH * scaleFactor))
        }
        onCrop(cropped)
    }
}

// MARK: - Color hex picker

private struct ColorHexPicker: View {
    @Binding var hex: String
    private let presets = ["#E74C3C", "#2ECC71", "#3498DB", "#F39C12", "#9B59B6", "#1ABC9C"]

    var body: some View {
        HStack {
            Text("Color")
            Spacer()
            ForEach(presets, id: \.self) { color in
                Circle()
                    .fill(Color(hex: color) ?? .gray)
                    .frame(width: 28, height: 28)
                    .overlay(Circle().stroke(.primary.opacity(hex == color ? 1 : 0), lineWidth: 2))
                    .onTapGesture { hex = color }
            }
        }
    }
}

#Preview {
    TrackersScreen()
        .modelContainer(for: [Tracker.self, Fix.self, TileRegion.self], inMemory: true)
}
