//
//  PointCloudFile.swift
//
//  The cloud's own on-disk format: a 16-byte header and then the GSPoint records
//  exactly as they sit in the Metal buffer.
//
//  Deliberately not PLY or LAS — those are export formats, written once and read
//  by other tools. This one has to load a multi-million point scan back into a
//  GPU buffer in well under a second, and a raw memory image with no parsing does
//  that. Exports are generated from it on demand.
//

import Foundation

enum PointCloudFile {

    enum Failure: LocalizedError {
        case badMagic
        case unsupportedVersion(UInt32)
        case truncated

        var errorDescription: String? {
            switch self {
            case .badMagic: return "That file is not a GeoScan point cloud."
            case .unsupportedVersion(let v): return "Point cloud format version \(v) is newer than this app."
            case .truncated: return "The point cloud file is incomplete."
            }
        }
    }

    static let magic: UInt32 = 0x4753_5043   // "GSPC"
    static let version: UInt32 = 1
    static let headerSize = 16
    static let fileExtension = "gspc"

    static func write(_ points: [GSPoint], to url: URL) throws {
        var data = Data(capacity: headerSize + points.count * MemoryLayout<GSPoint>.stride)
        let header: [UInt32] = [magic, version, UInt32(points.count), 0]
        header.withUnsafeBufferPointer { data.append(UnsafeRawBufferPointer($0).bindMemory(to: UInt8.self)) }
        points.withUnsafeBufferPointer { data.append(UnsafeRawBufferPointer($0).bindMemory(to: UInt8.self)) }
        try data.write(to: url, options: .atomic)
    }

    static func read(from url: URL) throws -> [GSPoint] {
        // Memory-mapped: the header check costs a page fault rather than a full read.
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= headerSize else { throw Failure.truncated }

        let header: [UInt32] = data.prefix(headerSize).withUnsafeBytes { raw in
            Array(raw.bindMemory(to: UInt32.self).prefix(4))
        }
        guard header.count == 4 else { throw Failure.truncated }
        guard header[0] == magic else { throw Failure.badMagic }
        guard header[1] <= version else { throw Failure.unsupportedVersion(header[1]) }

        let count = Int(header[2])
        let stride = MemoryLayout<GSPoint>.stride
        guard data.count >= headerSize + count * stride else { throw Failure.truncated }

        return data.withUnsafeBytes { raw -> [GSPoint] in
            let base = raw.baseAddress!.advanced(by: headerSize)
            let buffer = UnsafeRawBufferPointer(start: base, count: count * stride)
            return Array(buffer.bindMemory(to: GSPoint.self))
        }
    }

    /// Point count without reading the body — for list screens.
    static func peekCount(at url: URL) -> Int? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: headerSize), head.count == headerSize else { return nil }
        let header: [UInt32] = head.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self).prefix(4)) }
        guard header.count == 4, header[0] == magic else { return nil }
        return Int(header[2])
    }
}
