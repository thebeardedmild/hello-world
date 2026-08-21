//
//  OrbitCamera.swift
//  Turntable camera for the reviewer: orbit, pan and dolly around a target.
//

import Foundation
import CoreGraphics
import simd

final class OrbitCamera {

    /// Point the camera orbits, world space.
    var target: SIMD3<Float> = .zero
    /// Distance from the target, metres.
    var distance: Float = 4
    /// Rotation about the world up axis, radians.
    var azimuth: Float = 0
    /// Elevation above the horizon, radians, clamped short of the poles.
    var elevation: Float = 0.35
    var fieldOfView: Float = 60 * .pi / 180
    var near: Float = 0.02
    var far: Float = 500

    private var minDistance: Float = 0.15
    private var maxDistance: Float = 400

    var position: SIMD3<Float> {
        let cosE = cos(elevation)
        return target + SIMD3(distance * cosE * sin(azimuth),
                              distance * sin(elevation),
                              distance * cosE * cos(azimuth))
    }

    func viewMatrix() -> simd_float4x4 {
        simd_float4x4.lookAt(eye: position, target: target, up: SIMD3(0, 1, 0))
    }

    func projectionMatrix(aspect: Float) -> simd_float4x4 {
        .perspective(fovYRadians: fieldOfView, aspect: max(aspect, 0.01), near: near, far: far)
    }

    // MARK: - Gestures

    func orbit(deltaX: Float, deltaY: Float) {
        azimuth -= deltaX * 0.006
        elevation = max(-1.52, min(1.52, elevation + deltaY * 0.006))
    }

    func dolly(scale: Float) {
        guard scale > 0 else { return }
        distance = max(minDistance, min(maxDistance, distance / scale))
    }

    /// Pan in the camera's own screen plane, scaled by distance so the cloud
    /// tracks the finger at any zoom level.
    func pan(deltaX: Float, deltaY: Float, viewHeight: Float) {
        let view = viewMatrix()
        let right = SIMD3(view.columns.0.x, view.columns.1.x, view.columns.2.x)
        let up = SIMD3(view.columns.0.y, view.columns.1.y, view.columns.2.y)
        let metersPerPixel = 2 * distance * tan(fieldOfView * 0.5) / max(viewHeight, 1)
        target -= right * (deltaX * metersPerPixel)
        target += up * (deltaY * metersPerPixel)
    }

    /// Frame a bounding box, leaving a little air around it.
    func frame(bounds: PointCloudBounds) {
        guard !bounds.isEmpty else { return }
        target = bounds.center
        let radius = max(bounds.radius, 0.25)
        distance = max(minDistance, radius / tan(fieldOfView * 0.5) * 1.25)
        maxDistance = max(maxDistance, distance * 6)
        far = max(200, distance * 10)
    }

    /// Move to look at the scene the way a photo did, for "show me where this
    /// picture was taken".
    func match(photo: PhotoNote) {
        let eye = photo.cameraPosition
        let look = photo.anchorPosition
        target = look
        let offset = eye - look
        distance = max(minDistance, simd_length(offset))
        let horizontal = (offset.x * offset.x + offset.z * offset.z).squareRoot()
        azimuth = atan2(offset.x, offset.z)
        elevation = atan2(offset.y, max(horizontal, 1e-4))
    }
}
