//
//  ExportBundle.swift
//
//  Builds the export folder and hands back something shareable.
//
//  A scan is not one file. It is a cloud, a mesh, a set of stills, a measurement
//  schedule and the metadata that says what frame all of it is in — so the export
//  is a directory with a README that explains itself, zipped for the share sheet.
//

import Foundation
import Combine
import simd

/// Progress reported out of the export, which runs off the main actor — so this
/// lives at file scope rather than nested inside the main-actor-bound job.
enum ExportStage: Equatable {
    case idle
    case filtering
    case writing(String)
    case packaging
    case finished(URL)
    case failed(String)

    var description: String {
        switch self {
        case .idle: return "Ready"
        case .filtering: return "Filtering the cloud…"
        case .writing(let name): return "Writing \(name)…"
        case .packaging: return "Packaging…"
        case .finished: return "Done"
        case .failed(let message): return message
        }
    }
}

@MainActor
final class ExportJob: ObservableObject {

    @Published private(set) var stage: ExportStage = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var writtenFiles: [String] = []
    @Published private(set) var warnings: [String] = []

    var isRunning: Bool {
        switch stage {
        case .idle, .finished, .failed: return false
        default: return true
        }
    }

    // MARK: - Running

    /// The file locations are passed in rather than looked up, so the job has no
    /// dependency on the store and can be driven from a preview or a test.
    func run(project: Project,
             options: ExportOptions,
             cloudURL: URL,
             meshURL: URL,
             photosDirectory: URL) {
        guard !isRunning else { return }
        stage = .filtering
        progress = 0
        writtenFiles = []
        warnings = []

        Task.detached(priority: .userInitiated) {
            do {
                let result = try ExportBundle.build(project: project,
                                                    options: options,
                                                    cloudURL: cloudURL,
                                                    meshURL: meshURL,
                                                    photosDirectory: photosDirectory) { stage, fraction in
                    Task { @MainActor in
                        self.stage = stage
                        self.progress = fraction
                    }
                }
                await MainActor.run {
                    self.writtenFiles = result.fileNames
                    self.warnings = result.warnings
                    self.progress = 1
                    self.stage = .finished(result.url)
                }
            } catch {
                await MainActor.run {
                    self.stage = .failed(error.localizedDescription)
                }
            }
        }
    }

    func reset() {
        stage = .idle
        progress = 0
    }
}

enum ExportBundle {

    struct Result {
        /// The zip handed to the share sheet.
        var url: URL
        /// The directory it was built from, kept for Files-app access.
        var directory: URL
        var fileNames: [String]
        var warnings: [String]
    }

    /// Builds the export. Not main-actor bound: this is minutes of work on a
    /// large scan and it has no business on the UI thread.
    static func build(project: Project,
                      options: ExportOptions,
                      cloudURL: URL,
                      meshURL: URL,
                      photosDirectory: URL,
                      report: @escaping (ExportStage, Double) -> Void) throws -> Result {

        var warnings: [String] = []
        var fileNames: [String] = []

        let fileManager = FileManager.default
        let stamp = ExportBundle.timestamp()
        let folderName = "\(ExportBundle.safeName(project.name))_\(stamp)"
        let root = fileManager.temporaryDirectory.appendingPathComponent("exports", isDirectory: true)
        let directory = root.appendingPathComponent(folderName, isDirectory: true)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        // MARK: Frame

        var effectiveOptions = options
        if options.frame.requiresGeoreference && !project.geoSolution.isUsable {
            effectiveOptions.frame = .arWorld
            warnings.append("No usable GPS solution — exported in the scanner's local frame instead of \(options.frame.title).")
        }
        let transformer = PointTransformer(frame: effectiveOptions.frame, solution: project.geoSolution)

        // MARK: Cloud

        report(.filtering, 0.02)
        var points = try PointCloudFile.read(from: cloudURL)
        let capturedCount = points.count

        if effectiveOptions.voxelLeafSize > 0 {
            points = VoxelGridFilter.filter(points, leafSize: effectiveOptions.voxelLeafSize) { fraction in
                report(.filtering, 0.02 + fraction * 0.28)
            }
        }
        if effectiveOptions.removeOutliers {
            points = OutlierFilter.removeOutliers(points,
                                                  neighbors: project.settings.outlierNeighbors,
                                                  standardDeviations: project.settings.outlierStandardDeviations,
                                                  searchRadius: max(0.05, effectiveOptions.voxelLeafSize * 6)) { fraction in
                report(.filtering, 0.30 + fraction * 0.15)
            }
        }
        let exportedCount = points.count

        if effectiveOptions.formats.contains(.ply) {
            let name = "cloud.ply"
            report(.writing(name), 0.5)
            try PLYExporter.write(points: points,
                                  to: directory.appendingPathComponent(name),
                                  transformer: transformer,
                                  minConfidence: effectiveOptions.minConfidence,
                                  comments: ["Scan \(project.name)",
                                             "Captured \(ISO8601DateFormatter().string(from: project.createdAt))"])
            fileNames.append(name)
        }

        if effectiveOptions.formats.contains(.las) {
            if effectiveOptions.frame == .arWorld {
                warnings.append("LAS was skipped: it needs a georeferenced frame, and this scan has no GPS solution.")
            } else {
                let name = "cloud.las"
                report(.writing(name), 0.65)
                try LASExporter.write(points: points,
                                      to: directory.appendingPathComponent(name),
                                      transformer: transformer,
                                      minConfidence: effectiveOptions.minConfidence)
                fileNames.append(name)
            }
        }

        // MARK: Mesh

        if effectiveOptions.includeMesh, effectiveOptions.formats.contains(.obj),
           fileManager.fileExists(atPath: meshURL.path) {
            let name = "mesh.obj"
            report(.writing(name), 0.75)
            let source = try Data(contentsOf: meshURL)
            let converted = OBJExporter.retransform(objData: source, transformer: transformer)
            try converted.write(to: directory.appendingPathComponent(name), options: .atomic)
            fileNames.append(name)
        }

        // MARK: Notes and measurements

        if effectiveOptions.formats.contains(.geojson) {
            if let photoJSON = GeoJSONExporter.makePhotoCollection(project: project) {
                let name = "photos.geojson"
                try photoJSON.write(to: directory.appendingPathComponent(name), options: .atomic)
                fileNames.append(name)
            }
            if let measurementJSON = GeoJSONExporter.makeMeasurementCollection(project: project) {
                let name = "measurements.geojson"
                try measurementJSON.write(to: directory.appendingPathComponent(name), options: .atomic)
                fileNames.append(name)
            }
            if !project.geoSolution.isUsable {
                warnings.append("GeoJSON was skipped: it is defined in latitude/longitude only, and this scan has no GPS solution.")
            }
        }

        if effectiveOptions.formats.contains(.csv) {
            let measurementName = "measurements.csv"
            try CSVExporter.makeMeasurementCSV(project: project)
                .write(to: directory.appendingPathComponent(measurementName), options: .atomic)
            fileNames.append(measurementName)

            let photoName = "photos.csv"
            try CSVExporter.makePhotoCSV(project: project)
                .write(to: directory.appendingPathComponent(photoName), options: .atomic)
            fileNames.append(photoName)
        }

        // MARK: Stills

        if effectiveOptions.includePhotos, !project.photos.isEmpty {
            report(.writing("photos"), 0.85)
            let destination = directory.appendingPathComponent("photos", isDirectory: true)
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            for photo in project.photos {
                let source = photosDirectory.appendingPathComponent(photo.fileName)
                guard fileManager.fileExists(atPath: source.path) else {
                    warnings.append("Missing still \(photo.fileName).")
                    continue
                }
                try? fileManager.copyItem(at: source, to: destination.appendingPathComponent(photo.fileName))
            }
            fileNames.append("photos/ (\(project.photos.count) stills)")
        }

        // MARK: Metadata

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let manifest = try encoder.encode(project)
        try manifest.write(to: directory.appendingPathComponent("scan.json"), options: .atomic)
        fileNames.append("scan.json")

        let readme = ExportBundle.makeREADME(project: project,
                                             options: effectiveOptions,
                                             transformer: transformer,
                                             capturedCount: capturedCount,
                                             exportedCount: exportedCount,
                                             files: fileNames,
                                             warnings: warnings)
        try Data(readme.utf8).write(to: directory.appendingPathComponent("README.txt"), options: .atomic)
        fileNames.append("README.txt")

        // MARK: Package

        report(.packaging, 0.95)
        let zipURL = try ExportBundle.zip(directory: directory)

        return Result(url: zipURL, directory: directory, fileNames: fileNames, warnings: warnings)
    }

    /// Zips a directory using the file coordinator's `forUploading` option — the
    /// only zip implementation that ships with the system.
    static func zip(directory: URL) throws -> URL {
        var coordinatorError: NSError?
        var thrownError: Error?
        var result: URL?

        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: directory, options: [.forUploading], error: &coordinatorError) { temporary in
            let destination = directory.deletingLastPathComponent()
                .appendingPathComponent(directory.lastPathComponent + ".zip")
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                // The coordinator's copy is deleted as soon as this block
                // returns, so it has to be moved out now.
                try FileManager.default.copyItem(at: temporary, to: destination)
                result = destination
            } catch {
                thrownError = error
            }
        }
        if let coordinatorError { throw coordinatorError }
        if let thrownError { throw thrownError }
        guard let result else {
            throw NSError(domain: "GeoScan", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not package the export."])
        }
        return result
    }

    // MARK: - README

    static func makeREADME(project: Project,
                           options: ExportOptions,
                           transformer: PointTransformer,
                           capturedCount: Int,
                           exportedCount: Int,
                           files: [String],
                           warnings: [String]) -> String {
        let solution = project.geoSolution
        var text = """
        \(project.name)
        \(String(repeating: "=", count: project.name.count))

        Captured with GeoScan on \(DateFormatter.localizedString(from: project.createdAt, dateStyle: .long, timeStyle: .short))
        Device: \(project.deviceModel) — iOS \(project.systemVersion)

        COORDINATE REFERENCE
        --------------------
        Frame:  \(options.frame.title)
        CRS:    \(transformer.crsDescription)
        Axes:   \(transformer.axisDescription)
        Units:  metres

        """

        if solution.isUsable {
            text += """
            GEOREFERENCE
            ------------
            Method:              \(describe(solution.method))
            Origin:              \(String(format: "%.8f, %.8f", solution.origin.latitude, solution.origin.longitude))
            Origin height:       \(String(format: "%.3f m", solution.origin.ellipsoidalHeight)) above the WGS84 ellipsoid
            Yaw to true north:   \(String(format: "%.2f°", solution.yaw * 180 / .pi))
            GPS fixes used:      \(solution.fixCount)
            Walked baseline:     \(String(format: "%.1f m", solution.baselineLength))
            Fit residual (RMS):  \(String(format: "%.2f m horizontal, %.2f m vertical", solution.horizontalRMSE, solution.verticalRMSE))
            Best fix accuracy:   \(String(format: "%.1f m", solution.bestFixAccuracy))
            Estimated absolute:  ±\(String(format: "%.1f m", solution.estimatedAbsoluteAccuracy)) (1 sigma)

            Absolute position is only as good as consumer GPS. RELATIVE accuracy
            within the scan is far better — measurements between two points in this
            cloud are good to roughly a centimetre at typical range. Do not use the
            absolute coordinates for anything a surveyor would sign.

            """
        } else {
            text += """
            GEOREFERENCE
            ------------
            None. This scan has no usable GPS solution, so coordinates are relative
            to where the scan started. Distances and areas are still valid.

            """
        }

        if solution.method == .compass {
            text += """
            NOTE: north came from the magnetometer, not from the GPS track, because
            the scan did not cover enough ground to fit one. Treat the bearing as
            approximate — several degrees of error is normal indoors.

            """
        }

        text += """
        POINT CLOUD
        -----------
        Captured points:   \(capturedCount)
        Exported points:   \(exportedCount)
        Voxel leaf size:   \(options.voxelLeafSize > 0 ? String(format: "%.0f mm", options.voxelLeafSize * 1000) : "none")
        Outlier removal:   \(options.removeOutliers ? "on" : "off")
        Confidence floor:  \(options.minConfidence) (0 low, 1 medium, 2 high)

        Each point carries the LiDAR confidence it was captured with. In the PLY it
        is a `confidence` vertex property; in the LAS it is the user-data byte.

        MEASUREMENTS
        ------------
        \(project.measurements.count) recorded. See measurements.csv for the schedule,
        including the one-sigma uncertainty of every value. Those uncertainties are
        real: they come from the spread of the LiDAR samples that were averaged to
        place each end point.

        PHOTOS
        ------
        \(project.photos.count) stills. Each is EXIF-geotagged, and photos.csv /
        photos.geojson carry the note, the tags, the camera position and the bearing.
        scan.json holds the full camera pose and intrinsics for every still, which is
        what lets a viewer project a photo back onto the cloud.

        FILES
        -----
        """
        for file in files { text += "\n  \(file)" }

        if !warnings.isEmpty {
            text += "\n\nWARNINGS\n--------"
            for warning in warnings { text += "\n  - \(warning)" }
        }

        text += "\n"
        return text
    }

    private static func describe(_ method: GeoSolution.Method) -> String {
        switch method {
        case .none: return "none"
        case .singleFix: return "single GPS fix (position only)"
        case .compass: return "averaged GPS position, magnetometer heading"
        case .gpsTrack: return "least-squares fit of the walked path to the GPS track"
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter.string(from: Date())
    }

    private static func safeName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

extension OBJExporter {
    /// Rewrites the vertex lines of a stored OBJ into another frame. Parsing the
    /// text back is cheaper than keeping a second copy of the mesh around, and
    /// the rest of the file (normals, faces, grouping) passes through untouched.
    static func retransform(objData: Data, transformer: PointTransformer) -> Data {
        guard transformer.frame != .arWorld,
              let text = String(data: objData, encoding: .utf8) else { return objData }

        var out = "# Re-expressed in \(transformer.crsDescription)\n"
        out += "# AXES \(transformer.axisDescription)\n"
        out.reserveCapacity(text.count + 256)

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.hasPrefix("v ") else {
                out += line
                out += "\n"
                continue
            }
            let parts = line.split(separator: " ")
            guard parts.count >= 4,
                  let x = Float(parts[1]), let y = Float(parts[2]), let z = Float(parts[3]) else {
                out += line
                out += "\n"
                continue
            }
            let p = transformer.transform(SIMD3<Float>(x, y, z))
            out += String(format: "v %.4f %.4f %.4f\n", p.x, p.y, p.z)
        }
        return Data(out.utf8)
    }
}
