//
//  OBJExporter.swift
//  Writes the ARKit scene reconstruction as a Wavefront OBJ.
//
//  The mesh is context, not measurement truth — it is smoothed and it bridges
//  gaps the LiDAR never saw — but it opens anywhere and it makes a point cloud
//  far easier to read.
//

import Foundation
import simd

enum OBJExporter {

    static func makeOBJ(chunks: [MeshChunk],
                        name: String,
                        transformer: PointTransformer? = nil) -> Data {
        var out = ""
        out.reserveCapacity(chunks.reduce(0) { $0 + $1.vertices.count * 48 })
        out += "# GeoScan scene reconstruction: \(name)\n"
        out += "# \(chunks.count) chunk(s), \(chunks.reduce(0) { $0 + $1.indices.count / 3 }) faces\n"
        if let transformer {
            out += "# CRS \(transformer.crsDescription)\n"
            out += "# AXES \(transformer.axisDescription)\n"
        } else {
            out += "# AXES x=right, y=up, z=back (ARKit world)\n"
        }

        // OBJ indices are 1-based and global across the file, so chunks are
        // concatenated with a running offset.
        var vertexOffset = 1
        for (chunkIndex, chunk) in chunks.enumerated() {
            out += "o chunk_\(chunkIndex)\n"
            for vertex in chunk.vertices {
                if let transformer {
                    let p = transformer.transform(vertex)
                    out += "v \(fmt(p.x)) \(fmt(p.y)) \(fmt(p.z))\n"
                } else {
                    out += "v \(fmt(Double(vertex.x))) \(fmt(Double(vertex.y))) \(fmt(Double(vertex.z)))\n"
                }
            }
            for normal in chunk.normals {
                out += "vn \(fmt(Double(normal.x))) \(fmt(Double(normal.y))) \(fmt(Double(normal.z)))\n"
            }

            let hasNormals = chunk.normals.count == chunk.vertices.count
            var i = 0
            while i + 2 < chunk.indices.count {
                let a = Int(chunk.indices[i]) + vertexOffset
                let b = Int(chunk.indices[i + 1]) + vertexOffset
                let c = Int(chunk.indices[i + 2]) + vertexOffset
                if hasNormals {
                    out += "f \(a)//\(a) \(b)//\(b) \(c)//\(c)\n"
                } else {
                    out += "f \(a) \(b) \(c)\n"
                }
                i += 3
            }
            vertexOffset += chunk.vertices.count
        }
        return Data(out.utf8)
    }

    private static func fmt(_ value: Double) -> String {
        String(format: "%.4f", value)
    }
}
