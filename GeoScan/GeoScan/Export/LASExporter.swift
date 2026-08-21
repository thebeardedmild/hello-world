//
//  LASExporter.swift
//
//  LAS 1.4, point data record format 2 (XYZ + intensity + RGB), with an OGC WKT
//  projection VLR so the file carries its own coordinate reference system.
//
//  LAS is the format every survey and GIS package speaks, and unlike PLY it
//  stores coordinates as scaled 32-bit integers against a double-precision
//  offset — which is exactly what you need when your easting is 500,000 and you
//  still care about the millimetre.
//

import Foundation
import simd

enum LASExporter {

    enum Failure: LocalizedError {
        case notGeoreferenced
        case tooManyPoints

        var errorDescription: String? {
            switch self {
            case .notGeoreferenced:
                return "LAS export needs a georeferenced scan. Scan again with location enabled, or export PLY instead."
            case .tooManyPoints:
                return "That cloud is too large for a single LAS file."
            }
        }
    }

    /// Millimetre quantisation — an order of magnitude finer than the sensor.
    private static let scale = 0.001

    static func write(points: [GSPoint],
                      to url: URL,
                      transformer: PointTransformer,
                      minConfidence: Int,
                      progress: ((Double) -> Void)? = nil) throws {

        let kept = points.filter { Int($0.confidence) >= minConfidence && $0.isFinite }
        guard kept.count <= Int(UInt64.max) else { throw Failure.tooManyPoints }

        // Transform once: we need the extents for the header before writing any
        // records, and re-projecting millions of points twice is not free.
        var transformed = [SIMD3<Double>]()
        transformed.reserveCapacity(kept.count)
        var minimum = SIMD3<Double>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD3<Double>(repeating: -.greatestFiniteMagnitude)
        for (index, point) in kept.enumerated() {
            let p = transformer.transform(point)
            transformed.append(p)
            minimum = simd_min(minimum, p)
            maximum = simd_max(maximum, p)
            if index % 250_000 == 0 { progress?(0.4 * Double(index) / Double(max(kept.count, 1))) }
        }
        if kept.isEmpty {
            minimum = .zero
            maximum = .zero
        }

        // Offsets are whole metres near the cloud's own origin, which keeps the
        // scaled integers comfortably inside Int32 for any realistic scan.
        let offset = SIMD3(minimum.x.rounded(.down), minimum.y.rounded(.down), minimum.z.rounded(.down))

        let wkt = transformer.utmZone.map { UTM.wkt(for: $0) }
        var vlrData = Data()
        var vlrCount: UInt32 = 0
        if let wkt {
            vlrData = makeWKTVLR(wkt)
            vlrCount = 1
        }

        let headerSize: UInt16 = 375
        let pointRecordLength: UInt16 = 26     // PDRF 2
        let offsetToPointData = UInt32(Int(headerSize) + vlrData.count)

        var header = Data(capacity: Int(headerSize))
        header.append(contentsOf: Array("LASF".utf8))                 // signature
        header.appendLE(UInt16(0))                                    // file source id
        // Global encoding bit 4 says "the CRS is WKT, not GeoTIFF keys".
        header.appendLE(UInt16(wkt == nil ? 0 : 0b1_0000))
        header.append(Data(count: 16))                                // project GUID
        header.append(UInt8(1))                                       // version major
        header.append(UInt8(4))                                       // version minor
        header.append(fixedString("GeoScan", length: 32))             // system identifier
        header.append(fixedString("GeoScan iOS LiDAR", length: 32))   // generating software

        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let dayOfYear = calendar.ordinality(of: .day, in: .year, for: now) ?? 1
        let year = calendar.component(.year, from: now)
        header.appendLE(UInt16(dayOfYear))
        header.appendLE(UInt16(year))

        header.appendLE(headerSize)
        header.appendLE(offsetToPointData)
        header.appendLE(vlrCount)
        header.append(UInt8(2))                                       // point data record format
        header.appendLE(pointRecordLength)
        // LAS 1.4 keeps the legacy 32-bit counts for readers that predate it;
        // they must be zero once the count exceeds what they can hold.
        let legacyCount = kept.count <= Int(UInt32.max) ? UInt32(kept.count) : 0
        header.appendLE(legacyCount)
        header.appendLE(legacyCount)                                  // legacy points by return 1
        for _ in 0..<4 { header.appendLE(UInt32(0)) }                 // returns 2-5

        header.appendLE(scale); header.appendLE(scale); header.appendLE(scale)
        header.appendLE(offset.x); header.appendLE(offset.y); header.appendLE(offset.z)
        header.appendLE(maximum.x); header.appendLE(minimum.x)
        header.appendLE(maximum.y); header.appendLE(minimum.y)
        header.appendLE(maximum.z); header.appendLE(minimum.z)

        header.appendLE(UInt64(0))                                    // start of waveform data
        header.appendLE(UInt64(0))                                    // start of first EVLR
        header.appendLE(UInt32(0))                                    // number of EVLRs
        header.appendLE(UInt64(kept.count))                           // number of point records
        header.appendLE(UInt64(kept.count))                           // points by return 1
        for _ in 0..<14 { header.appendLE(UInt64(0)) }                // returns 2-15

        precondition(header.count == Int(headerSize), "LAS header must be exactly 375 bytes")

        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: header)
        if !vlrData.isEmpty { try handle.write(contentsOf: vlrData) }

        let inverseScale = 1.0 / scale
        var chunk = Data(capacity: 200_000 * Int(pointRecordLength))
        for (index, point) in kept.enumerated() {
            let p = transformed[index]
            chunk.appendLE(Int32(((p.x - offset.x) * inverseScale).rounded()))
            chunk.appendLE(Int32(((p.y - offset.y) * inverseScale).rounded()))
            chunk.appendLE(Int32(((p.z - offset.z) * inverseScale).rounded()))
            // No radiometric intensity from the LiDAR, so carry luminance — it is
            // what most viewers fall back to rendering when colour is off.
            let luma = 0.2126 * Double(point.r) + 0.7152 * Double(point.g) + 0.0722 * Double(point.b)
            chunk.appendLE(UInt16(min(65_535, Int(luma * 257))))
            chunk.append(UInt8(0b0000_1001))                          // return 1 of 1
            // Classification 0 = "created, never classified", which is honest.
            chunk.append(UInt8(0))
            // Scan angle rank is unused; user data carries LiDAR confidence so it
            // survives the round trip into other tools.
            chunk.append(UInt8(0))
            chunk.append(point.confidence)
            chunk.appendLE(UInt16(0))                                 // point source id
            chunk.appendLE(UInt16(point.r) << 8 | UInt16(point.r))
            chunk.appendLE(UInt16(point.g) << 8 | UInt16(point.g))
            chunk.appendLE(UInt16(point.b) << 8 | UInt16(point.b))

            if chunk.count >= 200_000 * Int(pointRecordLength) {
                try handle.write(contentsOf: chunk)
                chunk.removeAll(keepingCapacity: true)
                progress?(0.4 + 0.6 * Double(index) / Double(max(kept.count, 1)))
            }
        }
        if !chunk.isEmpty { try handle.write(contentsOf: chunk) }
        progress?(1.0)
    }

    // MARK: - Helpers

    /// LASF_Projection record 2112: the OGC WKT for the file's CRS.
    private static func makeWKTVLR(_ wkt: String) -> Data {
        var payload = Data(wkt.utf8)
        payload.append(0)   // null terminated, as the spec requires

        var vlr = Data()
        vlr.appendLE(UInt16(0))                                     // reserved
        vlr.append(fixedString("LASF_Projection", length: 16))
        vlr.appendLE(UInt16(2112))                                  // OGC math transform / coordinate system WKT
        vlr.appendLE(UInt16(payload.count))
        vlr.append(fixedString("OGC WKT from GeoScan", length: 32))
        vlr.append(payload)
        return vlr
    }

    private static func fixedString(_ value: String, length: Int) -> Data {
        var data = Data(value.utf8.prefix(length))
        if data.count < length { data.append(Data(count: length - data.count)) }
        return data
    }
}

private extension Data {
    /// Little-endian append for the fixed-width fields LAS is built from.
    mutating func appendLE<T>(_ value: T) {
        var v = value
        withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
