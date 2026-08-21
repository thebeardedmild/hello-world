//
//  ScanController.swift
//
//  The scan-time coordinator: owns the ARSession, decides which frames are worth
//  accumulating, collects GPS correspondences, takes stills, and turns all of it
//  into a Project when the operator is done.
//
//  Metal work does not happen here — the renderer pulls the current frame and
//  asks this object whether to accumulate it. Keeping the two apart is what lets
//  the reviewer reuse the same renderer with no AR session at all.
//

import Foundation
import Combine
import ARKit
import CoreLocation
import UIKit
import simd

@MainActor
final class ScanController: NSObject, ObservableObject {

    // MARK: - Published state

    enum Phase: Equatable {
        case idle
        case starting
        case scanning
        case paused
        case finishing
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var trackingState: ARCamera.TrackingState = .notAvailable
    @Published private(set) var pointCount: Int = 0
    @Published private(set) var frameCount: Int = 0
    @Published private(set) var droppedForMotion: Int = 0
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var geoSolution: GeoSolution = .unsolved
    @Published private(set) var photos: [PhotoNote] = []
    @Published private(set) var meshFaceCount: Int = 0
    @Published private(set) var bufferFill: Double = 0
    @Published private(set) var isCompacting = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var lastPhotoID: UUID?
    @Published var settings: ScanSettings = .default
    @Published var projectName: String = ScanController.defaultProjectName()

    /// Set once the renderer has a Metal device.
    var accumulator: PointCloudAccumulator?

    let session = ARSession()
    let location = LocationProvider()
    let motion = MotionLogger()
    let mesh = MeshCapture()
    private let referencer = GeoReferencer()

    private var cancellables = Set<AnyCancellable>()
    private var startedAt: Date?
    private var lastAccumulatedTransform: simd_float4x4?
    private var timer: AnyCancellable?

    /// Where stills are written while scanning; moved into the project on save.
    private(set) var workingDirectory: URL

    // MARK: - Init

    override init() {
        workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scan-\(UUID().uuidString)", isDirectory: true)
        super.init()
        session.delegate = self
        session.delegateQueue = DispatchQueue(label: "com.geoscan.arsession", qos: .userInitiated)
        try? FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        observeLocation()
    }

    static var isSupported: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
            && ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    // MARK: - Session lifecycle

    func start() {
        guard phase == .idle || phase == .paused else { return }
        phase = .starting

        location.start()
        motion.start()

        let configuration = ARWorldTrackingConfiguration()
        // Gravity alignment only: the world's yaw is solved from the GPS track,
        // which beats the magnetometer as soon as the operator walks a few metres.
        configuration.worldAlignment = .gravity
        configuration.planeDetection = []
        configuration.environmentTexturing = .none
        configuration.isAutoFocusEnabled = true

        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            configuration.frameSemantics.insert(.smoothedSceneDepth)
        }
        if settings.captureMesh, ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            configuration.sceneReconstruction = .meshWithClassification
        } else if settings.captureMesh, ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
        }
        // Prefer the highest-resolution video format available; colour fidelity
        // is the whole point of a colourised cloud.
        if let best = ARWorldTrackingConfiguration.supportedVideoFormats
            .max(by: { $0.imageResolution.width * $0.imageResolution.height
                     < $1.imageResolution.width * $1.imageResolution.height }) {
            configuration.videoFormat = best
        }

        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])

        startedAt = Date()
        lastAccumulatedTransform = nil
        accumulator?.reset()
        accumulator?.startAccumulating()
        referencer.reset()
        mesh.reset()
        photos.removeAll()
        frameCount = 0
        droppedForMotion = 0
        phase = .scanning
        startTimer()
        statusMessage = "Walk slowly, keep surfaces 0.5–4 m away."
    }

    func pause() {
        guard phase == .scanning else { return }
        accumulator?.pauseAccumulating()
        phase = .paused
        statusMessage = "Paused — capture is stopped, tracking continues."
    }

    func resume() {
        guard phase == .paused else { return }
        accumulator?.startAccumulating()
        phase = .scanning
        statusMessage = nil
    }

    func stopSession() {
        session.pause()
        location.stop()
        motion.stop()
        timer?.cancel()
        timer = nil
        accumulator?.pauseAccumulating()
        phase = .idle
    }

    private func startTimer() {
        timer?.cancel()
        timer = Timer.publish(every: 0.25, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }

    private func tick() {
        if let startedAt { elapsed = Date().timeIntervalSince(startedAt) }
        if let accumulator {
            pointCount = accumulator.count
            bufferFill = accumulator.fillFraction
            isCompacting = accumulator.state == .compacting
        }
        meshFaceCount = mesh.faceCount
        // Re-solving is cheap (a handful of dot products per fix) and the fit
        // improves markedly as the walked baseline grows.
        if referencer.fixes.count >= 2 { geoSolution = referencer.solve() }
    }

    // MARK: - Frame gating

    /// Called by the renderer once per frame. Returns true when this frame
    /// should be unprojected into the cloud.
    func shouldAccumulate(frame: ARFrame) -> Bool {
        guard phase == .scanning else { return false }
        guard case .normal = frame.camera.trackingState else { return false }
        guard frame.sceneDepth != nil || frame.smoothedSceneDepth != nil else { return false }

        // Motion gate: above ~1 rad/s the rolling shutter smears colour onto the
        // wrong geometry, and no amount of downstream filtering fixes that.
        if settings.motionGateEnabled && !motion.isSteady {
            droppedForMotion += 1
            return false
        }

        let transform = frame.camera.transform
        guard let last = lastAccumulatedTransform else {
            lastAccumulatedTransform = transform
            frameCount += 1
            return true
        }

        let translation = simd_distance(last.position, transform.position)
        let rotation = angleBetween(last, transform)
        guard translation >= settings.minTranslation
                || rotation >= settings.minRotationDegrees * .pi / 180 else {
            return false
        }

        lastAccumulatedTransform = transform
        frameCount += 1
        return true
    }

    private func angleBetween(_ a: simd_float4x4, _ b: simd_float4x4) -> Float {
        let qa = simd_quatf(simd_float3x3(SIMD3(a.columns.0.x, a.columns.0.y, a.columns.0.z),
                                          SIMD3(a.columns.1.x, a.columns.1.y, a.columns.1.z),
                                          SIMD3(a.columns.2.x, a.columns.2.y, a.columns.2.z)))
        let qb = simd_quatf(simd_float3x3(SIMD3(b.columns.0.x, b.columns.0.y, b.columns.0.z),
                                          SIMD3(b.columns.1.x, b.columns.1.y, b.columns.1.z),
                                          SIMD3(b.columns.2.x, b.columns.2.y, b.columns.2.z)))
        let dot = abs(simd_dot(qa.vector, qb.vector))
        return 2 * acos(min(1, dot))
    }

    // MARK: - Georeferencing

    private func observeLocation() {
        location.$latestLocation
            .compactMap { $0 }
            .sink { [weak self] fix in self?.ingest(fix) }
            .store(in: &cancellables)

        // Grab a compass heading early: it is the yaw fallback for scans where
        // the operator never walks far enough for the track fit.
        location.$latestHeading
            .compactMap { $0 }
            .prefix(20)
            .sink { [weak self] _ in
                guard let self, self.referencer.initialTrueHeading == nil else { return }
                if let heading = self.location.trueHeading {
                    self.referencer.initialTrueHeading = heading
                }
            }
            .store(in: &cancellables)
    }

    private func ingest(_ fix: CLLocation) {
        guard phase == .scanning || phase == .paused else { return }
        guard let frame = session.currentFrame else { return }
        guard case .normal = frame.camera.trackingState else { return }

        let geodetic = Geodetic(latitude: fix.coordinate.latitude,
                                longitude: fix.coordinate.longitude,
                                ellipsoidalHeight: fix.ellipsoidalAltitude)
        let sample = GeoFix(worldPosition: frame.camera.transform.position,
                            geodetic: geodetic,
                            horizontalAccuracy: fix.horizontalAccuracy,
                            verticalAccuracy: fix.verticalAccuracy,
                            timestamp: fix.timestamp,
                            relativeBarometricAltitude: motion.relativeAltitude)
        referencer.add(sample)
    }

    var geoFixCount: Int { referencer.fixes.count }

    // MARK: - Stills

    @discardableResult
    func capturePhoto(note: String = "", tags: [String] = []) -> PhotoNote? {
        guard let frame = session.currentFrame else {
            statusMessage = "No camera frame yet."
            return nil
        }
        let orientation = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.interfaceOrientation }
            .first ?? .portrait

        guard let capture = PhotoCapture.capture(frame: frame,
                                                 interfaceOrientation: orientation,
                                                 location: location.latestLocation) else {
            statusMessage = "Could not encode the still."
            return nil
        }

        let fileName = "IMG_\(String(format: "%04d", photos.count + 1)).jpg"
        let url = workingDirectory.appendingPathComponent(fileName)
        do {
            try capture.jpeg.write(to: url, options: .atomic)
        } catch {
            statusMessage = "Could not write the still: \(error.localizedDescription)"
            return nil
        }

        // Anchor the pin on the surface the camera was aimed at, not at the lens.
        var aimPoint: SIMD3<Float>?
        let distance = PhotoCapture.aimDistance(frame: frame)
        if let distance {
            aimPoint = frame.camera.transform.position + frame.camera.transform.forward * distance
        }

        let photo = PhotoNote(fileName: fileName,
                              capturedAt: Date(),
                              note: note,
                              tags: tags,
                              cameraTransform: Matrix4x4Codable(capture.cameraTransform),
                              intrinsics: Matrix3x3Codable(capture.intrinsics),
                              imageWidth: capture.width,
                              imageHeight: capture.height,
                              exifOrientation: capture.exifOrientation,
                              aimPoint: aimPoint,
                              aimDistance: distance,
                              location: location.latestGeodetic,
                              locationHorizontalAccuracy: location.horizontalAccuracy,
                              exposureDuration: capture.exposureDuration,
                              exposureOffset: capture.exposureOffset)
        photos.append(photo)
        lastPhotoID = photo.id
        return photo
    }

    func updatePhoto(_ photo: PhotoNote) {
        guard let index = photos.firstIndex(where: { $0.id == photo.id }) else { return }
        photos[index] = photo
    }

    func deletePhoto(_ id: UUID) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        let fileName = photos[index].fileName
        photos.remove(at: index)
        try? FileManager.default.removeItem(at: workingDirectory.appendingPathComponent(fileName))
    }

    // MARK: - Finishing

    /// Freezes the scan into a Project value. The caller persists it.
    func makeProject(measurements: [SiteMeasurement]) -> Project {
        phase = .finishing
        accumulator?.pauseAccumulating()

        var project = Project(name: projectName)
        project.settings = settings
        project.geoFixes = referencer.fixes
        project.initialTrueHeading = referencer.initialTrueHeading
        project.resolveGeoreference()
        project.photos = photos
        project.measurements = measurements
        project.hasMesh = !mesh.chunks.isEmpty
        project.deviceModel = UIDevice.current.model
        project.systemVersion = UIDevice.current.systemVersion
        project.appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"

        var stats = ProjectStatistics()
        stats.pointCount = accumulator?.count ?? 0
        stats.rawPointCount = accumulator?.rawCount ?? 0
        stats.frameCount = frameCount
        stats.droppedForMotion = droppedForMotion
        stats.scanDuration = elapsed
        stats.meshFaceCount = mesh.faceCount
        if let bounds = accumulator?.bounds, !bounds.isEmpty {
            stats.boundsMin = bounds.min
            stats.boundsMax = bounds.max
        }
        project.statistics = stats
        project.updatedAt = Date()

        geoSolution = project.geoSolution
        return project
    }

    static func defaultProjectName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM, HH:mm"
        return "Scan \(formatter.string(from: Date()))"
    }

    // MARK: - Human-readable status

    var trackingDescription: String {
        switch trackingState {
        case .normal: return "Tracking"
        case .notAvailable: return "Starting…"
        case .limited(let reason):
            switch reason {
            case .initializing: return "Initialising"
            case .excessiveMotion: return "Slow down"
            case .insufficientFeatures: return "Not enough texture"
            case .relocalizing: return "Relocalising"
            @unknown default: return "Limited"
            }
        }
    }

    var isTrackingHealthy: Bool {
        if case .normal = trackingState { return true }
        return false
    }
}

// MARK: - ARSessionDelegate

extension ScanController: ARSessionDelegate {

    nonisolated func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let state = camera.trackingState
        Task { @MainActor in self.trackingState = state }
    }

    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        ingestMesh(anchors)
    }

    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        ingestMesh(anchors)
    }

    nonisolated func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        let identifiers = anchors.map(\.identifier)
        Task { @MainActor in self.mesh.remove(identifiers) }
    }

    /// Runs on the session's delegate queue: the anchor geometry is only safe to
    /// read here, so flatten first and hand the plain arrays to the main actor.
    private nonisolated func ingestMesh(_ anchors: [ARAnchor]) {
        let chunks = anchors.compactMap { ($0 as? ARMeshAnchor).map(MeshCapture.flatten) }
        guard !chunks.isEmpty else { return }
        Task { @MainActor in self.mesh.apply(chunks) }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in self.statusMessage = "AR session failed: \(message)" }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor in self.statusMessage = "Interrupted — capture paused." }
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        Task { @MainActor in self.statusMessage = "Resumed. Re-scan the last area to re-register." }
    }
}
