//
//  Project.swift
//  The on-disk unit of work: one scan, its cloud, its stills, its measurements
//  and the georeference solution that ties them to the earth.
//
//  Layout under Documents/Projects/<uuid>/
//    project.json   this struct
//    cloud.gspc     packed GSPoint records (see PointCloudFile)
//    mesh.obj       ARKit scene reconstruction, optional
//    photos/*.jpg   stills, EXIF-geotagged
//    thumb.jpg      list thumbnail
//

import Foundation
import simd

struct ProjectStatistics: Codable, Equatable {
    var pointCount: Int = 0
    var rawPointCount: Int = 0          // before voxel compaction
    var frameCount: Int = 0
    var droppedForMotion: Int = 0
    var boundsMin: SIMD3<Float> = .zero
    var boundsMax: SIMD3<Float> = .zero
    var scanDuration: TimeInterval = 0
    var meshFaceCount: Int = 0

    var extent: SIMD3<Float> { boundsMax - boundsMin }

    var volumeDescription: String {
        let e = extent
        guard e.x.isFinite, e.x > 0 else { return "—" }
        return String(format: "%.1f × %.1f × %.1f m", e.x, e.z, e.y)
    }
}

struct Project: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var settings: ScanSettings = .default
    var statistics: ProjectStatistics = ProjectStatistics()

    /// Georeference solution and the raw fixes behind it, so it can be re-solved.
    var geoSolution: GeoSolution = .unsolved
    var geoFixes: [GeoFix] = []
    var initialTrueHeading: Double?

    var photos: [PhotoNote] = []
    var measurements: [SiteMeasurement] = []

    var hasMesh: Bool = false
    var deviceModel: String = ""
    var systemVersion: String = ""
    var appVersion: String = ""

    /// Schema version, so an older scan can be migrated rather than rejected.
    var formatVersion: Int = 1

    // MARK: - Convenience

    var photoCount: Int { photos.count }
    var measurementCount: Int { measurements.count }

    var subtitle: String {
        let points = Project.pointCountFormatter.string(from: NSNumber(value: statistics.pointCount)) ?? "0"
        var parts = ["\(points) pts"]
        if photoCount > 0 { parts.append("\(photoCount) photo\(photoCount == 1 ? "" : "s")") }
        if measurementCount > 0 { parts.append("\(measurementCount) meas.") }
        if geoSolution.isUsable { parts.append("GPS") }
        return parts.joined(separator: " · ")
    }

    func photo(id: UUID) -> PhotoNote? { photos.first { $0.id == id } }
    func measurement(id: UUID) -> SiteMeasurement? { measurements.first { $0.id == id } }

    /// Re-run the georeference fit over the stored fixes — useful after a scan,
    /// when all the fixes are in and the walked baseline is at its longest.
    mutating func resolveGeoreference() {
        geoSolution = GeoReferencer.solve(fixes: geoFixes, initialTrueHeading: initialTrueHeading)
    }

    static let pointCountFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()
}
