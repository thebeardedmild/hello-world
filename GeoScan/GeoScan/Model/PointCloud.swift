//
//  PointCloud.swift
//  CPU-side view over the packed GSPoint records the GPU produces.
//

import Foundation
import simd

extension GSPoint {
    init(position: SIMD3<Float>, color: SIMD3<UInt8>, confidence: UInt8) {
        self.init(x: position.x, y: position.y, z: position.z,
                  r: color.x, g: color.y, b: color.z, confidence: confidence)
    }

    var position: SIMD3<Float> {
        get { SIMD3(x, y, z) }
        set { x = newValue.x; y = newValue.y; z = newValue.z }
    }

    var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
}

struct PointCloudBounds: Equatable {
    var min: SIMD3<Float>
    var max: SIMD3<Float>

    var center: SIMD3<Float> { (min + max) * 0.5 }
    var extent: SIMD3<Float> { max - min }
    var radius: Float { simd_length(extent) * 0.5 }

    static let empty = PointCloudBounds(min: SIMD3(repeating: .greatestFiniteMagnitude),
                                        max: SIMD3(repeating: -.greatestFiniteMagnitude))

    var isEmpty: Bool { min.x > max.x }

    mutating func expand(_ p: SIMD3<Float>) {
        min = simd_min(min, p)
        max = simd_max(max, p)
    }

    static func compute(_ points: [GSPoint]) -> PointCloudBounds {
        var b = PointCloudBounds.empty
        for p in points where p.isFinite { b.expand(p.position) }
        return b
    }
}

/// An immutable snapshot of a cloud, plus lazily-built acceleration structures.
final class PointCloud {
    private(set) var points: [GSPoint]
    private(set) var bounds: PointCloudBounds

    init(points: [GSPoint]) {
        self.points = points
        self.bounds = PointCloudBounds.compute(points)
    }

    var count: Int { points.count }
    var isEmpty: Bool { points.isEmpty }

    /// Built on first pick; ~0.4 s for 6M points, then every query is O(cells).
    private var index: SpatialHashGrid?

    func spatialIndex(cellSize: Float = 0.15) -> SpatialHashGrid {
        if let index, index.cellSize == cellSize { return index }
        let built = SpatialHashGrid(points: points, cellSize: cellSize)
        index = built
        return built
    }

    func invalidateIndex() { index = nil }

    func replacing(points newPoints: [GSPoint]) -> PointCloud {
        PointCloud(points: newPoints)
    }
}

/// Uniform-grid spatial hash. A k-d tree would be tighter, but this builds in a
/// single linear pass, needs no rebalancing, and the queries we run (ray cones
/// and radius neighbourhoods) are exactly what a uniform grid is good at.
final class SpatialHashGrid {
    let cellSize: Float
    private let inverseCellSize: Float
    /// Cell key -> indices into the source point array.
    private var cells: [Int64: [Int32]] = [:]
    private let pointCount: Int

    init(points: [GSPoint], cellSize: Float) {
        self.cellSize = cellSize
        self.inverseCellSize = 1.0 / cellSize
        self.pointCount = points.count
        cells.reserveCapacity(max(1024, points.count / 24))
        for (i, p) in points.enumerated() where p.isFinite {
            cells[SpatialHashGrid.key(for: p.position, inverseCellSize: inverseCellSize), default: []]
                .append(Int32(i))
        }
    }

    static func key(for p: SIMD3<Float>, inverseCellSize: Float) -> Int64 {
        let ix = Int64(floor(p.x * inverseCellSize))
        let iy = Int64(floor(p.y * inverseCellSize))
        let iz = Int64(floor(p.z * inverseCellSize))
        return SpatialHashGrid.key(ix, iy, iz)
    }

    /// Morton-ish mix of three 21-bit cell coordinates. Collisions are possible
    /// in principle but need a cloud spanning ~150 km at 15 cm cells.
    static func key(_ x: Int64, _ y: Int64, _ z: Int64) -> Int64 {
        let m: Int64 = 0x1F_FFFF
        return ((x & m) << 42) | ((y & m) << 21) | (z & m)
    }

    func indices(inCellContaining p: SIMD3<Float>) -> [Int32] {
        cells[SpatialHashGrid.key(for: p, inverseCellSize: inverseCellSize)] ?? []
    }

    /// Indices in every cell overlapping the sphere (p, radius).
    func indices(near p: SIMD3<Float>, radius: Float) -> [Int32] {
        let r = Int64(ceil(radius * inverseCellSize))
        let cx = Int64(floor(p.x * inverseCellSize))
        let cy = Int64(floor(p.y * inverseCellSize))
        let cz = Int64(floor(p.z * inverseCellSize))
        var result: [Int32] = []
        var dz = -r
        while dz <= r {
            var dy = -r
            while dy <= r {
                var dx = -r
                while dx <= r {
                    if let bucket = cells[SpatialHashGrid.key(cx + dx, cy + dy, cz + dz)] {
                        result.append(contentsOf: bucket)
                    }
                    dx += 1
                }
                dy += 1
            }
            dz += 1
        }
        return result
    }

    /// Cells pierced by a ray, walked front to back in fixed steps of one cell.
    /// `radius` widens the walk so a ray grazing a cell corner still sees it.
    func indices(alongRay origin: SIMD3<Float>, direction: SIMD3<Float>,
                 maxDistance: Float, radius: Float) -> [Int32] {
        var seen = Set<Int64>()
        var result: [Int32] = []
        let step = cellSize * 0.5
        var t: Float = 0
        let widen = Int64(ceil(radius * inverseCellSize))
        while t <= maxDistance {
            let p = origin + direction * t
            let cx = Int64(floor(p.x * inverseCellSize))
            let cy = Int64(floor(p.y * inverseCellSize))
            let cz = Int64(floor(p.z * inverseCellSize))
            var dz = -widen
            while dz <= widen {
                var dy = -widen
                while dy <= widen {
                    var dx = -widen
                    while dx <= widen {
                        let k = SpatialHashGrid.key(cx + dx, cy + dy, cz + dz)
                        if seen.insert(k).inserted, let bucket = cells[k] {
                            result.append(contentsOf: bucket)
                        }
                        dx += 1
                    }
                    dy += 1
                }
                dz += 1
            }
            t += step
        }
        return result
    }
}
