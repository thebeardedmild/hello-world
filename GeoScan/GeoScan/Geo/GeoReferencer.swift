//
//  GeoReferencer.swift
//
//  Ties the ARKit world frame to the earth.
//
//  The world frame is gravity aligned, so only four unknowns are left: the
//  geodetic position of the world origin (3) and a yaw about the up axis (1).
//  We estimate all four from the stream of (world position, GPS fix) pairs
//  collected while scanning:
//
//    * Position comes from an accuracy-weighted least-squares fit.
//    * Yaw comes from a 2-D Procrustes fit of the walked path against the GPS
//      track — no scale term, because both are already metric. That beats the
//      magnetometer by a wide margin as soon as you have walked a few metres.
//    * If the operator never moved far enough for the track fit to be stable we
//      fall back to the compass heading recorded at session start.
//
//  The solution is stored, not baked in, so a scan can be re-solved later.
//

import Foundation
import simd

/// One (AR world position, GPS fix) correspondence.
struct GeoFix: Codable, Equatable {
    var worldPosition: SIMD3<Float>
    var geodetic: Geodetic
    var horizontalAccuracy: Double
    var verticalAccuracy: Double
    var timestamp: Date
    /// Barometric relative altitude in metres since session start, when available.
    var relativeBarometricAltitude: Double?
}

struct GeoSolution: Codable, Equatable {
    enum Method: String, Codable {
        case none          // no usable GPS at all
        case singleFix     // one or more fixes, position only, compass yaw
        case compass       // averaged position, compass yaw
        case gpsTrack      // position and yaw fitted from the walked path
    }

    /// Geodetic position of the AR world origin.
    var origin: Geodetic
    /// Rotation, in radians, taking the AR horizontal frame (x, -z) to (east, north).
    var yaw: Double
    var method: Method
    var fixCount: Int
    /// RMS of the horizontal residuals, metres. Reads as "how well the walked
    /// path agrees with the GPS track", not as absolute accuracy.
    var horizontalRMSE: Double
    var verticalRMSE: Double
    /// Best horizontal accuracy reported by any contributing fix, metres.
    var bestFixAccuracy: Double
    /// Extent of the walked path, metres. Short baselines make yaw unreliable.
    var baselineLength: Double
    var solvedAt: Date

    static let unsolved = GeoSolution(origin: .zero, yaw: 0, method: .none, fixCount: 0,
                                      horizontalRMSE: .nan, verticalRMSE: .nan,
                                      bestFixAccuracy: .nan, baselineLength: 0,
                                      solvedAt: Date(timeIntervalSince1970: 0))

    var isUsable: Bool { method != .none }

    /// Rough one-sigma absolute accuracy of a georeferenced point: the GPS fix
    /// quality dominates, the fit residual adds on top.
    var estimatedAbsoluteAccuracy: Double {
        guard isUsable else { return .nan }
        let fit = horizontalRMSE.isFinite ? horizontalRMSE : 0
        let fix = bestFixAccuracy.isFinite ? bestFixAccuracy : 10
        return (fix * fix + fit * fit).squareRoot()
    }

    /// AR world point -> ENU offset from the origin.
    func enu(for world: SIMD3<Float>) -> ENU {
        // AR horizontal plane is (x, -z); +y is up.
        let hx = Double(world.x)
        let hy = Double(-world.z)
        let c = cos(yaw), s = sin(yaw)
        return ENU(east: c * hx - s * hy,
                   north: s * hx + c * hy,
                   up: Double(world.y))
    }

    /// AR world point -> latitude / longitude / ellipsoidal height.
    func geodetic(for world: SIMD3<Float>) -> Geodetic {
        Geodesy.geodetic(enu: enu(for: world), from: origin)
    }

    /// Inverse: ENU offset -> AR world point. Used to drop a pin from a coordinate.
    func world(forENU e: ENU) -> SIMD3<Float> {
        let c = cos(-yaw), s = sin(-yaw)
        let hx = c * e.east - s * e.north
        let hy = s * e.east + c * e.north
        return SIMD3<Float>(Float(hx), Float(e.up), Float(-hy))
    }

    /// True-north bearing, in degrees, of an AR-world direction.
    func bearing(forWorldDirection d: SIMD3<Float>) -> Double {
        let e = enu(for: d)   // rotation only; the origin cancels for a direction
        return (atan2(e.east, e.north) * 180.0 / .pi + 360.0).truncatingRemainder(dividingBy: 360.0)
    }
}

/// Accumulates fixes and solves for the world-to-earth transform.
final class GeoReferencer {

    /// Fixes worse than this are ignored outright.
    var maxAcceptableHorizontalAccuracy: Double = 25.0
    /// Minimum walked extent before the track fit is trusted for yaw.
    var minimumBaselineForYaw: Double = 4.0
    /// Minimum fix count before the track fit is trusted for yaw.
    var minimumFixesForYaw: Int = 6
    /// Fixes closer together than this add noise without adding geometry.
    var minimumFixSpacing: Double = 0.75

    private(set) var fixes: [GeoFix] = []
    /// Compass heading (degrees from true north) captured at session start.
    var initialTrueHeading: Double?

    var latestSolution: GeoSolution = .unsolved

    // MARK: - Collection

    /// Returns true when the fix was kept.
    @discardableResult
    func add(_ fix: GeoFix) -> Bool {
        guard fix.horizontalAccuracy > 0,
              fix.horizontalAccuracy <= maxAcceptableHorizontalAccuracy,
              fix.geodetic.latitude.isFinite, fix.geodetic.longitude.isFinite else {
            return false
        }
        if let last = fixes.last {
            let moved = simd_distance(last.worldPosition, fix.worldPosition)
            // Keep a stationary fix only if it is meaningfully more accurate.
            if Double(moved) < minimumFixSpacing,
               fix.horizontalAccuracy > last.horizontalAccuracy * 0.8 {
                return false
            }
        }
        fixes.append(fix)
        return true
    }

    func reset() {
        fixes.removeAll()
        latestSolution = .unsolved
        initialTrueHeading = nil
    }

    // MARK: - Solving

    @discardableResult
    func solve() -> GeoSolution {
        latestSolution = GeoReferencer.solve(fixes: fixes,
                                             initialTrueHeading: initialTrueHeading,
                                             minimumBaselineForYaw: minimumBaselineForYaw,
                                             minimumFixesForYaw: minimumFixesForYaw)
        return latestSolution
    }

    /// Pure function so it can be re-run over a stored scan's fixes.
    static func solve(fixes: [GeoFix],
                      initialTrueHeading: Double?,
                      minimumBaselineForYaw: Double = 4.0,
                      minimumFixesForYaw: Int = 6) -> GeoSolution {
        guard !fixes.isEmpty else { return .unsolved }

        // Inverse-variance weights, floored so a wildly optimistic fix cannot
        // dominate the fit.
        let weights = fixes.map { fix -> Double in
            let sigma = max(fix.horizontalAccuracy, 1.0)
            return 1.0 / (sigma * sigma)
        }
        let weightSum = weights.reduce(0, +)
        guard weightSum > 0 else { return .unsolved }

        // Provisional tangent-plane origin: the weighted mean fix.
        let provisional = Geodetic(
            latitude: zip(fixes, weights).reduce(0) { $0 + $1.0.geodetic.latitude * $1.1 } / weightSum,
            longitude: zip(fixes, weights).reduce(0) { $0 + $1.0.geodetic.longitude * $1.1 } / weightSum,
            ellipsoidalHeight: zip(fixes, weights).reduce(0) { $0 + $1.0.geodetic.ellipsoidalHeight * $1.1 } / weightSum)

        // Correspondences in the provisional tangent plane.
        let gps = fixes.map { Geodesy.enu(of: $0.geodetic, from: provisional) }
        let ar = fixes.map { fix -> SIMD2<Double> in
            SIMD2(Double(fix.worldPosition.x), Double(-fix.worldPosition.z))
        }
        let arUp = fixes.map { Double($0.worldPosition.y) }

        let baseline = pathExtent(ar)
        let bestAccuracy = fixes.map(\.horizontalAccuracy).min() ?? .nan

        // Compass fallback: AR forward (0, 1) points along the recorded heading,
        // and R(yaw) * (0, 1) = (-sin yaw, cos yaw), so yaw = -heading.
        let compassYaw = initialTrueHeading.map { -$0 * .pi / 180.0 }

        var yaw: Double
        var method: GeoSolution.Method

        if fixes.count >= minimumFixesForYaw && baseline >= minimumBaselineForYaw {
            yaw = procrustesYaw(ar: ar, gps: gps, weights: weights)
            method = .gpsTrack
        } else if let compassYaw {
            yaw = compassYaw
            method = fixes.count > 1 ? .compass : .singleFix
        } else {
            yaw = 0
            method = fixes.count > 1 ? .compass : .singleFix
        }

        // Translation: with yaw fixed, the ENU position of the AR origin is the
        // weighted mean of (gps - R * ar).
        let c = cos(yaw), s = sin(yaw)
        var tEast = 0.0, tNorth = 0.0, tUp = 0.0
        for i in fixes.indices {
            let rx = c * ar[i].x - s * ar[i].y
            let ry = s * ar[i].x + c * ar[i].y
            tEast += weights[i] * (gps[i].east - rx)
            tNorth += weights[i] * (gps[i].north - ry)
            tUp += weights[i] * (gps[i].up - arUp[i])
        }
        tEast /= weightSum
        tNorth /= weightSum
        tUp /= weightSum

        // Residuals under the fitted transform.
        var hSum = 0.0, vSum = 0.0
        for i in fixes.indices {
            let rx = c * ar[i].x - s * ar[i].y + tEast
            let ry = s * ar[i].x + c * ar[i].y + tNorth
            let dh = (rx - gps[i].east) * (rx - gps[i].east) + (ry - gps[i].north) * (ry - gps[i].north)
            let dv = (arUp[i] + tUp) - gps[i].up
            hSum += dh
            vSum += dv * dv
        }
        let n = Double(fixes.count)
        let horizontalRMSE = (hSum / n).squareRoot()
        let verticalRMSE = (vSum / n).squareRoot()

        let origin = Geodesy.geodetic(enu: ENU(east: tEast, north: tNorth, up: tUp), from: provisional)

        return GeoSolution(origin: origin,
                           yaw: yaw,
                           method: method,
                           fixCount: fixes.count,
                           horizontalRMSE: horizontalRMSE,
                           verticalRMSE: verticalRMSE,
                           bestFixAccuracy: bestAccuracy,
                           baselineLength: baseline,
                           solvedAt: Date())
    }

    // MARK: - Maths

    /// Weighted 2-D Procrustes rotation (no scale) taking `ar` onto `gps`.
    private static func procrustesYaw(ar: [SIMD2<Double>], gps: [ENU], weights: [Double]) -> Double {
        let weightSum = weights.reduce(0, +)
        var arMean = SIMD2<Double>(0, 0)
        var gpsMean = SIMD2<Double>(0, 0)
        for i in ar.indices {
            arMean += ar[i] * weights[i]
            gpsMean += SIMD2(gps[i].east, gps[i].north) * weights[i]
        }
        arMean /= weightSum
        gpsMean /= weightSum

        var cross = 0.0   // sum w * (a x b)
        var dot = 0.0     // sum w * (a . b)
        for i in ar.indices {
            let a = ar[i] - arMean
            let b = SIMD2(gps[i].east, gps[i].north) - gpsMean
            cross += weights[i] * (a.x * b.y - a.y * b.x)
            dot += weights[i] * (a.x * b.x + a.y * b.y)
        }
        return atan2(cross, dot)
    }

    /// Diagonal of the bounding box of the walked path.
    private static func pathExtent(_ points: [SIMD2<Double>]) -> Double {
        guard let first = points.first else { return 0 }
        var minP = first, maxP = first
        for p in points {
            minP = SIMD2(Swift.min(minP.x, p.x), Swift.min(minP.y, p.y))
            maxP = SIMD2(Swift.max(maxP.x, p.x), Swift.max(maxP.y, p.y))
        }
        let d = maxP - minP
        return (d.x * d.x + d.y * d.y).squareRoot()
    }
}
