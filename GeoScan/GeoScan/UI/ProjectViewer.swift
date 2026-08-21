//
//  ProjectViewer.swift
//
//  The reviewer: the finished cloud, off the AR session, with the measure tools,
//  the stills and the export in one place.
//

import SwiftUI
import UIKit
import simd

struct ProjectViewer: View {

    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss

    @State private var project: Project
    @StateObject private var host: RenderHost
    @StateObject private var measurements = MeasurementEngine()

    @State private var mode: Mode = .look
    @State private var cloud: PointCloud?
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var selectedPhotoID: UUID?
    @State private var showsPhotos = false
    @State private var showsMeasurements = false
    @State private var showsInfo = false
    @State private var showsExport = false
    @State private var isDirty = false

    private let snapshotCache = CloudSnapshotCache()
    @State private var picker: HybridScenePicker?

    enum Mode: String, CaseIterable, Identifiable {
        case look = "Look"
        case measure = "Measure"
        var id: String { rawValue }
    }

    init(project: Project) {
        _project = State(initialValue: project)
        // Review mode never grows the buffer, so size it to the saved cloud.
        let capacity = max(project.statistics.pointCount + 1024, 1 << 16)
        _host = StateObject(wrappedValue: RenderHost(capacity: capacity, mode: .review)!)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            MetalViewRepresentable(host: host, interactive: true) { point, size in
                handleTap(at: point, viewSize: size)
            }
            .ignoresSafeArea()

            SceneOverlayView(host: host,
                             measurements: measurements.displayed,
                             selectedMeasurementID: measurements.selectedID,
                             photos: project.photos,
                             showsPhotoPins: true,
                             onPhotoTap: { selectedPhotoID = $0.id },
                             onMeasurementTap: { measurements.selectedID = $0.id })

            if isLoading { loadingOverlay }
            if let loadError { errorOverlay(loadError) }

            VStack {
                topBar
                Spacer()
                bottomBar
            }
            .padding(.horizontal, 14)
        }
        .navigationBarHidden(true)
        .onAppear(perform: load)
        .onDisappear(perform: persistIfNeeded)
        .sheet(isPresented: $showsPhotos) { photoListSheet }
        .sheet(isPresented: $showsMeasurements) { measurementListSheet }
        .sheet(isPresented: $showsInfo) { ProjectInfoView(project: project, store: store) }
        .sheet(isPresented: $showsExport) { ExportView(project: project) }
        .sheet(item: photoBinding) { photo in
            PhotoDetailView(photo: photo,
                            imageURL: store.photoURL(photo, in: project),
                            cloud: cloud,
                            onUpdate: { updated in apply(updated) },
                            onLocate: { world in
                                host.renderer.orbitCamera.target = world
                                host.renderer.orbitCamera.distance = 2.0
                            },
                            onMatchViewpoint: {
                                host.renderer.orbitCamera.match(photo: photo)
                            })
        }
    }

    // MARK: - Loading

    private func load() {
        host.renderer.mode = .review
        measurements.measurements = project.measurements

        guard store.hasCloud(for: project) else {
            isLoading = false
            loadError = "This scan has no point cloud on disk."
            return
        }

        let project = self.project
        let store = self.store
        Task {
            do {
                let points = try await Task.detached(priority: .userInitiated) {
                    try store.loadCloud(for: project)
                }.value
                let loaded = PointCloud(points: points)
                self.cloud = loaded
                self.snapshotCache.set(loaded)
                self.host.renderer.present(cloud: loaded)
                self.picker = HybridScenePicker(
                    viewProjectionProvider: { self.host.renderer.viewProjection },
                    cloudProvider: { self.snapshotCache.current },
                    meshProvider: { [] })
                self.isLoading = false
            } catch {
                self.isLoading = false
                self.loadError = error.localizedDescription
            }
        }
    }

    private func persistIfNeeded() {
        guard isDirty else { return }
        var updated = project
        updated.measurements = measurements.measurements
        try? store.update(updated)
        isDirty = false
    }

    // MARK: - Interaction

    private func handleTap(at point: CGPoint, viewSize: CGSize) {
        guard mode == .measure, let picker else { return }
        measurements.beginOrExtend(at: point, viewSize: viewSize, picker: picker)
        isDirty = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // MARK: - Photo sheet plumbing

    /// `sheet(item:)` needs an Identifiable value; the id is what we track.
    private var photoBinding: Binding<PhotoNote?> {
        Binding(get: { project.photos.first { $0.id == selectedPhotoID } },
                set: { selectedPhotoID = $0?.id })
    }

    /// Notes and markers live in the manifest, so a change is written straight
    /// away rather than being held until the screen closes.
    private func apply(_ updated: PhotoNote) {
        guard let index = project.photos.firstIndex(where: { $0.id == updated.id }) else { return }
        project.photos[index] = updated
        try? store.update(project)
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack(spacing: 8) {
            Button {
                persistIfNeeded()
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 32, height: 32)
                    .background(Theme.panel, in: Circle())
            }
            .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(project.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .foregroundStyle(.white)

            Spacer()

            Menu {
                Picker("Colouring", selection: Binding(get: { host.renderer.colorMode },
                                                       set: { host.renderer.colorMode = $0 })) {
                    ForEach(PointColorMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.symbolName).tag(mode)
                    }
                }
                Picker("Confidence", selection: Binding(get: { Int(host.renderer.minConfidence) },
                                                        set: { host.renderer.minConfidence = UInt8($0) })) {
                    Text("Show everything").tag(0)
                    Text("Medium and high").tag(1)
                    Text("High only").tag(2)
                }
                Button {
                    if let cloud { host.renderer.orbitCamera.frame(bounds: cloud.bounds) }
                } label: {
                    Label("Reframe", systemImage: "scope")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 32, height: 32)
                    .background(Theme.panel, in: Circle())
            }
            .foregroundStyle(.white)
        }
        .padding(.top, 6)
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if mode == .measure {
                HUDPanel(padding: 10) {
                    VStack(spacing: 8) {
                        Picker("Kind", selection: Binding(get: { measurements.kind },
                                                          set: { measurements.setKind($0) })) {
                            ForEach(MeasurementKind.allCases) { kind in
                                Label(kind.title, systemImage: kind.symbolName).tag(kind)
                            }
                        }
                        .pickerStyle(.segmented)

                        Text(measurements.lastError ?? measurements.prompt)
                            .font(.caption)
                            .foregroundStyle(measurements.lastError == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.bad))

                        if measurements.isDrafting {
                            HStack(spacing: 12) {
                                Button("Undo point") { measurements.undoLastVertex() }
                                    .buttonStyle(.bordered)
                                Button("Cancel", role: .destructive) { measurements.cancelDraft() }
                                    .buttonStyle(.bordered)
                                if measurements.kind.acceptsMoreVertices && measurements.draftIsComplete {
                                    Button("Done") { measurements.commitDraft() }
                                        .buttonStyle(.borderedProminent)
                                }
                            }
                            .font(.caption)
                        }
                    }
                }
            }

            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 240)

            HStack(spacing: 22) {
                toolButton("photo.stack", "\(project.photos.count)") { showsPhotos = true }
                toolButton("ruler", "\(measurements.measurements.count)") { showsMeasurements = true }
                toolButton("info.circle", "Info") { showsInfo = true }
                toolButton("square.and.arrow.up", "Export") { showsExport = true }
            }
        }
        .padding(.bottom, 14)
    }

    private func toolButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.title3)
                Text(label).font(.caption2)
            }
            .foregroundStyle(.white)
            .frame(width: 62, height: 48)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var loadingOverlay: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Loading \(Format.pointCount(project.statistics.pointCount)) points…")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func errorOverlay(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").font(.title2)
            Text(message).font(.callout).multilineTextAlignment(.center)
        }
        .foregroundStyle(.white)
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(40)
    }

    // MARK: - Sheets

    private var photoListSheet: some View {
        NavigationStack {
            List {
                if project.photos.isEmpty {
                    ContentUnavailableView("No stills",
                                           systemImage: "camera",
                                           description: Text("Take stills while scanning to tag what you see."))
                }
                ForEach(project.photos) { photo in
                    Button {
                        showsPhotos = false
                        selectedPhotoID = photo.id
                    } label: {
                        HStack(spacing: 12) {
                            AsyncLocalImage(url: store.photoURL(photo, in: project), contentMode: .fill)
                                .frame(width: 64, height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(photo.displayTitle).lineLimit(2)
                                HStack(spacing: 6) {
                                    if !photo.tags.isEmpty {
                                        Text(photo.tags.joined(separator: ", "))
                                    }
                                    if !photo.annotations.isEmpty {
                                        Label("\(photo.annotations.count)", systemImage: "mappin")
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }
            .navigationTitle("Stills")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showsPhotos = false }
                }
            }
        }
    }

    private var measurementListSheet: some View {
        NavigationStack {
            List {
                if measurements.measurements.isEmpty {
                    ContentUnavailableView("No measurements",
                                           systemImage: "ruler",
                                           description: Text("Switch to Measure and tap two points on the cloud."))
                }
                ForEach(measurements.measurements) { measurement in
                    MeasurementRow(measurement: measurement,
                                   solution: project.geoSolution,
                                   photoCount: PhotoCorrelator.photos(observing: measurement,
                                                                      in: project.photos,
                                                                      cloud: cloud).count)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        measurements.selectedID = measurement.id
                        if let first = measurement.vertices.first {
                            host.renderer.orbitCamera.target = first.world
                        }
                        showsMeasurements = false
                    }
                }
                .onDelete { offsets in
                    for index in offsets {
                        measurements.delete(measurements.measurements[index].id)
                    }
                    isDirty = true
                }
            }
            .navigationTitle("Measurements")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        showsMeasurements = false
                        persistIfNeeded()
                    }
                }
            }
        }
    }
}

struct MeasurementRow: View {
    let measurement: SiteMeasurement
    let solution: GeoSolution
    var photoCount: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(measurement.displayName, systemImage: measurement.kind.symbolName)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(measurement.primaryText)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
            }
            HStack(spacing: 10) {
                if let uncertainty = measurement.uncertaintyText {
                    Text(uncertainty)
                }
                let result = measurement.result
                if result.horizontal.isFinite && measurement.kind != .area {
                    Text("run \(SiteMeasurement.formatLength(result.horizontal))")
                }
                if result.vertical.isFinite && measurement.kind != .area {
                    Text("rise \(SiteMeasurement.formatLength(result.vertical))")
                }
                if measurement.kind == .area, result.planarityRMS.isFinite, result.planarityRMS > 0.02 {
                    Text(String(format: "not flat: ±%.0f mm", result.planarityRMS * 1000))
                        .foregroundStyle(Theme.warn)
                }
                if photoCount > 0 {
                    Label("\(photoCount)", systemImage: "camera")
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
