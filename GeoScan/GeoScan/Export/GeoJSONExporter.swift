//
//  GeoJSONExporter.swift
//
//  Photo positions and measurement geometry as GeoJSON, so the scan's notes drop
//  straight onto a map in QGIS, Felt, Mapbox or anything else.
//
//  GeoJSON is always WGS84 lon/lat/height by specification — no local frames, no
//  UTM — so this exporter is the one place that ignores the chosen export frame
//  and always georeferences properly. It is skipped entirely for scans with no
//  GPS solution, rather than emitting plausible-looking nonsense at null island.
//

import Foundation
import simd

enum GeoJSONExporter {

    static func makePhotoCollection(project: Project) -> Data? {
        guard project.geoSolution.isUsable else { return nil }
        let solution = project.geoSolution

        var features: [[String: Any]] = []
        for photo in project.photos {
            // Prefer the surveyed pin over the raw GPS fix: it comes from the
            // solved AR trajectory, which is far steadier than a single fix.
            let anchor = solution.geodetic(for: photo.anchorPosition)
            let camera = solution.geodetic(for: photo.cameraPosition)

            var properties: [String: Any] = [
                "id": photo.id.uuidString,
                "file": "photos/\(photo.fileName)",
                "note": photo.note,
                "tags": photo.tags,
                "captured_at": ISO8601DateFormatter().string(from: photo.capturedAt),
                "camera_latitude": camera.latitude,
                "camera_longitude": camera.longitude,
                "camera_ellipsoidal_height_m": camera.ellipsoidalHeight,
                "view_bearing_deg": solution.bearing(forWorldDirection: photo.viewDirection),
                "annotation_count": photo.annotations.count
            ]
            if let distance = photo.aimDistance {
                properties["subject_distance_m"] = Double(distance)
            }
            if let accuracy = photo.locationHorizontalAccuracy {
                properties["gps_horizontal_accuracy_m"] = accuracy
            }

            features.append([
                "type": "Feature",
                "geometry": [
                    "type": "Point",
                    "coordinates": [anchor.longitude, anchor.latitude, anchor.ellipsoidalHeight]
                ],
                "properties": properties
            ])

            // Annotations resolved to 3-D become their own points, so a note
            // pinned to a crack lands on the crack rather than on the photo.
            for annotation in photo.annotations {
                guard let world = annotation.world else { continue }
                let position = solution.geodetic(for: world)
                features.append([
                    "type": "Feature",
                    "geometry": [
                        "type": "Point",
                        "coordinates": [position.longitude, position.latitude, position.ellipsoidalHeight]
                    ],
                    "properties": [
                        "id": annotation.id.uuidString,
                        "kind": "annotation",
                        "photo_id": photo.id.uuidString,
                        "text": annotation.text,
                        "sigma_m": Double(annotation.sigma)
                    ]
                ])
            }
        }

        return serialize(features: features, name: "\(project.name) — photos")
    }

    static func makeMeasurementCollection(project: Project) -> Data? {
        guard project.geoSolution.isUsable else { return nil }
        let solution = project.geoSolution

        var features: [[String: Any]] = []
        for measurement in project.measurements {
            let coordinates = measurement.vertices.map { vertex -> [Double] in
                let g = solution.geodetic(for: vertex.world)
                return [g.longitude, g.latitude, g.ellipsoidalHeight]
            }
            guard coordinates.count >= 2 else { continue }

            let result = measurement.result
            var properties: [String: Any] = [
                "id": measurement.id.uuidString,
                "kind": measurement.kind.rawValue,
                "label": measurement.displayName,
                "note": measurement.note,
                "sigma_m": result.sigma,
                "created_at": ISO8601DateFormatter().string(from: measurement.createdAt)
            ]
            if result.length.isFinite { properties["length_m"] = result.length }
            if result.horizontal.isFinite { properties["horizontal_m"] = result.horizontal }
            if result.vertical.isFinite { properties["vertical_m"] = result.vertical }
            if result.area.isFinite { properties["area_m2"] = result.area }
            if result.planarityRMS.isFinite { properties["planarity_rms_m"] = result.planarityRMS }

            let geometry: [String: Any]
            if measurement.kind == .area {
                // GeoJSON polygons must close the ring explicitly.
                var ring = coordinates
                if let first = ring.first { ring.append(first) }
                geometry = ["type": "Polygon", "coordinates": [ring]]
            } else {
                geometry = ["type": "LineString", "coordinates": coordinates]
            }

            features.append([
                "type": "Feature",
                "geometry": geometry,
                "properties": properties
            ])
        }

        return serialize(features: features, name: "\(project.name) — measurements")
    }

    private static func serialize(features: [[String: Any]], name: String) -> Data? {
        let collection: [String: Any] = [
            "type": "FeatureCollection",
            "name": name,
            "features": features
        ]
        return try? JSONSerialization.data(withJSONObject: collection,
                                           options: [.prettyPrinted, .sortedKeys])
    }
}

enum CSVExporter {

    /// One row per measurement, with the numbers a report actually needs.
    static func makeMeasurementCSV(project: Project) -> Data {
        var rows = ["label,kind,value,unit,horizontal_m,vertical_m,sigma_m,vertices,latitude,longitude,ellipsoidal_height_m,planarity_rms_m,note"]
        let solution = project.geoSolution

        for measurement in project.measurements {
            let result = measurement.result
            let value = measurement.kind == .area ? result.area : result.length
            let unit = measurement.kind == .area ? "m2" : "m"

            var latitude = "", longitude = "", height = ""
            if solution.isUsable, let first = measurement.vertices.first {
                let g = solution.geodetic(for: first.world)
                latitude = String(format: "%.8f", g.latitude)
                longitude = String(format: "%.8f", g.longitude)
                height = String(format: "%.3f", g.ellipsoidalHeight)
            }

            let fields = [
                measurement.displayName,
                measurement.kind.rawValue,
                value.isFinite ? String(format: "%.4f", value) : "",
                unit,
                result.horizontal.isFinite ? String(format: "%.4f", result.horizontal) : "",
                result.vertical.isFinite ? String(format: "%.4f", result.vertical) : "",
                result.sigma.isFinite ? String(format: "%.4f", result.sigma) : "",
                String(measurement.vertices.count),
                latitude, longitude, height,
                result.planarityRMS.isFinite ? String(format: "%.4f", result.planarityRMS) : "",
                measurement.note
            ]
            rows.append(fields.map(escape).joined(separator: ","))
        }
        return Data(rows.joined(separator: "\n").utf8)
    }

    /// One row per still, so a photo log can be opened in a spreadsheet.
    static func makePhotoCSV(project: Project) -> Data {
        var rows = ["file,captured_at,note,tags,latitude,longitude,ellipsoidal_height_m,view_bearing_deg,subject_distance_m,annotations"]
        let solution = project.geoSolution

        for photo in project.photos {
            var latitude = "", longitude = "", height = "", bearing = ""
            if solution.isUsable {
                let g = solution.geodetic(for: photo.anchorPosition)
                latitude = String(format: "%.8f", g.latitude)
                longitude = String(format: "%.8f", g.longitude)
                height = String(format: "%.3f", g.ellipsoidalHeight)
                bearing = String(format: "%.1f", solution.bearing(forWorldDirection: photo.viewDirection))
            }
            let fields = [
                "photos/\(photo.fileName)",
                ISO8601DateFormatter().string(from: photo.capturedAt),
                photo.note,
                photo.tags.joined(separator: "; "),
                latitude, longitude, height, bearing,
                photo.aimDistance.map { String(format: "%.3f", $0) } ?? "",
                String(photo.annotations.count)
            ]
            rows.append(fields.map(escape).joined(separator: ","))
        }
        return Data(rows.joined(separator: "\n").utf8)
    }

    private static func escape(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
