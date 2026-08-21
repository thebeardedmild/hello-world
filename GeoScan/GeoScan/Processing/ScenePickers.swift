//
//  ScenePickers.swift
//
//  Screen tap -> world ray -> world point.
//
//  Two sources of geometry are available and they are good at different things:
//  the ARKit mesh is smooth and continuous (nice to snap to, but it invents
//  surfaces across gaps), and the point cloud is the raw truth (noisy, but only
//  where something was actually seen). So we intersect both and prefer whichever
//  is in front, then always refine against the cloud so that the number you read
//  came from measured points.
//

import Foundation
import CoreGraphics
import simd

/// Unprojects screen taps using a view-projection matrix.
struct CameraRay {
    var origin: SIMD3<Float>
    var direction: SIMD3<Float>

    /// - Parameters:
    ///   - screenPoint: UIKit coordinates, origin top-left.
    ///   - viewSize: view size in the same coordinate space.
    static func make(screenPoint: CGPoint, viewSize: CGSize, viewProjection: simd_float4x4) -> CameraRay? {
        guard viewSize.width > 0, viewSize.height > 0 else { return nil }
        let inverse = viewProjection.inverse

        // UIKit -> normalised device coordinates (y flips).
        let ndcX = Float(screenPoint.x / viewSize.width) * 2 - 1
        let ndcY = 1 - Float(screenPoint.y / viewSize.height) * 2

        // Metal's clip space is z in [0, 1]: 0 is the near plane, 1 the far one.
        let nearPoint = inverse * SIMD4<Float>(ndcX, ndcY, 0, 1)
        let farPoint = inverse * SIMD4<Float>(ndcX, ndcY, 1, 1)
        guard abs(nearPoint.w) > 1e-9, abs(farPoint.w) > 1e-9 else { return nil }

        let origin = SIMD3(nearPoint.x, nearPoint.y, nearPoint.z) / nearPoint.w
        let target = SIMD3(farPoint.x, farPoint.y, farPoint.z) / farPoint.w
        let delta = target - origin
        guard simd_length(delta) > 1e-6 else { return nil }
        return CameraRay(origin: origin, direction: simd_normalize(delta))
    }
}

/// Ray/triangle intersection against the captured ARKit mesh.
enum MeshRaycaster {

    struct Hit {
        var world: SIMD3<Float>
        var normal: SIMD3<Float>
        var distance: Float
    }

    static func raycast(chunks: [MeshChunk],
                        origin: SIMD3<Float>,
                        direction: SIMD3<Float>,
                        maxDistance: Float = 30) -> Hit? {
        var best: Hit?
        for chunk in chunks {
            // Cheap reject: skip a chunk the ray never enters.
            guard let box = boundingBox(chunk.vertices),
                  intersectsBox(origin: origin, direction: direction, box: box, maxDistance: maxDistance) else {
                continue
            }
            var i = 0
            while i + 2 < chunk.indices.count {
                let a = chunk.vertices[Int(chunk.indices[i])]
                let b = chunk.vertices[Int(chunk.indices[i + 1])]
                let c = chunk.vertices[Int(chunk.indices[i + 2])]
                if let t = intersectTriangle(origin: origin, direction: direction, a: a, b: b, c: c),
                   t > 0.03, t < maxDistance, t < (best?.distance ?? .greatestFiniteMagnitude) {
                    let normal = simd_normalize(simd_cross(b - a, c - a))
                    best = Hit(world: origin + direction * t, normal: normal, distance: t)
                }
                i += 3
            }
        }
        return best
    }

    /// Möller–Trumbore, double sided — the reconstruction's winding is not
    /// something a measurement should depend on.
    static func intersectTriangle(origin: SIMD3<Float>, direction: SIMD3<Float>,
                                  a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>) -> Float? {
        let edge1 = b - a
        let edge2 = c - a
        let h = simd_cross(direction, edge2)
        let det = simd_dot(edge1, h)
        if abs(det) < 1e-8 { return nil }
        let invDet = 1 / det
        let s = origin - a
        let u = invDet * simd_dot(s, h)
        if u < 0 || u > 1 { return nil }
        let q = simd_cross(s, edge1)
        let v = invDet * simd_dot(direction, q)
        if v < 0 || u + v > 1 { return nil }
        let t = invDet * simd_dot(edge2, q)
        return t > 0 ? t : nil
    }

    private static func boundingBox(_ vertices: [SIMD3<Float>]) -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        guard let first = vertices.first else { return nil }
        var lo = first, hi = first
        for v in vertices { lo = simd_min(lo, v); hi = simd_max(hi, v) }
        return (lo, hi)
    }

    /// Slab test.
    private static func intersectsBox(origin: SIMD3<Float>, direction: SIMD3<Float>,
                                      box: (min: SIMD3<Float>, max: SIMD3<Float>),
                                      maxDistance: Float) -> Bool {
        var tMin: Float = 0
        var tMax = maxDistance
        for axis in 0..<3 {
            let d = direction[axis]
            let lo = box.min[axis], hi = box.max[axis]
            if abs(d) < 1e-9 {
                if origin[axis] < lo || origin[axis] > hi { return false }
            } else {
                var t1 = (lo - origin[axis]) / d
                var t2 = (hi - origin[axis]) / d
                if t1 > t2 { swap(&t1, &t2) }
                tMin = max(tMin, t1)
                tMax = min(tMax, t2)
                if tMin > tMax { return false }
            }
        }
        return true
    }
}

/// Picks against the mesh and the cloud together.
@MainActor
final class HybridScenePicker: ScenePicker {

    /// Supplies the current view-projection matrix; the renderer owns it.
    var viewProjectionProvider: () -> simd_float4x4
    /// Supplies the cloud to pick against. Rebuilt lazily as the scan grows.
    var cloudProvider: () -> PointCloud?
    var meshProvider: () -> [MeshChunk]
    var minConfidence: UInt8 = 1

    init(viewProjectionProvider: @escaping () -> simd_float4x4,
         cloudProvider: @escaping () -> PointCloud?,
         meshProvider: @escaping () -> [MeshChunk] = { [] }) {
        self.viewProjectionProvider = viewProjectionProvider
        self.cloudProvider = cloudProvider
        self.meshProvider = meshProvider
    }

    func pick(at screenPoint: CGPoint, viewSize: CGSize) -> PickResult? {
        guard let ray = CameraRay.make(screenPoint: screenPoint,
                                       viewSize: viewSize,
                                       viewProjection: viewProjectionProvider()) else { return nil }
        let cloud = cloudProvider()
        let meshHit = MeshRaycaster.raycast(chunks: meshProvider(),
                                            origin: ray.origin,
                                            direction: ray.direction)
        let cloudHit = cloud.flatMap {
            PointCloudPicker.pick(cloud: $0,
                                  origin: ray.origin,
                                  direction: ray.direction,
                                  minConfidence: minConfidence)
        }

        switch (meshHit, cloudHit) {
        case (nil, nil):
            return nil

        case (let mesh?, nil):
            // Mesh only: no measured points nearby, so report the mesh's own
            // smoothing error rather than a fictitious sub-centimetre sigma.
            return PickResult(world: mesh.world,
                              sigma: max(0.02, PointCloudPicker.rawSensorSigma(atRange: mesh.distance)),
                              source: .meshRaycast,
                              neighborCount: 0,
                              planarityRMS: .nan,
                              normal: mesh.normal,
                              distance: mesh.distance)

        case (nil, let cloudPick?):
            return cloudPick

        case (let mesh?, let cloudPick?):
            // If the two agree, the cloud's plane fit is the more precise answer.
            // If the mesh is clearly in front, the ray hit a surface the cloud
            // has not covered, and snapping to a distant point would be wrong.
            if mesh.distance < cloudPick.distance - 0.10, let cloud {
                return PointCloudPicker.refine(cloud: cloud,
                                               seed: mesh.world,
                                               origin: ray.origin,
                                               direction: ray.direction,
                                               minConfidence: minConfidence)
            }
            return cloudPick
        }
    }
}
