//
//  SiteMeasurement.swift
//
//  A measurement is a list of world-space vertices plus a kind. Every derived
//  number (length, run, rise, area, bearing) is computed on demand, so a scan
//  that gets re-georeferenced later reports new bearings and coordinates without
//  any migration.
//
//  Every vertex carries the one-sigma position uncertainty estimated when it was
//  picked, and that is propagated into the result. A measurement app that shows
//  three decimal places and no error bar is lying to you.
//

import Foundation
import simd

struct MeasurementVertex: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    /// AR world space, metres.
    var world: SIMD3<Float>
    /// One-sigma position uncertainty in metres, from the picker.
    var sigma: Float
    /// How the point was obtained, for the audit trail.
    var source: Source

    enum Source: String, Codable {
        case meshRaycast   // snapped to the ARKit scene mesh
        case planeFit      // local plane fit through nearby cloud points
        case nearestPoint  // raw nearest point along the ray
        case manual        // typed in / dragged
    }
}

enum MeasurementKind: String, Codable, CaseIterable, Identifiable {
    case distance
    case polyline
    case area
    case height

    var id: String { rawValue }

    var title: String {
        switch self {
        case .distance: return "Distance"
        case .polyline: return "Path"
        case .area: return "Area"
        case .height: return "Height"
        }
    }

    var symbolName: String {
        switch self {
        case .distance: return "ruler"
        case .polyline: return "point.topleft.down.curvedto.point.bottomright.up"
        case .area: return "square.dashed"
        case .height: return "arrow.up.and.down"
        }
    }

    var requiredVertices: Int {
        switch self {
        case .distance, .height: return 2
        case .polyline: return 2
        case .area: return 3
        }
    }

    var acceptsMoreVertices: Bool {
        switch self {
        case .distance, .height: return false
        case .polyline, .area: return true
        }
    }
}

struct MeasurementResult {
    /// Straight-line or cumulative length, metres. NaN for area-only results.
    var length: Double
    /// Horizontal component (plan distance), metres.
    var horizontal: Double
    /// Vertical component (rise), metres — signed for a two-point measurement.
    var vertical: Double
    /// Planar area, square metres. NaN unless the kind is `.area`.
    var area: Double
    /// One-sigma uncertainty of the headline value, metres (or m² for area).
    var sigma: Double
    /// Planarity RMS for an area measurement — how far the picked ring is from
    /// being flat. Large values mean the area number is not meaningful.
    var planarityRMS: Double
}

struct SiteMeasurement: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var kind: MeasurementKind
    var vertices: [MeasurementVertex]
    var label: String = ""
    var note: String = ""
    var createdAt: Date = Date()
    /// IDs of photo notes the operator explicitly linked to this measurement.
    var linkedPhotoIDs: [UUID] = []

    var isComplete: Bool { vertices.count >= kind.requiredVertices }

    var displayName: String {
        if !label.isEmpty { return label }
        return kind.title
    }

    // MARK: - Derived geometry

    var result: MeasurementResult {
        switch kind {
        case .distance:
            return SiteMeasurement.segmentResult(vertices)
        case .height:
            var r = SiteMeasurement.segmentResult(vertices)
            r.length = abs(r.vertical)
            return r
        case .polyline:
            return SiteMeasurement.polylineResult(vertices)
        case .area:
            return SiteMeasurement.areaResult(vertices)
        }
    }

    /// The headline value, formatted for the HUD.
    var primaryText: String {
        let r = result
        switch kind {
        case .area:
            guard r.area.isFinite else { return "—" }
            return SiteMeasurement.formatArea(r.area)
        default:
            guard r.length.isFinite else { return "—" }
            return SiteMeasurement.formatLength(r.length)
        }
    }

    var uncertaintyText: String? {
        let r = result
        guard r.sigma.isFinite, r.sigma > 0 else { return nil }
        if kind == .area {
            return String(format: "± %.2f m²", r.sigma)
        }
        return String(format: "± %.0f mm", r.sigma * 1000)
    }

    // MARK: - Maths

    private static func segmentResult(_ v: [MeasurementVertex]) -> MeasurementResult {
        guard v.count >= 2 else {
            return MeasurementResult(length: .nan, horizontal: .nan, vertical: .nan,
                                     area: .nan, sigma: .nan, planarityRMS: .nan)
        }
        let a = v[0].world, b = v[1].world
        let d = b - a
        let length = Double(simd_length(d))
        let horizontal = Double((d.x * d.x + d.z * d.z).squareRoot())
        let vertical = Double(d.y)
        let sigma = Double((v[0].sigma * v[0].sigma + v[1].sigma * v[1].sigma).squareRoot())
        return MeasurementResult(length: length, horizontal: horizontal, vertical: vertical,
                                 area: .nan, sigma: sigma, planarityRMS: .nan)
    }

    private static func polylineResult(_ v: [MeasurementVertex]) -> MeasurementResult {
        guard v.count >= 2 else {
            return MeasurementResult(length: .nan, horizontal: .nan, vertical: .nan,
                                     area: .nan, sigma: .nan, planarityRMS: .nan)
        }
        var length = 0.0, horizontal = 0.0
        var variance = 0.0
        for i in 1..<v.count {
            let d = v[i].world - v[i - 1].world
            length += Double(simd_length(d))
            horizontal += Double((d.x * d.x + d.z * d.z).squareRoot())
            // Segment errors are dominated by independent per-pick noise, so the
            // variances add rather than the sigmas.
            variance += Double(v[i].sigma * v[i].sigma + v[i - 1].sigma * v[i - 1].sigma)
        }
        let vertical = Double(v[v.count - 1].world.y - v[0].world.y)
        return MeasurementResult(length: length, horizontal: horizontal, vertical: vertical,
                                 area: .nan, sigma: variance.squareRoot(), planarityRMS: .nan)
    }

    /// Newell's method: works for any simple polygon in 3-D and gives the best-fit
    /// plane normal for free, which we reuse to report how planar the ring is.
    private static func areaResult(_ v: [MeasurementVertex]) -> MeasurementResult {
        guard v.count >= 3 else {
            return MeasurementResult(length: .nan, horizontal: .nan, vertical: .nan,
                                     area: .nan, sigma: .nan, planarityRMS: .nan)
        }
        var normal = SIMD3<Float>(repeating: 0)
        var perimeter = 0.0
        for i in 0..<v.count {
            let a = v[i].world
            let b = v[(i + 1) % v.count].world
            normal.x += (a.y - b.y) * (a.z + b.z)
            normal.y += (a.z - b.z) * (a.x + b.x)
            normal.z += (a.x - b.x) * (a.y + b.y)
            perimeter += Double(simd_length(b - a))
        }
        let area = Double(simd_length(normal)) * 0.5

        // Planarity: RMS distance of the vertices from the fitted plane.
        var planarity = 0.0
        if simd_length(normal) > 1e-6 {
            let n = simd_normalize(normal)
            var centroid = SIMD3<Float>(repeating: 0)
            for vertex in v { centroid += vertex.world }
            centroid /= Float(v.count)
            for vertex in v {
                let d = Double(simd_dot(vertex.world - centroid, n))
                planarity += d * d
            }
            planarity = (planarity / Double(v.count)).squareRoot()
        }

        // First-order propagation: each vertex perturbs the area by roughly
        // sigma * (half the length of its two adjacent edges).
        var areaVariance = 0.0
        for i in 0..<v.count {
            let prev = v[(i + v.count - 1) % v.count].world
            let next = v[(i + 1) % v.count].world
            let lever = Double(simd_length(next - prev)) * 0.5
            let s = Double(v[i].sigma) * lever
            areaVariance += s * s
        }

        return MeasurementResult(length: perimeter,
                                 horizontal: .nan,
                                 vertical: .nan,
                                 area: area,
                                 sigma: areaVariance.squareRoot(),
                                 planarityRMS: planarity)
    }

    // MARK: - Formatting

    static func formatLength(_ meters: Double) -> String {
        guard meters.isFinite else { return "—" }
        if abs(meters) < 1.0 { return String(format: "%.0f mm", meters * 1000) }
        return String(format: "%.3f m", meters)
    }

    static func formatArea(_ squareMeters: Double) -> String {
        guard squareMeters.isFinite else { return "—" }
        if squareMeters < 1.0 { return String(format: "%.0f cm²", squareMeters * 10_000) }
        return String(format: "%.3f m²", squareMeters)
    }
}
