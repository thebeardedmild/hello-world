//
//  ExportOptions.swift
//
//  What frame the numbers are in matters more than the file format, so it is the
//  first choice the export sheet offers.
//

import Foundation
import simd

enum CoordinateFrame: String, Codable, CaseIterable, Identifiable {
    /// Raw ARKit world axes: metres, +Y up, origin where the scan started.
    case arWorld
    /// East / North / Up, metres, origin at the georeferenced scan origin.
    case localENU
    /// WGS84 UTM easting / northing / ellipsoidal height, shifted by a stated
    /// offset so the values still fit in 32-bit floats.
    case utm

    var id: String { rawValue }

    var title: String {
        switch self {
        case .arWorld: return "Scanner local"
        case .localENU: return "Local East/North/Up"
        case .utm: return "UTM (georeferenced)"
        }
    }

    var subtitle: String {
        switch self {
        case .arWorld: return "Origin where you started, +Y up. No GPS needed."
        case .localENU: return "Metres east/north/up from the scan origin, true north."
        case .utm: return "Projected coordinates for GIS and survey software."
        }
    }

    var requiresGeoreference: Bool { self != .arWorld }
}

enum ExportFormat: String, Codable, CaseIterable, Identifiable {
    case ply
    case las
    case obj
    case geojson
    case csv

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ply: return "PLY point cloud"
        case .las: return "LAS 1.4 point cloud"
        case .obj: return "OBJ mesh"
        case .geojson: return "GeoJSON (photos + measurements)"
        case .csv: return "CSV measurement schedule"
        }
    }

    var subtitle: String {
        switch self {
        case .ply: return "Binary, with colour and confidence. CloudCompare, MeshLab, Blender."
        case .las: return "Colourised, with a CRS. QGIS, ArcGIS, Civil 3D, ReCap."
        case .obj: return "ARKit's reconstructed surfaces, for context."
        case .geojson: return "Photo positions and measurement geometry on a map."
        case .csv: return "Every measurement with its uncertainty, for a report."
        }
    }

    var fileExtension: String { rawValue }
}

struct ExportOptions: Codable, Equatable {
    var frame: CoordinateFrame = .localENU
    var formats: Set<ExportFormat> = [.ply, .geojson, .csv]

    /// 0 disables the voxel pass and exports the cloud as captured.
    var voxelLeafSize: Float = 0.01
    var removeOutliers: Bool = true
    var minConfidence: Int = 1
    var includePhotos: Bool = true
    var includeMesh: Bool = true

    static let `default` = ExportOptions()
}

/// Maps a captured point into the chosen export frame.
struct PointTransformer {

    let frame: CoordinateFrame
    let solution: GeoSolution
    /// Subtracted from UTM coordinates so the exported values stay small enough
    /// for single-precision consumers. Recorded in every file's header.
    private(set) var offset: SIMD3<Double> = .zero
    private(set) var utmZone: UTMZone?

    init(frame requested: CoordinateFrame, solution: GeoSolution, origin: SIMD3<Float> = .zero) {
        // Silently degrade rather than fail: a scan with no GPS is still a
        // perfectly good relative measurement, and the header says which it is.
        self.frame = (requested.requiresGeoreference && !solution.isUsable) ? .arWorld : requested
        self.solution = solution

        if self.frame == .utm {
            let originGeodetic = solution.geodetic(for: origin)
            let projected = UTM.project(originGeodetic)
            utmZone = projected.zone
            // Round the offset to a whole metre so it is easy to add back by hand.
            offset = SIMD3(projected.easting.rounded(),
                           projected.northing.rounded(),
                           projected.height.rounded())
        }
    }

    func transform(_ p: GSPoint) -> SIMD3<Double> {
        switch frame {
        case .arWorld:
            return SIMD3(Double(p.x), Double(p.y), Double(p.z))
        case .localENU:
            let e = solution.enu(for: p.position)
            return SIMD3(e.east, e.north, e.up)
        case .utm:
            let geodetic = solution.geodetic(for: p.position)
            let projected = UTM.project(geodetic, forcedZone: utmZone)
            return SIMD3(projected.easting - offset.x,
                         projected.northing - offset.y,
                         projected.height - offset.z)
        }
    }

    func transform(_ world: SIMD3<Float>) -> SIMD3<Double> {
        transform(GSPoint(x: world.x, y: world.y, z: world.z, r: 0, g: 0, b: 0, confidence: 0))
    }

    /// Axis names for file headers, so nobody has to guess.
    var axisDescription: String {
        switch frame {
        case .arWorld: return "x=right, y=up, z=back (ARKit world, scan origin)"
        case .localENU: return "x=east, y=north, z=up (metres from scan origin)"
        case .utm: return "x=easting, y=northing, z=ellipsoidal height (UTM, offset applied)"
        }
    }

    var crsDescription: String {
        switch frame {
        case .arWorld:
            return "Local scanner frame, no datum."
        case .localENU:
            return String(format: "Local ENU tangent plane, origin %.8f, %.8f, %.3f m (WGS84 ellipsoidal)",
                          solution.origin.latitude, solution.origin.longitude, solution.origin.ellipsoidalHeight)
        case .utm:
            guard let utmZone else { return "UTM" }
            return "\(utmZone.name) (EPSG:\(utmZone.epsgCode)), offset "
                + String(format: "%.0f / %.0f / %.0f", offset.x, offset.y, offset.z)
        }
    }
}
