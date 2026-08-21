//
//  PointCloudPicker.swift
//
//  Turning a fingertip into a millimetre-honest 3-D coordinate.
//
//  A raw nearest-point pick inherits the full sensor noise of one sample, which
//  on an iPhone is roughly 1% of range — 3 cm at 3 m, and it will not repeat.
//  So we do it in two stages: find the first point cluster the ray pierces, then
//  fit a local plane through its neighbourhood by PCA and intersect the ray with
//  that plane. Averaging n samples pulls the noise down by sqrt(n), and the
//  residual of the fit gives an honest error bar to show next to the number.
//

import Foundation
import simd

struct PickResult {
    var world: SIMD3<Float>
    /// One-sigma position uncertainty, metres.
    var sigma: Float
    var source: MeasurementVertex.Source
    /// Points that took part in the local fit.
    var neighborCount: Int
    /// RMS residual of the plane fit, metres. High means a corner or an edge.
    var planarityRMS: Float
    /// Surface normal from the fit, world space.
    var normal: SIMD3<Float>
    /// Distance from the ray origin.
    var distance: Float

    var vertex: MeasurementVertex {
        MeasurementVertex(world: world, sigma: sigma, source: source)
    }
}

enum PointCloudPicker {

    /// Half-angle of the selection cone. 0.6° at 2 m is a ~2 cm disc, which is
    /// about the size of a fingertip on screen.
    static var coneHalfAngle: Float = 0.0105
    /// Never let the cone shrink below this, or picks fail at close range.
    static var minimumConeRadius: Float = 0.012
    /// Radius of the neighbourhood used for the plane fit.
    static var fitRadius: Float = 0.05
    /// Below this many neighbours, fall back to the raw point.
    static var minimumFitNeighbors: Int = 6

    /// Intersect a ray with the cloud.
    static func pick(cloud: PointCloud,
                     origin: SIMD3<Float>,
                     direction rawDirection: SIMD3<Float>,
                     maxDistance: Float = 30.0,
                     minConfidence: UInt8 = 1) -> PickResult? {
        guard !cloud.isEmpty else { return nil }
        let direction = simd_normalize(rawDirection)
        let grid = cloud.spatialIndex()
        let candidates = grid.indices(alongRay: origin, direction: direction,
                                      maxDistance: maxDistance,
                                      radius: max(minimumConeRadius, coneHalfAngle * maxDistance))
        guard !candidates.isEmpty else { return nil }

        // First hit along the ray, inside a cone that widens with distance.
        var bestT = Float.greatestFiniteMagnitude
        var bestIndex = -1
        for c in candidates {
            let i = Int(c)
            let p = cloud.points[i]
            guard p.confidence >= minConfidence, p.isFinite else { continue }
            let v = p.position - origin
            let t = simd_dot(v, direction)
            guard t > 0.05, t < maxDistance, t < bestT else { continue }
            let perpendicular = simd_length(v - direction * t)
            let allowed = max(minimumConeRadius, coneHalfAngle * t)
            if perpendicular <= allowed {
                bestT = t
                bestIndex = i
            }
        }
        guard bestIndex >= 0 else { return nil }

        let seed = cloud.points[bestIndex].position
        return refine(cloud: cloud, seed: seed, origin: origin, direction: direction,
                      minConfidence: minConfidence)
    }

    /// Snap an approximate world position (say, an ARKit mesh raycast hit) onto
    /// the cloud, so that a measurement taken off the mesh and one taken off the
    /// cloud agree.
    static func refine(cloud: PointCloud,
                       seed: SIMD3<Float>,
                       origin: SIMD3<Float>,
                       direction: SIMD3<Float>,
                       minConfidence: UInt8 = 1) -> PickResult {
        let grid = cloud.spatialIndex()
        let candidates = grid.indices(near: seed, radius: fitRadius)

        var neighbors: [SIMD3<Float>] = []
        neighbors.reserveCapacity(candidates.count)
        for c in candidates {
            let p = cloud.points[Int(c)]
            guard p.confidence >= minConfidence, p.isFinite else { continue }
            if simd_distance(p.position, seed) <= fitRadius { neighbors.append(p.position) }
        }

        guard neighbors.count >= minimumFitNeighbors else {
            // Not enough support for a fit — report the raw point and an honest
            // sensor-noise sigma instead of pretending to a precision we lack.
            let distance = simd_length(seed - origin)
            return PickResult(world: seed,
                              sigma: rawSensorSigma(atRange: distance),
                              source: .nearestPoint,
                              neighborCount: neighbors.count,
                              planarityRMS: .nan,
                              normal: -direction,
                              distance: distance)
        }

        var centroid = SIMD3<Float>(repeating: 0)
        for n in neighbors { centroid += n }
        centroid /= Float(neighbors.count)

        let (normal, planarity) = planeFit(neighbors, centroid: centroid)

        // Intersect the ray with the fitted plane. If the surface is close to
        // edge-on the intersection is ill-conditioned, so keep the centroid.
        var world = centroid
        var source = MeasurementVertex.Source.planeFit
        let denom = simd_dot(normal, direction)
        if abs(denom) > 0.15 {
            let t = simd_dot(normal, centroid - origin) / denom
            if t > 0.05 {
                let candidate = origin + direction * t
                // Only accept it if it stays inside the neighbourhood we fitted.
                if simd_distance(candidate, centroid) <= fitRadius { world = candidate }
            }
        } else {
            source = .nearestPoint
        }

        let distance = simd_length(world - origin)
        // Averaging n samples reduces the noise by sqrt(n), but the systematic
        // part of the sensor error does not average out, so keep a floor.
        let averaged = rawSensorSigma(atRange: distance) / Float(neighbors.count).squareRoot()
        let fitError = planarity.isFinite ? planarity * 0.5 : 0
        let sigma = max(0.002, (averaged * averaged + fitError * fitError).squareRoot())

        return PickResult(world: world,
                          sigma: sigma,
                          source: source,
                          neighborCount: neighbors.count,
                          planarityRMS: planarity,
                          normal: normal,
                          distance: distance)
    }

    /// Single-sample depth noise for the iPhone LiDAR: a fixed floor plus about
    /// 1% of range. Conservative, and it matches what repeat picks actually show.
    static func rawSensorSigma(atRange range: Float) -> Float {
        max(0.004, 0.004 + 0.010 * range)
    }

    // MARK: - Plane fitting

    /// Least-squares plane through a neighbourhood: the eigenvector of the
    /// covariance matrix with the smallest eigenvalue is the normal, and the
    /// square root of that eigenvalue is the RMS distance to the plane.
    static func planeFit(_ points: [SIMD3<Float>], centroid: SIMD3<Float>) -> (normal: SIMD3<Float>, rms: Float) {
        var xx: Float = 0, xy: Float = 0, xz: Float = 0
        var yy: Float = 0, yz: Float = 0, zz: Float = 0
        for p in points {
            let d = p - centroid
            xx += d.x * d.x; xy += d.x * d.y; xz += d.x * d.z
            yy += d.y * d.y; yz += d.y * d.z; zz += d.z * d.z
        }
        let n = Float(points.count)
        let cov = simd_float3x3(SIMD3(xx / n, xy / n, xz / n),
                                SIMD3(xy / n, yy / n, yz / n),
                                SIMD3(xz / n, yz / n, zz / n))
        let (values, vectors) = symmetricEigen(cov)

        // Eigenvalues come back ascending, so column 0 is the plane normal.
        var normal = vectors.columns.0
        if simd_length(normal) < 1e-9 { normal = SIMD3(0, 1, 0) }
        normal = simd_normalize(normal)
        let rms = max(values.x, 0).squareRoot()
        return (normal, rms)
    }

    /// Jacobi eigenvalue iteration for a symmetric 3x3. Converges in a handful of
    /// sweeps and, unlike a closed-form solve, stays well behaved on the
    /// near-degenerate covariance a flat wall produces.
    static func symmetricEigen(_ m: simd_float3x3) -> (values: SIMD3<Float>, vectors: simd_float3x3) {
        var a = m
        var v = matrix_identity_float3x3

        for _ in 0..<12 {
            // Largest off-diagonal magnitude decides which rotation to apply.
            let offDiagonals: [(Float, Int, Int)] = [
                (abs(a[1][0]), 0, 1),
                (abs(a[2][0]), 0, 2),
                (abs(a[2][1]), 1, 2)
            ]
            guard let pivot = offDiagonals.max(by: { $0.0 < $1.0 }), pivot.0 > 1e-12 else { break }
            let (p, q) = (pivot.1, pivot.2)

            let apq = a[q][p]
            let app = a[p][p]
            let aqq = a[q][q]
            let theta = (aqq - app) / (2 * apq)
            let t = (theta >= 0 ? 1 : -1) / (abs(theta) + (theta * theta + 1).squareRoot())
            let c = 1 / (t * t + 1).squareRoot()
            let s = t * c

            var rotation = matrix_identity_float3x3
            rotation[p][p] = c
            rotation[q][q] = c
            rotation[q][p] = s
            rotation[p][q] = -s

            a = rotation.transpose * a * rotation
            v = v * rotation
        }

        var values = SIMD3<Float>(a[0][0], a[1][1], a[2][2])
        var columns = [v.columns.0, v.columns.1, v.columns.2]

        // Sort ascending by eigenvalue so the caller can always take column 0.
        var order = [0, 1, 2]
        order.sort { values[$0] < values[$1] }
        values = SIMD3(values[order[0]], values[order[1]], values[order[2]])
        columns = [columns[order[0]], columns[order[1]], columns[order[2]]]

        return (values, simd_float3x3(columns[0], columns[1], columns[2]))
    }
}
