//
//  MeasurementEngine.swift
//
//  Drives the measure interaction. The two places you can measure — live in AR
//  and later in the reviewer — differ only in how a screen tap becomes a ray and
//  how a world point becomes a screen position, so both are abstracted behind
//  small protocols and the interaction logic is written once.
//

import Foundation
import CoreGraphics
import Combine
import simd

/// Turns a screen tap into a 3-D point.
///
/// Main-actor bound on purpose: every implementation reads renderer state and
/// live capture buffers that only the main thread owns.
@MainActor
protocol ScenePicker: AnyObject {
    func pick(at screenPoint: CGPoint, viewSize: CGSize) -> PickResult?
}

/// Turns a 3-D point into a screen position, for SwiftUI overlays.
@MainActor
protocol ScreenProjector: AnyObject {
    /// Returns nil when the point is behind the camera or outside the frustum.
    func project(_ world: SIMD3<Float>, viewSize: CGSize) -> CGPoint?
    /// Camera position in world space, for depth sorting and label scaling.
    var eyePosition: SIMD3<Float> { get }
}

@MainActor
final class MeasurementEngine: ObservableObject {

    @Published var kind: MeasurementKind = .distance
    /// The measurement currently being placed, if any.
    @Published private(set) var draft: SiteMeasurement?
    /// Finished measurements for the open project.
    @Published var measurements: [SiteMeasurement] = []
    /// Last pick, so the HUD can show live quality feedback.
    @Published private(set) var lastPick: PickResult?
    @Published var selectedID: UUID?
    @Published var lastError: String?

    var isDrafting: Bool { draft != nil }

    var draftIsComplete: Bool {
        guard let draft else { return false }
        return draft.isComplete
    }

    // MARK: - Interaction

    func beginOrExtend(at screenPoint: CGPoint, viewSize: CGSize, picker: ScenePicker) {
        guard let pick = picker.pick(at: screenPoint, viewSize: viewSize) else {
            lastError = "No surface there — move closer or scan that area first."
            return
        }
        lastError = nil
        lastPick = pick
        append(pick.vertex)
    }

    func append(_ vertex: MeasurementVertex) {
        if draft == nil {
            draft = SiteMeasurement(kind: kind, vertices: [vertex])
            return
        }
        guard var current = draft else { return }
        if !kind.acceptsMoreVertices && current.vertices.count >= kind.requiredVertices {
            // A two-point kind is full: start the next one from this tap.
            commitDraft()
            draft = SiteMeasurement(kind: kind, vertices: [vertex])
            return
        }
        current.vertices.append(vertex)
        draft = current

        // Distance and height complete themselves at two points; a path or an
        // area stays open until the operator says it is done.
        if !kind.acceptsMoreVertices && current.vertices.count >= kind.requiredVertices {
            commitDraft()
        }
    }

    func undoLastVertex() {
        guard var current = draft else { return }
        current.vertices.removeLast()
        draft = current.vertices.isEmpty ? nil : current
    }

    @discardableResult
    func commitDraft() -> SiteMeasurement? {
        guard let current = draft else { return nil }
        guard current.isComplete else {
            lastError = "\(current.kind.title) needs at least \(current.kind.requiredVertices) points."
            return nil
        }
        var finished = current
        finished.label = defaultLabel(for: finished.kind)
        measurements.append(finished)
        draft = nil
        selectedID = finished.id
        return finished
    }

    func cancelDraft() {
        draft = nil
        lastError = nil
    }

    func delete(_ id: UUID) {
        measurements.removeAll { $0.id == id }
        if selectedID == id { selectedID = nil }
    }

    func update(_ measurement: SiteMeasurement) {
        guard let index = measurements.firstIndex(where: { $0.id == measurement.id }) else { return }
        measurements[index] = measurement
    }

    func setKind(_ newKind: MeasurementKind) {
        if draft != nil { cancelDraft() }
        kind = newKind
    }

    // MARK: - Presentation helpers

    /// Everything that should be drawn right now, draft included.
    var displayed: [SiteMeasurement] {
        if let draft { return measurements + [draft] }
        return measurements
    }

    /// Short instruction for the current state, shown under the reticle.
    var prompt: String {
        guard let draft else {
            switch kind {
            case .distance: return "Tap the first end of the distance"
            case .height:   return "Tap the bottom of the height"
            case .polyline: return "Tap the start of the path"
            case .area:     return "Tap the first corner of the area"
            }
        }
        let n = draft.vertices.count
        switch kind {
        case .distance: return "Tap the other end"
        case .height:   return "Tap the top"
        case .polyline: return n < 2 ? "Tap the next point" : "Tap to extend, or Done to finish"
        case .area:     return n < 3 ? "Tap the next corner (\(3 - n) more)" : "Tap to extend, or Done to close the shape"
        }
    }

    private func defaultLabel(for kind: MeasurementKind) -> String {
        let existing = measurements.filter { $0.kind == kind }.count + 1
        return "\(kind.title) \(existing)"
    }
}
