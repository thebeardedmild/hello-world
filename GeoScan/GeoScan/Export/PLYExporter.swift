//
//  PLYExporter.swift
//
//  Binary little-endian PLY with colour and per-point LiDAR confidence.
//
//  Written straight to a file handle in chunks: a 6M point cloud is around
//  100 MB, and building that as one Data in memory on a phone that is also
//  holding the live buffer is asking for a jetsam kill.
//

import Foundation
import simd

enum PLYExporter {

    /// One vertex record: 3 floats + 4 bytes.
    private struct Vertex {
        var x: Float
        var y: Float
        var z: Float
        var red: UInt8
        var green: UInt8
        var blue: UInt8
        var confidence: UInt8
    }

    static func write(points: [GSPoint],
                      to url: URL,
                      transformer: PointTransformer,
                      minConfidence: Int,
                      comments: [String] = [],
                      progress: ((Double) -> Void)? = nil) throws {
        let kept = points.filter { Int($0.confidence) >= minConfidence && $0.isFinite }

        var header = "ply\n"
        header += "format binary_little_endian 1.0\n"
        header += "comment Created by GeoScan\n"
        header += "comment CRS \(transformer.crsDescription)\n"
        header += "comment AXES \(transformer.axisDescription)\n"
        header += "comment UNITS metres\n"
        header += "comment CONFIDENCE 0=low 1=medium 2=high (ARKit LiDAR)\n"
        for comment in comments {
            header += "comment \(comment.replacingOccurrences(of: "\n", with: " "))\n"
        }
        header += "element vertex \(kept.count)\n"
        header += "property float x\n"
        header += "property float y\n"
        header += "property float z\n"
        header += "property uchar red\n"
        header += "property uchar green\n"
        header += "property uchar blue\n"
        header += "property uchar confidence\n"
        header += "end_header\n"

        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data(header.utf8))

        let chunkSize = 200_000
        var buffer = [Vertex]()
        buffer.reserveCapacity(chunkSize)

        for (index, point) in kept.enumerated() {
            let p = transformer.transform(point)
            buffer.append(Vertex(x: Float(p.x), y: Float(p.y), z: Float(p.z),
                                 red: point.r, green: point.g, blue: point.b,
                                 confidence: point.confidence))
            if buffer.count == chunkSize {
                try flush(&buffer, to: handle)
                progress?(Double(index) / Double(max(kept.count, 1)))
            }
        }
        try flush(&buffer, to: handle)
        progress?(1.0)
    }

    private static func flush(_ buffer: inout [Vertex], to handle: FileHandle) throws {
        guard !buffer.isEmpty else { return }
        try buffer.withUnsafeBufferPointer { source in
            let raw = UnsafeRawBufferPointer(source)
            try handle.write(contentsOf: Data(raw))
        }
        buffer.removeAll(keepingCapacity: true)
    }
}
