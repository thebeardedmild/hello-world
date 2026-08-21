//
//  ScanView.swift
//  The capture screen: live cloud, HUD, stills and in-flight measuring.
//

import SwiftUI
import ARKit
import UIKit
import simd

struct ScanView: View {

    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss

    @StateObject private var controller = ScanController()
    @StateObject private var measurements = MeasurementEngine()
    @StateObject private var host: RenderHost

    @State private var mode: Mode = .capture
    @State private var showsPhotoEditor = false
    @State private var showsSettings = false
    @State private var showsFinishSheet = false
    @State private var pendingPhoto: PhotoNote?
    @State private var flashOpacity: Double = 0
    @State private var savedProject: Project?
    @State private var isSaving = false
    @State private var saveError: String?

    private let snapshotCache = CloudSnapshotCache()
    @State private var picker: HybridScenePicker?

    enum Mode: String, CaseIterable, Identifiable {
        case capture = "Capture"
        case measure = "Measure"
        var id: String { rawValue }
    }

    init() {
        // Capacity is fixed at renderer creation, so it comes from the default
        // settings rather than whatever the operator picks later.
        _host = StateObject(wrappedValue: RenderHost(capacity: ScanSettings.default.maxPoints,
                                                     mode: .live)!)
    }

    var body: some View {
        ZStack {
            MetalViewRepresentable(host: host, interactive: false) { point, size in
                handleTap(at: point, viewSize: size)
            }
            .ignoresSafeArea()

            SceneOverlayView(host: host,
                             measurements: measurements.displayed,
                             selectedMeasurementID: measurements.selectedID,
                             photos: controller.photos,
                             showsPhotoPins: true,
                             onPhotoTap: { pendingPhoto = $0; showsPhotoEditor = true })

            if mode == .measure { reticle }

            VStack(spacing: 0) {
                topHUD
                Spacer()
                bottomControls
            }
            .padding(.horizontal, 14)

            Color.white
                .opacity(flashOpacity)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .statusBarHidden()
        .navigationBarBackButtonHidden()
        .onAppear(perform: setUp)
        .onDisappear { controller.stopSession() }
        .sheet(isPresented: $showsPhotoEditor) {
            if let photo = pendingPhoto {
                PhotoNoteEditorView(photo: photo,
                                    imageURL: controller.workingDirectory.appendingPathComponent(photo.fileName),
                                    onSave: { controller.updatePhoto($0) },
                                    onDelete: { controller.deletePhoto($0.id) })
            }
        }
        .sheet(isPresented: $showsSettings) {
            ScanSettingsView(settings: $controller.settings, colorMode: Binding(
                get: { host.renderer.colorMode },
                set: { host.renderer.colorMode = $0 }))
        }
        .sheet(isPresented: $showsFinishSheet) { finishSheet }
        .fullScreenCover(item: $savedProject) { project in
            NavigationStack {
                ProjectViewer(project: project)
            }
            // Closing the reviewer closes the whole capture flow: the session is
            // already stopped, so going "back" to a frozen scan screen would be
            // a dead end.
            .onDisappear { dismiss() }
        }
        .alert("Could not save", isPresented: Binding(get: { saveError != nil },
                                                      set: { if !$0 { saveError = nil } })) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    // MARK: - Set-up

    private func setUp() {
        host.renderer.scanController = controller
        controller.accumulator = host.renderer.accumulator

        picker = HybridScenePicker(
            viewProjectionProvider: { host.renderer.viewProjection },
            cloudProvider: {
                snapshotCache.cloud(liveCount: host.renderer.accumulator?.count ?? 0) {
                    host.renderer.accumulator?.snapshot(maxPoints: 2_000_000) ?? []
                }
            },
            meshProvider: { Array(controller.mesh.chunks.values) })

        controller.start()
    }

    // MARK: - Interaction

    private func handleTap(at point: CGPoint, viewSize: CGSize) {
        guard mode == .measure, let picker else { return }
        measurements.beginOrExtend(at: point, viewSize: viewSize, picker: picker)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func capturePhoto() {
        guard let photo = controller.capturePhoto() else { return }
        pendingPhoto = photo
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.easeOut(duration: 0.08)) { flashOpacity = 0.75 }
        withAnimation(.easeIn(duration: 0.35).delay(0.08)) { flashOpacity = 0 }
        // Straight into the note editor: a still without its note is a still
        // nobody will ever identify again.
        showsPhotoEditor = true
    }

    // MARK: - HUD

    private var topHUD: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    controller.stopSession()
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 32, height: 32)
                        .background(Theme.panel, in: Circle())
                }
                .foregroundStyle(.white)

                StatChip(symbol: "circle.hexagongrid.fill",
                         text: Format.pointCount(host.livePointCount))
                StatChip(symbol: trackingSymbol,
                         text: controller.trackingDescription,
                         tint: controller.isTrackingHealthy ? .white : Theme.warn)
                gpsChip

                Spacer()

                Button { showsSettings = true } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 32, height: 32)
                        .background(Theme.panel, in: Circle())
                }
                .foregroundStyle(.white)
            }

            if let message = statusLine {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.panel, in: Capsule())
                    .transition(.opacity)
            }

            if controller.bufferFill > 0.75 {
                bufferBar
            }
        }
        .padding(.top, 8)
        .animation(.easeInOut(duration: 0.2), value: statusLine)
    }

    private var trackingSymbol: String {
        controller.isTrackingHealthy ? "viewfinder" : "exclamationmark.triangle.fill"
    }

    private var gpsChip: some View {
        let quality = controller.location.quality
        let tint: Color
        switch quality {
        case .excellent, .good: tint = Theme.good
        case .fair: tint = Theme.warn
        case .poor, .none: tint = Theme.bad
        }
        let accuracy = controller.location.horizontalAccuracy
        let text = accuracy.map { Format.accuracy($0) } ?? "No GPS"
        return StatChip(symbol: "location.fill", text: text, tint: tint)
    }

    private var statusLine: String? {
        if mode == .measure { return measurements.lastError ?? measurements.prompt }
        if let message = controller.statusMessage { return message }
        if controller.settings.motionGateEnabled && !controller.motion.isSteady { return "Hold steadier — frames are being skipped" }
        return nil
    }

    private var bufferBar: some View {
        HUDPanel(padding: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(controller.isCompacting ? "Compacting the cloud…" : "Point buffer")
                        .font(.caption.weight(.medium))
                    Spacer()
                    Text("\(Int(controller.bufferFill * 100))%")
                        .font(.caption.monospacedDigit())
                }
                ProgressView(value: min(controller.bufferFill, 1))
                    .tint(controller.bufferFill > 0.92 ? Theme.warn : Theme.accent)
                if controller.bufferFill > 0.92 && !controller.settings.autoCompact {
                    Text("Buffer full — turn on auto-compact or finish the scan.")
                        .font(.caption2)
                        .foregroundStyle(Theme.warn)
                }
            }
        }
    }

    private var reticle: some View {
        Image(systemName: "plus")
            .font(.title3.weight(.light))
            .foregroundStyle(Theme.accent)
            .shadow(radius: 2)
            .allowsHitTesting(false)
    }

    // MARK: - Controls

    private var bottomControls: some View {
        VStack(spacing: 12) {
            if mode == .measure { measureBar }

            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)

            HStack(spacing: 26) {
                Button {
                    controller.phase == .scanning ? controller.pause() : controller.resume()
                } label: {
                    Image(systemName: controller.phase == .scanning ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.white)
                }
                .accessibilityLabel(controller.phase == .scanning ? "Pause capture" : "Resume capture")

                Button(action: capturePhoto) {
                    ZStack {
                        Circle().fill(.white).frame(width: 66, height: 66)
                        Circle().strokeBorder(.white.opacity(0.6), lineWidth: 3).frame(width: 78, height: 78)
                        Image(systemName: "camera.fill")
                            .font(.title3)
                            .foregroundStyle(.black)
                    }
                }
                .accessibilityLabel("Take a still and add a note")

                Button {
                    controller.pause()
                    showsFinishSheet = true
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(Theme.good)
                }
                .accessibilityLabel("Finish the scan")
            }

            HStack(spacing: 14) {
                Text(Format.duration(controller.elapsed))
                Text("·")
                Text("\(controller.photos.count) stills")
                Text("·")
                Text("\(controller.geoFixCount) fixes")
                if controller.meshFaceCount > 0 {
                    Text("·")
                    Text("\(Format.pointCount(controller.meshFaceCount)) faces")
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.8))
        }
        .padding(.bottom, 18)
    }

    private var measureBar: some View {
        HUDPanel(padding: 10) {
            VStack(spacing: 10) {
                Picker("Kind", selection: Binding(get: { measurements.kind },
                                                  set: { measurements.setKind($0) })) {
                    ForEach(MeasurementKind.allCases) { kind in
                        Label(kind.title, systemImage: kind.symbolName).tag(kind)
                    }
                }
                .pickerStyle(.segmented)

                if let pick = measurements.lastPick {
                    HStack(spacing: 10) {
                        Text(String(format: "%.2f m away", pick.distance))
                        Text("·")
                        Text(String(format: "±%.0f mm", pick.sigma * 1000))
                        Text("·")
                        Text(pickQualityText(pick))
                            .foregroundStyle(pickQualityTint(pick))
                    }
                    .font(.caption.monospacedDigit())
                }

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

    private func pickQualityText(_ pick: PickResult) -> String {
        switch pick.source {
        case .planeFit: return "\(pick.neighborCount) pts fitted"
        case .meshRaycast: return "mesh only"
        case .nearestPoint: return "sparse — rescan for a better fix"
        case .manual: return "manual"
        }
    }

    private func pickQualityTint(_ pick: PickResult) -> Color {
        switch pick.source {
        case .planeFit: return pick.neighborCount > 20 ? Theme.good : Theme.warn
        case .meshRaycast, .nearestPoint: return Theme.warn
        case .manual: return .white
        }
    }

    // MARK: - Finishing

    private var finishSheet: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Scan name", text: $controller.projectName)
                }
                Section("Captured") {
                    StatRow(label: "Points", value: Format.pointCount(host.livePointCount))
                    StatRow(label: "Stills", value: "\(controller.photos.count)")
                    StatRow(label: "Measurements", value: "\(measurements.measurements.count)")
                    StatRow(label: "Duration", value: Format.duration(controller.elapsed))
                    StatRow(label: "Frames used", value: "\(controller.frameCount)")
                    if controller.droppedForMotion > 0 {
                        StatRow(label: "Skipped for motion", value: "\(controller.droppedForMotion)")
                    }
                }
                Section("Georeference") {
                    GeoSolutionSummary(solution: controller.geoSolution)
                }
                Section {
                    Button {
                        finish()
                    } label: {
                        HStack {
                            Text("Save scan")
                            Spacer()
                            if isSaving { ProgressView() }
                        }
                    }
                    .disabled(isSaving)
                    Button("Keep scanning", role: .cancel) {
                        showsFinishSheet = false
                        controller.resume()
                    }
                    .disabled(isSaving)
                }
            }
            .navigationTitle("Finish scan")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func finish() {
        guard let accumulator = host.renderer.accumulator else { return }
        isSaving = true

        let project = controller.makeProject(measurements: measurements.measurements)
        let points = accumulator.snapshot()
        let chunks = Array(controller.mesh.chunks.values)
        let source = controller.workingDirectory

        Task {
            do {
                // The final voxel pass runs once, here, rather than on every
                // export: it is what turns the redundant capture buffer into a
                // uniform cloud, and every later operation benefits.
                let leaf = controller.settings.voxelLeafSize
                let filtered = await Task.detached(priority: .userInitiated) {
                    VoxelGridFilter.filter(points, leafSize: leaf)
                }.value

                var finished = project
                // Annotations placed during the scan can now be resolved against
                // the completed cloud.
                let cloud = PointCloud(points: filtered)
                PhotoCorrelator.resolveAnnotations(in: &finished.photos, cloud: cloud)

                let saved = try store.save(finished,
                                           points: filtered,
                                           meshChunks: chunks,
                                           photoSource: source)
                controller.stopSession()
                isSaving = false
                showsFinishSheet = false
                savedProject = saved
            } catch {
                isSaving = false
                saveError = error.localizedDescription
            }
        }
    }
}

/// Shared read-out of how well the scan is tied to the earth.
struct GeoSolutionSummary: View {
    let solution: GeoSolution

    var body: some View {
        Group {
            if solution.isUsable {
                StatRow(label: "Method", value: methodText, tint: methodTint)
                StatRow(label: "Origin", value: Format.coordinate(solution.origin))
                StatRow(label: "GPS fixes", value: "\(solution.fixCount)")
                StatRow(label: "Walked baseline", value: String(format: "%.1f m", solution.baselineLength))
                if solution.horizontalRMSE.isFinite {
                    StatRow(label: "Fit residual", value: String(format: "%.2f m", solution.horizontalRMSE))
                }
                StatRow(label: "Absolute accuracy",
                        value: Format.accuracy(solution.estimatedAbsoluteAccuracy),
                        tint: solution.estimatedAbsoluteAccuracy < 8 ? Theme.good : Theme.warn)
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("Not georeferenced", systemImage: "location.slash")
                    .foregroundStyle(Theme.warn)
                Text("Distances and areas are still exact. Latitude/longitude, LAS and GeoJSON export need a GPS fix.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var methodText: String {
        switch solution.method {
        case .none: return "None"
        case .singleFix: return "Single fix"
        case .compass: return "GPS + compass"
        case .gpsTrack: return "GPS track fit"
        }
    }

    private var methodTint: Color {
        switch solution.method {
        case .gpsTrack: return Theme.good
        case .compass, .singleFix: return Theme.warn
        case .none: return Theme.bad
        }
    }

    private var explanation: String {
        switch solution.method {
        case .gpsTrack:
            return "North and position were fitted from the path you walked against the GPS track — the most reliable result this app can produce."
        case .compass:
            return "North came from the magnetometer. Walk 10 m or more during a scan and the fit takes over, which is considerably more accurate."
        case .singleFix:
            return "Only one usable fix so far. Position is approximate and north is a guess."
        case .none:
            return ""
        }
    }
}
