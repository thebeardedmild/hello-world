//
//  VoxelGridFilter.swift
//
//  The live cloud is deliberately redundant: every frame re-observes surfaces the
//  last one already saw, which is what makes the colour average out nicely but
//  also means a two-minute scan holds the same wall a hundred times over.
//
//  A voxel grid fixes that in one linear pass: quantise to a lattice, average the
//  positions and colours that land in each cell, keep the best confidence. The
//  output has uniform density, which is exactly what you want both for measuring
//  and for every downstream tool that expects a survey-grade cloud.
//

import Foundation
import simd

enum VoxelGridFilter {

    /// Downsample to one point per `leafSize` cube.
    /// - Parameter minPointsPerVoxel: cells with fewer observations than this are
    ///   dropped, which sweeps out most single-frame speckle for free.
    static func filter(_ points: [GSPoint],
                       leafSize: Float,
                       minPointsPerVoxel: Int = 1,
                       progress: ((Double) -> Void)? = nil) -> [GSPoint] {
        guard leafSize > 0, !points.isEmpty else { return points }
        let inverseLeaf = 1.0 / leafSize

        // Parallel arrays keyed by a dense slot index; the dictionary only maps
        // lattice key -> slot, so we never store a struct inside the hash table.
        var slotForKey = [Int64: Int32]()
        slotForKey.reserveCapacity(min(points.count, 1 << 21))

        var sumX = [Float](), sumY = [Float](), sumZ = [Float]()
        var sumR = [Int32](), sumG = [Int32](), sumB = [Int32]()
        var counts = [Int32](), bestConfidence = [UInt8]()

        let reserve = min(points.count / 4 + 16, 4_000_000)
        sumX.reserveCapacity(reserve); sumY.reserveCapacity(reserve); sumZ.reserveCapacity(reserve)
        sumR.reserveCapacity(reserve); sumG.reserveCapacity(reserve); sumB.reserveCapacity(reserve)
        counts.reserveCapacity(reserve); bestConfidence.reserveCapacity(reserve)

        let reportEvery = max(1, points.count / 50)

        for (i, p) in points.enumerated() {
            guard p.isFinite else { continue }
            let key = SpatialHashGrid.key(Int64(floor(p.x * inverseLeaf)),
                                          Int64(floor(p.y * inverseLeaf)),
                                          Int64(floor(p.z * inverseLeaf)))
            if let slot = slotForKey[key] {
                let s = Int(slot)
                sumX[s] += p.x; sumY[s] += p.y; sumZ[s] += p.z
                sumR[s] += Int32(p.r); sumG[s] += Int32(p.g); sumB[s] += Int32(p.b)
                counts[s] += 1
                if p.confidence > bestConfidence[s] { bestConfidence[s] = p.confidence }
            } else {
                slotForKey[key] = Int32(sumX.count)
                sumX.append(p.x); sumY.append(p.y); sumZ.append(p.z)
                sumR.append(Int32(p.r)); sumG.append(Int32(p.g)); sumB.append(Int32(p.b))
                counts.append(1)
                bestConfidence.append(p.confidence)
            }
            if i % reportEvery == 0 { progress?(Double(i) / Double(points.count)) }
        }

        var output = [GSPoint]()
        output.reserveCapacity(sumX.count)
        for s in 0..<sumX.count {
            let n = counts[s]
            guard Int(n) >= minPointsPerVoxel else { continue }
            let inv = 1.0 / Float(n)
            output.append(GSPoint(x: sumX[s] * inv,
                                  y: sumY[s] * inv,
                                  z: sumZ[s] * inv,
                                  r: UInt8(clamping: Int(sumR[s] / n)),
                                  g: UInt8(clamping: Int(sumG[s] / n)),
                                  b: UInt8(clamping: Int(sumB[s] / n)),
                                  confidence: bestConfidence[s]))
        }
        progress?(1.0)
        return output
    }
}

enum OutlierFilter {

    /// Statistical outlier removal. For every point, take the mean distance to
    /// its `k` nearest neighbours; drop the points whose mean sits more than
    /// `standardDeviations` above the cloud-wide mean.
    ///
    /// Run this *after* voxel filtering — on a uniform cloud the distance
    /// distribution is tight, so the threshold actually means something, and
    /// there are far fewer points to walk.
    static func removeOutliers(_ points: [GSPoint],
                               neighbors k: Int = 8,
                               standardDeviations: Float = 2.0,
                               searchRadius: Float = 0.10,
                               progress: ((Double) -> Void)? = nil) -> [GSPoint] {
        guard points.count > k * 4, k > 0 else { return points }

        let grid = SpatialHashGrid(points: points, cellSize: max(searchRadius, 0.02))
        var meanDistances = [Float](repeating: .nan, count: points.count)

        // Chunked concurrency: one closure per core, each walking a contiguous
        // slice, so the grid stays read-only and no locking is needed.
        let chunkCount = min(ProcessInfo.processInfo.activeProcessorCount, 8)
        let chunkSize = (points.count + chunkCount - 1) / chunkCount

        meanDistances.withUnsafeMutableBufferPointer { buffer in
            // Take the base address out of the inout buffer before the closure,
            // so the concurrent workers capture a plain pointer.
            guard let out = buffer.baseAddress else { return }
            DispatchQueue.concurrentPerform(iterations: chunkCount) { chunk in
                let start = chunk * chunkSize
                let end = min(start + chunkSize, points.count)
                guard start < end else { return }
                var heap = [Float]()
                heap.reserveCapacity(k + 1)
                for i in start..<end {
                    let p = points[i].position
                    let candidates = grid.indices(near: p, radius: searchRadius)
                    heap.removeAll(keepingCapacity: true)
                    for c in candidates {
                        let j = Int(c)
                        if j == i { continue }
                        let d = simd_distance(p, points[j].position)
                        if d > searchRadius { continue }
                        // Insertion into a bounded, sorted list of the k smallest.
                        if heap.count < k {
                            heap.append(d)
                            heap.sort()
                        } else if d < heap[k - 1] {
                            heap[k - 1] = d
                            heap.sort()
                        }
                    }
                    out[i] = heap.isEmpty ? .nan : heap.reduce(0, +) / Float(heap.count)
                }
            }
        }
        progress?(0.7)

        // Points with no neighbour inside the search radius are flyers by
        // definition, so they are dropped without entering the statistics.
        var sum: Double = 0
        var validCount = 0
        for d in meanDistances where d.isFinite { sum += Double(d); validCount += 1 }
        guard validCount > 0 else { return points }
        let mean = sum / Double(validCount)

        var variance: Double = 0
        for d in meanDistances where d.isFinite { variance += (Double(d) - mean) * (Double(d) - mean) }
        let sigma = (variance / Double(validCount)).squareRoot()
        let threshold = Float(mean + Double(standardDeviations) * sigma)

        var output = [GSPoint]()
        output.reserveCapacity(points.count)
        for i in points.indices {
            let d = meanDistances[i]
            if d.isFinite && d <= threshold { output.append(points[i]) }
        }
        progress?(1.0)
        return output
    }
}
