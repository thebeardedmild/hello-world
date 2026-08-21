//
//  SceneOverlayView.swift
//
//  Measurement graphics and photo pins, drawn in SwiftUI on top of the Metal
//  view rather than inside it.
//
//  Drawing them in 2-D is not a shortcut: labels stay crisp at any distance, pins
//  keep a sensible tap target however far away they are, and text never has to
//  fight the point cloud for the depth buffer. The renderer supplies the same
//  view-projection matrix it drew with, so the geometry lands exactly where the
//  points do.
//

import SwiftUI
import simd

struct SceneOverlayView: View {

    @ObservedObject var host: RenderHost
    let measurements: [SiteMeasurement]
    let selectedMeasurementID: UUID?
    let photos: [PhotoNote]
    var showsPhotoPins: Bool = true
    var onPhotoTap: ((PhotoNote) -> Void)?
    var onMeasurementTap: ((SiteMeasurement) -> Void)?

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            // frameTick is read so SwiftUI re-projects when the camera moves.
            let _ = host.frameTick

            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    for measurement in measurements {
                        draw(measurement, in: &context, size: size)
                    }
                }
                .allowsHitTesting(false)

                ForEach(measurements) { measurement in
                    if let anchor = labelAnchor(for: measurement, size: size) {
                        MeasurementLabel(measurement: measurement,
                                         isSelected: measurement.id == selectedMeasurementID)
                            .position(anchor)
                            .onTapGesture { onMeasurementTap?(measurement) }
                    }
                }

                if showsPhotoPins {
                    ForEach(photos) { photo in
                        if let point = host.renderer.project(photo.anchorPosition, viewSize: size) {
                            PhotoPin(photo: photo)
                                .position(point)
                                .onTapGesture { onPhotoTap?(photo) }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Drawing

    private func draw(_ measurement: SiteMeasurement, in context: inout GraphicsContext, size: CGSize) {
        let projected = measurement.vertices.compactMap {
            host.renderer.project($0.world, viewSize: size)
        }
        guard projected.count == measurement.vertices.count, !projected.isEmpty else { return }

        let isSelected = measurement.id == selectedMeasurementID
        let stroke = isSelected ? Theme.accent : Color.white
        let width: CGFloat = isSelected ? 3 : 2

        if projected.count >= 2 {
            var path = Path()
            path.move(to: projected[0])
            for point in projected.dropFirst() { path.addLine(to: point) }
            if measurement.kind == .area, projected.count >= 3 {
                path.closeSubpath()
                context.fill(path, with: .color(stroke.opacity(0.18)))
            }
            // A dark casing under the line keeps it readable over a bright cloud.
            context.stroke(path, with: .color(.black.opacity(0.55)), lineWidth: width + 2)
            context.stroke(path, with: .color(stroke), lineWidth: width)
        }

        for point in projected {
            let dot = Path(ellipseIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10))
            context.fill(dot, with: .color(.black.opacity(0.6)))
            let inner = Path(ellipseIn: CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7))
            context.fill(inner, with: .color(stroke))
        }
    }

    /// Midpoint of the run for a line, centroid for an area.
    private func labelAnchor(for measurement: SiteMeasurement, size: CGSize) -> CGPoint? {
        let projected = measurement.vertices.compactMap {
            host.renderer.project($0.world, viewSize: size)
        }
        guard !projected.isEmpty else { return nil }

        if measurement.kind == .area || projected.count > 2 {
            let sum = projected.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
            return CGPoint(x: sum.x / CGFloat(projected.count), y: sum.y / CGFloat(projected.count))
        }
        guard projected.count == 2 else { return projected[0] }
        return CGPoint(x: (projected[0].x + projected[1].x) / 2,
                       y: (projected[0].y + projected[1].y) / 2 - 22)
    }
}

private struct MeasurementLabel: View {
    let measurement: SiteMeasurement
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 1) {
            Text(measurement.primaryText)
                .font(.footnote.monospacedDigit().weight(.semibold))
            if let uncertainty = measurement.uncertaintyText {
                Text(uncertainty)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? Theme.accent : Color.white.opacity(0.2), lineWidth: isSelected ? 1.5 : 0.5)
        )
        .shadow(radius: 3, y: 1)
        .fixedSize()
    }
}

private struct PhotoPin: View {
    let photo: PhotoNote

    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.accent)
                .frame(width: 26, height: 26)
            Image(systemName: photo.note.isEmpty ? "camera.fill" : "text.bubble.fill")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.black)
        }
        .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1.5))
        .shadow(radius: 3, y: 1)
        // The pin's tap target is bigger than the pin itself; these are small
        // and the operator is usually holding the phone one-handed.
        .contentShape(Circle().inset(by: -10))
        .accessibilityLabel(photo.note.isEmpty ? "Photo" : "Photo: \(photo.note)")
    }
}
