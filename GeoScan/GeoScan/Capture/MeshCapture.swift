//
//  MeshCapture.swift
//
//  Keeps a copy of ARKit's scene reconstruction alongside the point cloud.
//
//  The mesh is not a substitute for the cloud — it is smoothed and it invents
//  surfaces across gaps — but it is the better thing to snap a measurement to,
//  and it gives the export a watertight-ish OBJ to open next to the points.
//

import Foundation
import ARKit
import simd

/// A flattened, world-space copy of one ARMeshAnchor.
struct MeshChunk {
    var identifier: UUID
    var vertices: [SIMD3<Float>]
    var normals: [SIMD3<Float>]
    var indices: [UInt32]
    /// ARMeshClassification raw values, one per face.
    var classifications: [UInt8]
}

final class MeshCapture {

    private(set) var chunks: [UUID: MeshChunk] = [:]

    var faceCount: Int { chunks.values.reduce(0) { $0 + $1.indices.count / 3 } }
    var vertexCount: Int { chunks.values.reduce(0) { $0 + $1.vertices.count } }

    /// Apply chunks that were flattened on the ARSession's own queue.
    func apply(_ newChunks: [MeshChunk]) {
        for chunk in newChunks { chunks[chunk.identifier] = chunk }
    }

    func remove(_ identifiers: [UUID]) {
        for id in identifiers { chunks.removeValue(forKey: id) }
    }

    func reset() { chunks.removeAll() }

    /// Copies the geometry out of the anchor's GPU buffers into world space.
    ///
    /// Call this on the ARSession delegate queue, while the anchor is still
    /// valid — ARKit recycles those buffers, so reading them a hop later is a
    /// use-after-free waiting to happen.
    static func flatten(_ anchor: ARMeshAnchor) -> MeshChunk {
        let geometry = anchor.geometry
        let transform = anchor.transform
        let normalTransform = simd_float3x3(SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
                                            SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
                                            SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z))

        var vertices = [SIMD3<Float>]()
        vertices.reserveCapacity(geometry.vertices.count)
        for i in 0..<geometry.vertices.count {
            let local = geometry.vertices.value(at: i, as: SIMD3<Float>.self)
            let world = transform * SIMD4<Float>(local, 1)
            vertices.append(SIMD3(world.x, world.y, world.z))
        }

        var normals = [SIMD3<Float>]()
        normals.reserveCapacity(geometry.normals.count)
        for i in 0..<geometry.normals.count {
            let local = geometry.normals.value(at: i, as: SIMD3<Float>.self)
            normals.append(simd_normalize(normalTransform * local))
        }

        var indices = [UInt32]()
        let faces = geometry.faces
        // ARKit has always used 32-bit indices here, but the API does not
        // promise it, and misreading the buffer would produce silent garbage.
        if faces.bytesPerIndex == MemoryLayout<UInt32>.size {
            indices.reserveCapacity(faces.count * faces.indexCountPerPrimitive)
            let indexBuffer = faces.buffer.contents().assumingMemoryBound(to: UInt32.self)
            for i in 0..<(faces.count * faces.indexCountPerPrimitive) {
                indices.append(indexBuffer[i])
            }
        } else {
            assertionFailure("Unexpected ARKit index width: \(faces.bytesPerIndex) bytes")
        }

        var classifications = [UInt8]()
        if let source = geometry.classification {
            classifications.reserveCapacity(source.count)
            let base = source.buffer.contents().advanced(by: source.offset)
            for i in 0..<source.count {
                classifications.append(base.advanced(by: i * source.stride).assumingMemoryBound(to: UInt8.self).pointee)
            }
        }

        return MeshChunk(identifier: anchor.identifier,
                         vertices: vertices,
                         normals: normals,
                         indices: indices,
                         classifications: classifications)
    }
}

extension ARGeometrySource {
    /// Reads one element out of an ARKit geometry source, honouring its stride
    /// and offset rather than assuming a tight packing.
    func value<T>(at index: Int, as type: T.Type) -> T {
        let pointer = buffer.contents().advanced(by: offset + stride * index)
        return pointer.assumingMemoryBound(to: T.self).pointee
    }
}
