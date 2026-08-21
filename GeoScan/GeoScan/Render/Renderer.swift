//
//  Renderer.swift
//
//  One renderer, two modes.
//
//  Live: draws the camera feed, runs the unprojection kernel on the current
//  ARFrame, then draws everything accumulated so far on top — so the operator
//  literally paints the cloud onto the world as they walk.
//
//  Review: no AR session, no camera feed. The same point pipeline, driven by an
//  orbit camera, over a cloud loaded from disk.
//
//  Both publish the view-projection matrix they used, which is what lets the
//  SwiftUI overlay put measurement labels and photo pins in the right place.
//

import Foundation
import Metal
import MetalKit
import ARKit
import UIKit
import simd

@MainActor
final class Renderer: NSObject, MTKViewDelegate {

    enum Mode {
        case live
        case review
    }

    // MARK: - Metal

    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let library: MTLLibrary
    private var backgroundPipeline: MTLRenderPipelineState?
    private var pointPipeline: MTLRenderPipelineState?
    private var depthState: MTLDepthStencilState?
    private var textureCache: CVMetalTextureCache?

    /// Kept alive for the lifetime of the frame that uses them.
    private var frameTextures: [CVMetalTexture] = []
    private var backgroundUVBuffer: MTLBuffer?
    private var renderUniformBuffer: MTLBuffer?

    private(set) var accumulator: PointCloudAccumulator?

    // MARK: - Configuration

    var mode: Mode = .live
    weak var scanController: ScanController?
    let orbitCamera = OrbitCamera()
    /// Review mode only: the cloud to draw, uploaded to `accumulator`.
    private(set) var reviewCloud: PointCloud?

    var colorMode: PointColorMode = .rgb
    var minConfidence: UInt8 = 0
    var pointSizeScale: Float = 1.0
    var showsCameraFeed = true

    /// Latest matrices, for hit testing and overlays.
    private(set) var viewProjection: simd_float4x4 = matrix_identity_float4x4
    private(set) var eyePosition: SIMD3<Float> = .zero
    private(set) var viewSize: CGSize = .zero

    /// Called after each frame with the live point count, for the HUD.
    var onFrame: ((Int) -> Void)?

    private var heightRange: SIMD2<Float> = SIMD2(0, 3)
    private var framesSinceHeightUpdate = 0

    // MARK: - Init

    init?(device: MTLDevice, view: MTKView, capacity: Int) {
        guard let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else { return nil }
        self.device = device
        self.commandQueue = queue
        self.library = library
        super.init()

        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.clearColor = MTLClearColor(red: 0.05, green: 0.06, blue: 0.08, alpha: 1)
        view.preferredFramesPerSecond = 60
        view.isOpaque = true

        guard buildPipelines(view: view) else { return nil }
        accumulator = PointCloudAccumulator(device: device, library: library, capacity: capacity)

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        textureCache = cache

        backgroundUVBuffer = device.makeBuffer(length: MemoryLayout<SIMD2<Float>>.stride * 4,
                                               options: .storageModeShared)
        renderUniformBuffer = device.makeBuffer(length: MemoryLayout<GSRenderUniforms>.stride,
                                                options: .storageModeShared)
    }

    private func buildPipelines(view: MTKView) -> Bool {
        let backgroundDescriptor = MTLRenderPipelineDescriptor()
        backgroundDescriptor.label = "CameraBackground"
        backgroundDescriptor.vertexFunction = library.makeFunction(name: "cameraBackgroundVertex")
        backgroundDescriptor.fragmentFunction = library.makeFunction(name: "cameraBackgroundFragment")
        backgroundDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        backgroundDescriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat

        let pointDescriptor = MTLRenderPipelineDescriptor()
        pointDescriptor.label = "PointCloud"
        pointDescriptor.vertexFunction = library.makeFunction(name: "pointCloudVertex")
        pointDescriptor.fragmentFunction = library.makeFunction(name: "pointCloudFragment")
        pointDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        pointDescriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        // Straight alpha blend, so the soft sprite edge does not cut a hard hole
        // in whatever is behind it.
        pointDescriptor.colorAttachments[0].isBlendingEnabled = true
        pointDescriptor.colorAttachments[0].rgbBlendOperation = .add
        pointDescriptor.colorAttachments[0].alphaBlendOperation = .add
        pointDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pointDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        pointDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pointDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true

        do {
            backgroundPipeline = try device.makeRenderPipelineState(descriptor: backgroundDescriptor)
            pointPipeline = try device.makeRenderPipelineState(descriptor: pointDescriptor)
            depthState = device.makeDepthStencilState(descriptor: depthDescriptor)
            return true
        } catch {
            assertionFailure("Pipeline creation failed: \(error)")
            return false
        }
    }

    // MARK: - Review mode

    func present(cloud: PointCloud) {
        reviewCloud = cloud
        accumulator?.load(cloud.points)
        orbitCamera.frame(bounds: cloud.bounds)
        if !cloud.bounds.isEmpty {
            heightRange = SIMD2(cloud.bounds.min.y, cloud.bounds.max.y)
        }
    }

    /// Live cloud as a pickable snapshot. Rebuilt on demand — the spatial index
    /// behind it is the expensive part, so callers should hold on to the result.
    func makeCloudSnapshot(maxPoints: Int = 3_000_000) -> PointCloud? {
        guard let accumulator, accumulator.count > 0 else { return reviewCloud }
        return PointCloud(points: accumulator.snapshot(maxPoints: maxPoints))
    }

    // MARK: - MTKViewDelegate

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        MainActor.assumeIsolated {
            viewSize = view.bounds.size
        }
    }

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated {
            render(in: view)
        }
    }

    private func render(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        viewSize = view.bounds.size
        frameTextures.removeAll(keepingCapacity: true)

        if let accumulator {
            accumulator.refreshCount()
            accumulator.applyPendingCompaction(resumeAccumulating: mode == .live && scanController?.phase == .scanning)
        }

        var backgroundReady = false
        if mode == .live {
            backgroundReady = prepareLiveFrame(view: view, commandBuffer: commandBuffer)
        } else {
            updateReviewCamera(view: view)
        }

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            commandBuffer.commit()
            return
        }
        encoder.label = "GeoScan"

        if backgroundReady && showsCameraFeed,
           let backgroundPipeline, let backgroundUVBuffer, frameTextures.count >= 2 {
            encoder.setRenderPipelineState(backgroundPipeline)
            encoder.setVertexBuffer(backgroundUVBuffer, offset: 0, index: 0)
            encoder.setFragmentTexture(CVMetalTextureGetTexture(frameTextures[0]),
                                       index: GSTexture.y)
            encoder.setFragmentTexture(CVMetalTextureGetTexture(frameTextures[1]),
                                       index: GSTexture.cbcr)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        drawPoints(encoder: encoder, contentScale: Float(view.contentScaleFactor))
        encoder.endEncoding()

        let retained = frameTextures
        commandBuffer.addCompletedHandler { _ in
            // Hold the CVMetalTexture wrappers until the GPU is finished; the
            // texture cache will happily recycle the backing IOSurface otherwise.
            _ = retained
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()

        onFrame?(accumulator?.count ?? 0)
    }

    // MARK: - Live frame

    private func prepareLiveFrame(view: MTKView, commandBuffer: MTLCommandBuffer) -> Bool {
        guard let controller = scanController,
              let frame = controller.session.currentFrame,
              let textureCache else { return false }

        let orientation = view.window?.windowScene?.interfaceOrientation ?? .portrait

        // Camera matrices come straight from ARKit so the cloud lands exactly on
        // the video, whatever the interface orientation.
        let projection = frame.camera.projectionMatrix(for: orientation,
                                                       viewportSize: view.bounds.size,
                                                       zNear: 0.01,
                                                       zFar: 200)
        let viewMatrix = frame.camera.viewMatrix(for: orientation)
        viewProjection = projection * viewMatrix
        eyePosition = frame.camera.transform.position

        guard let y = makeTexture(from: frame.capturedImage, plane: 0, format: .r8Unorm),
              let cbcr = makeTexture(from: frame.capturedImage, plane: 1, format: .rg8Unorm) else {
            return false
        }
        frameTextures.append(y)
        frameTextures.append(cbcr)
        updateBackgroundUVs(frame: frame, orientation: orientation, viewSize: view.bounds.size)

        // Depth path: prefer the smoothed map for a calmer cloud, but fall back
        // to the raw one — smoothing lags a fast pan by a frame or two.
        let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth
        if let depthData,
           let accumulator,
           let confidenceMap = depthData.confidenceMap,
           controller.shouldAccumulate(frame: frame),
           let depthTexture = makeTexture(from: depthData.depthMap, plane: 0, format: .r32Float),
           let confidenceTexture = makeTexture(from: confidenceMap, plane: 0, format: .r8Uint) {
            frameTextures.append(depthTexture)
            frameTextures.append(confidenceTexture)
            if let depth = CVMetalTextureGetTexture(depthTexture),
               let confidence = CVMetalTextureGetTexture(confidenceTexture),
               let yTexture = CVMetalTextureGetTexture(y),
               let cbcrTexture = CVMetalTextureGetTexture(cbcr) {
                accumulator.encode(into: commandBuffer,
                                   frame: frame,
                                   depth: depth,
                                   confidence: confidence,
                                   y: yTexture,
                                   cbcr: cbcrTexture,
                                   settings: controller.settings)
            }
        }

        if let accumulator, accumulator.shouldCompact {
            if controller.settings.autoCompact {
                accumulator.beginCompaction(leafSize: controller.settings.voxelLeafSize)
            } else {
                accumulator.pauseAccumulating()
            }
        }

        // The height ramp needs a range; recomputing it every frame is wasteful.
        framesSinceHeightUpdate += 1
        if colorMode == .height, framesSinceHeightUpdate > 30 {
            framesSinceHeightUpdate = 0
            if let bounds = accumulator?.bounds, !bounds.isEmpty {
                heightRange = SIMD2(bounds.min.y, bounds.max.y)
            }
        }

        return true
    }

    private func updateReviewCamera(view: MTKView) {
        let size = view.bounds.size
        let aspect = Float(max(size.width, 1) / max(size.height, 1))
        viewProjection = orbitCamera.projectionMatrix(aspect: aspect) * orbitCamera.viewMatrix()
        eyePosition = orbitCamera.position
    }

    // MARK: - Drawing

    private func drawPoints(encoder: MTLRenderCommandEncoder, contentScale: Float) {
        guard let pointPipeline, let accumulator, let renderUniformBuffer,
              accumulator.count > 0 else { return }

        var uniforms = GSRenderUniforms(viewProjection: viewProjection,
                                        cameraPosition: eyePosition,
                                        pointSize: pointSize(contentScale: contentScale),
                                        minConfidence: Float(minConfidence),
                                        colorMode: colorMode.rawValue,
                                        heightMin: heightRange.x,
                                        heightMax: heightRange.y)
        memcpy(renderUniformBuffer.contents(), &uniforms, MemoryLayout<GSRenderUniforms>.size)

        encoder.setRenderPipelineState(pointPipeline)
        if let depthState { encoder.setDepthStencilState(depthState) }
        encoder.setVertexBuffer(accumulator.pointBuffer, offset: 0,
                                index: GSBuffer.points)
        encoder.setVertexBuffer(renderUniformBuffer, offset: 0,
                                index: GSBuffer.renderUniforms)
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: accumulator.count)
    }

    private func pointSize(contentScale: Float) -> Float {
        let base = scanController?.settings.pointSize ?? 7.0
        return base * pointSizeScale * max(contentScale, 1)
    }

    // MARK: - Textures

    private func makeTexture(from pixelBuffer: CVPixelBuffer,
                             plane: Int,
                             format: MTLPixelFormat) -> CVMetalTexture? {
        guard let textureCache else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
        guard width > 0, height > 0 else { return nil }

        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pixelBuffer, nil, format, width, height, plane, &texture)
        return status == kCVReturnSuccess ? texture : nil
    }

    /// Maps the four corners of the fullscreen quad onto the camera image,
    /// honouring the interface orientation and the aspect-fill crop.
    private func updateBackgroundUVs(frame: ARFrame, orientation: UIInterfaceOrientation, viewSize: CGSize) {
        guard let backgroundUVBuffer, viewSize.width > 0, viewSize.height > 0 else { return }
        let displayToCamera = frame.displayTransform(for: orientation, viewportSize: viewSize).inverted()

        // Quad corner order matches the vertex shader: BL, BR, TL, TR in clip
        // space, which is TL, TR, BL, BR in the display's top-left origin space.
        let displayCorners = [CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1),
                              CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0)]
        let uvs = displayCorners.map { corner -> SIMD2<Float> in
            let mapped = corner.applying(displayToCamera)
            return SIMD2(Float(mapped.x), Float(mapped.y))
        }
        uvs.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            backgroundUVBuffer.contents().copyMemory(from: base,
                                                     byteCount: MemoryLayout<SIMD2<Float>>.stride * 4)
        }
    }
}

// MARK: - ScreenProjector

extension Renderer: ScreenProjector {

    func project(_ world: SIMD3<Float>, viewSize: CGSize) -> CGPoint? {
        guard viewSize.width > 0, viewSize.height > 0 else { return nil }
        let clip = viewProjection * SIMD4<Float>(world, 1)
        guard clip.w > 1e-5 else { return nil }
        let ndc = SIMD3(clip.x, clip.y, clip.z) / clip.w
        guard ndc.z >= 0, ndc.z <= 1 else { return nil }
        return CGPoint(x: CGFloat((ndc.x + 1) * 0.5) * viewSize.width,
                       y: CGFloat((1 - ndc.y) * 0.5) * viewSize.height)
    }
}
