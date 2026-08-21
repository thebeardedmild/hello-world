//
//  PointCloudAccumulator.swift
//
//  Owns the GPU-resident point buffer and the compute pass that fills it.
//
//  The buffer is shared-storage, so the same memory the shader appends to is
//  directly readable by the CPU for picking, filtering and export — no copies, no
//  staging, and picking a measurement point never stalls the render loop.
//

import Foundation
import Metal
import ARKit
import simd

final class PointCloudAccumulator {

    enum State {
        case idle
        case accumulating
        case compacting
        case full
    }

    private(set) var state: State = .idle

    let device: MTLDevice
    private let pipeline: MTLComputePipelineState
    private(set) var capacity: Int

    /// GSPoint records. Shared storage: CPU and GPU see the same bytes.
    private(set) var pointBuffer: MTLBuffer
    /// A single atomic uint the shader appends through.
    private let countBuffer: MTLBuffer

    private var uniformBuffer: MTLBuffer

    /// Points written since the last reset, saturating at `capacity`.
    private(set) var count: Int = 0
    /// Points seen before compaction ever ran, for the statistics panel.
    private(set) var rawCount: Int = 0
    private(set) var compactionCount: Int = 0

    private let processingQueue = DispatchQueue(label: "com.geoscan.compaction", qos: .userInitiated)
    private var pendingCompaction: [GSPoint]?
    private let pendingLock = NSLock()

    init?(device: MTLDevice, library: MTLLibrary, capacity: Int) {
        guard let function = library.makeFunction(name: "unprojectKernel"),
              let pipeline = try? device.makeComputePipelineState(function: function) else {
            return nil
        }
        let byteCount = capacity * MemoryLayout<GSPoint>.stride
        guard let pointBuffer = device.makeBuffer(length: byteCount, options: .storageModeShared),
              let countBuffer = device.makeBuffer(length: MemoryLayout<UInt32>.stride, options: .storageModeShared),
              let uniformBuffer = device.makeBuffer(length: MemoryLayout<GSUnprojectUniforms>.stride,
                                                    options: .storageModeShared) else {
            return nil
        }
        self.device = device
        self.pipeline = pipeline
        self.capacity = capacity
        self.pointBuffer = pointBuffer
        self.countBuffer = countBuffer
        self.uniformBuffer = uniformBuffer
        pointBuffer.label = "GeoScan.points"
        resetCounter()
    }

    // MARK: - Buffer access

    var points: UnsafeMutablePointer<GSPoint> {
        pointBuffer.contents().assumingMemoryBound(to: GSPoint.self)
    }

    private var counter: UnsafeMutablePointer<UInt32> {
        countBuffer.contents().assumingMemoryBound(to: UInt32.self)
    }

    private func resetCounter() {
        counter.pointee = 0
        count = 0
    }

    func reset() {
        resetCounter()
        rawCount = 0
        compactionCount = 0
        state = .idle
        pendingLock.lock(); pendingCompaction = nil; pendingLock.unlock()
    }

    /// Copy the live cloud out for filtering, picking or export.
    func snapshot() -> [GSPoint] {
        let n = min(count, capacity)
        guard n > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: points, count: n))
    }

    /// A strided sample, for cheap operations that do not need every point.
    func snapshot(maxPoints: Int) -> [GSPoint] {
        let n = min(count, capacity)
        guard n > 0 else { return [] }
        if n <= maxPoints { return snapshot() }
        let stride = n / maxPoints + 1
        var out = [GSPoint]()
        out.reserveCapacity(maxPoints + 1)
        var i = 0
        while i < n { out.append(points[i]); i += stride }
        return out
    }

    var bounds: PointCloudBounds {
        var b = PointCloudBounds.empty
        let n = min(count, capacity)
        var i = 0
        // Bounds only need a representative sample; walking 6M points every frame
        // for a HUD readout is not a good trade.
        let stride = max(1, n / 20_000)
        while i < n {
            let p = points[i]
            if p.isFinite { b.expand(p.position) }
            i += stride
        }
        return b
    }

    // MARK: - Accumulation

    /// Encodes one unprojection pass. Call from the render loop, on the thread
    /// that owns the command buffer.
    func encode(into commandBuffer: MTLCommandBuffer,
                frame: ARFrame,
                depth: MTLTexture,
                confidence: MTLTexture,
                y: MTLTexture,
                cbcr: MTLTexture,
                settings: ScanSettings) {
        guard state == .accumulating else { return }

        let depthWidth = depth.width
        let depthHeight = depth.height
        let imageResolution = frame.camera.imageResolution
        guard depthWidth > 0, depthHeight > 0,
              imageResolution.width > 0, imageResolution.height > 0 else { return }

        // Rescale the colour-camera intrinsics to the depth map's resolution.
        let sx = Float(Double(depthWidth) / imageResolution.width)
        let sy = Float(Double(depthHeight) / imageResolution.height)
        var k = frame.camera.intrinsics
        k.columns.0.x *= sx
        k.columns.1.y *= sy
        k.columns.2.x *= sx
        k.columns.2.y *= sy

        // ARKit camera space is +x right, +y up, -z forward; the unprojection
        // works in image convention, so fold the axis flip into the transform.
        let flip = simd_float4x4(SIMD4(1, 0, 0, 0), SIMD4(0, -1, 0, 0), SIMD4(0, 0, -1, 0), SIMD4(0, 0, 0, 1))

        var uniforms = GSUnprojectUniforms(
            localToWorld: frame.camera.transform * flip,
            depthIntrinsicsInverse: k.inverse,
            depthResolution: SIMD2(Float(depthWidth), Float(depthHeight)),
            minRange: settings.minRange,
            maxRange: settings.maxRange,
            minConfidence: UInt32(max(0, min(2, settings.minConfidence))),
            capacity: UInt32(capacity),
            sampleStride: UInt32(max(1, settings.sampleStride)),
            _pad: 0)
        memcpy(uniformBuffer.contents(), &uniforms, MemoryLayout<GSUnprojectUniforms>.size)

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.label = "Unproject"
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(uniformBuffer, offset: 0, index: GSBuffer.unprojectUniforms)
        encoder.setBuffer(pointBuffer, offset: 0, index: GSBuffer.points)
        encoder.setBuffer(countBuffer, offset: 0, index: GSBuffer.pointCount)
        encoder.setTexture(depth, index: GSTexture.depth)
        encoder.setTexture(confidence, index: GSTexture.confidence)
        encoder.setTexture(y, index: GSTexture.y)
        encoder.setTexture(cbcr, index: GSTexture.cbcr)

        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroups = MTLSize(width: (depthWidth + 15) / 16,
                                   height: (depthHeight + 15) / 16,
                                   depth: 1)
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()
    }

    /// Refresh `count` from the GPU counter. Call once per frame after the
    /// command buffer for the previous frame has completed.
    func refreshCount() {
        let written = Int(counter.pointee)
        rawCount = max(rawCount, written)
        if written >= capacity {
            count = capacity
            counter.pointee = UInt32(capacity)
            if state == .accumulating { state = .full }
        } else {
            count = written
        }
    }

    var fillFraction: Double {
        capacity > 0 ? Double(count) / Double(capacity) : 0
    }

    // MARK: - Control

    func startAccumulating() {
        guard state != .compacting else { return }
        state = .accumulating
    }

    func pauseAccumulating() {
        guard state == .accumulating else { return }
        state = .idle
    }

    // MARK: - Compaction
    //
    // When the buffer fills, voxel-filtering in place typically recovers 50-80%
    // of it, so a long scan degrades in resolution rather than simply stopping.

    var shouldCompact: Bool {
        state != .compacting && fillFraction > 0.92
    }

    /// Kick off a compaction. Safe to call from the render thread: accumulation
    /// stops immediately and the filtered result is swapped in on a later frame.
    func beginCompaction(leafSize: Float, completion: ((Int) -> Void)? = nil) {
        guard state != .compacting else { return }
        state = .compacting
        let snapshotCount = min(count, capacity)
        let source = Array(UnsafeBufferPointer(start: points, count: snapshotCount))

        processingQueue.async { [weak self] in
            guard let self else { return }
            let filtered = VoxelGridFilter.filter(source, leafSize: leafSize)
            self.pendingLock.lock()
            self.pendingCompaction = filtered
            self.pendingLock.unlock()
            completion?(filtered.count)
        }
    }

    /// Swap in a finished compaction. Render thread only.
    /// - Returns: true when a swap happened.
    @discardableResult
    func applyPendingCompaction(resumeAccumulating: Bool) -> Bool {
        pendingLock.lock()
        let filtered = pendingCompaction
        pendingCompaction = nil
        pendingLock.unlock()

        guard let filtered else { return false }
        let n = min(filtered.count, capacity)
        filtered.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            pointBuffer.contents().copyMemory(from: base, byteCount: n * MemoryLayout<GSPoint>.stride)
        }
        counter.pointee = UInt32(n)
        count = n
        compactionCount += 1
        state = resumeAccumulating ? .accumulating : .idle
        return true
    }

    /// Overwrite the buffer wholesale — used when loading a saved scan.
    func load(_ newPoints: [GSPoint]) {
        let n = min(newPoints.count, capacity)
        newPoints.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            pointBuffer.contents().copyMemory(from: base, byteCount: n * MemoryLayout<GSPoint>.stride)
        }
        counter.pointee = UInt32(n)
        count = n
        rawCount = max(rawCount, n)
        state = .idle
    }
}
