//
//  ProjectStore.swift
//
//  Every scan is a self-contained directory under Documents, which is also
//  exposed over iTunes/Finder file sharing — so a scan can be pulled off the
//  phone with a cable even if every share sheet on iOS is having a bad day.
//

import Foundation
import Combine
import UIKit

@MainActor
final class ProjectStore: ObservableObject {

    @Published private(set) var projects: [Project] = []
    @Published private(set) var lastError: String?

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init() {
        try? fileManager.createDirectory(at: Self.projectsRoot, withIntermediateDirectories: true)
        refresh()
    }

    // MARK: - Locations

    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var projectsRoot: URL {
        documentsDirectory.appendingPathComponent("Projects", isDirectory: true)
    }

    // The path helpers and the raw cloud read are deliberately nonisolated: they
    // touch nothing but the file system, and export and loading both run them
    // off the main actor.
    nonisolated func directory(for id: UUID) -> URL {
        Self.projectsRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    nonisolated func manifestURL(for id: UUID) -> URL {
        directory(for: id).appendingPathComponent("project.json")
    }

    nonisolated func cloudURL(for id: UUID) -> URL {
        directory(for: id).appendingPathComponent("cloud.\(PointCloudFile.fileExtension)")
    }

    nonisolated func meshURL(for id: UUID) -> URL {
        directory(for: id).appendingPathComponent("mesh.obj")
    }

    nonisolated func photosDirectory(for id: UUID) -> URL {
        directory(for: id).appendingPathComponent("photos", isDirectory: true)
    }

    nonisolated func photoURL(_ photo: PhotoNote, in project: Project) -> URL {
        photosDirectory(for: project.id).appendingPathComponent(photo.fileName)
    }

    nonisolated func thumbnailURL(for id: UUID) -> URL {
        directory(for: id).appendingPathComponent("thumb.jpg")
    }

    // MARK: - Listing

    func refresh() {
        guard let entries = try? fileManager.contentsOfDirectory(at: Self.projectsRoot,
                                                                 includingPropertiesForKeys: nil) else {
            projects = []
            return
        }
        var loaded: [Project] = []
        for entry in entries where entry.hasDirectoryPath {
            let manifest = entry.appendingPathComponent("project.json")
            guard let data = try? Data(contentsOf: manifest),
                  let project = try? decoder.decode(Project.self, from: data) else { continue }
            loaded.append(project)
        }
        projects = loaded.sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Writing

    /// Persists a finished scan: manifest, cloud, mesh and stills.
    /// - Parameter photoSource: the scan's working directory, whose stills are
    ///   moved into the project.
    @discardableResult
    func save(_ project: Project,
              points: [GSPoint],
              meshChunks: [MeshChunk],
              photoSource: URL?,
              thumbnail: Data? = nil) throws -> Project {
        var project = project
        let directory = directory(for: project.id)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: photosDirectory(for: project.id), withIntermediateDirectories: true)

        try PointCloudFile.write(points, to: cloudURL(for: project.id))
        project.statistics.pointCount = points.count

        if !meshChunks.isEmpty {
            let obj = OBJExporter.makeOBJ(chunks: meshChunks, name: project.name)
            try obj.write(to: meshURL(for: project.id), options: .atomic)
            project.hasMesh = true
        }

        if let photoSource {
            for photo in project.photos {
                let source = photoSource.appendingPathComponent(photo.fileName)
                let destination = photosDirectory(for: project.id).appendingPathComponent(photo.fileName)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                if fileManager.fileExists(atPath: destination.path) {
                    try? fileManager.removeItem(at: destination)
                }
                // Move rather than copy: a 12 MP still is 4 MB and a long scan
                // can hold dozens of them.
                try? fileManager.moveItem(at: source, to: destination)
            }
        }

        if let thumbnail {
            try? thumbnail.write(to: thumbnailURL(for: project.id), options: .atomic)
        }

        project.updatedAt = Date()
        try writeManifest(project)
        refresh()
        return project
    }

    /// Updates the manifest only — used when notes or measurements change.
    func update(_ project: Project) throws {
        var project = project
        project.updatedAt = Date()
        try writeManifest(project)
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index] = project
        } else {
            refresh()
        }
    }

    private func writeManifest(_ project: Project) throws {
        let directory = directory(for: project.id)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(project)
        try data.write(to: manifestURL(for: project.id), options: .atomic)
    }

    // MARK: - Reading

    func load(id: UUID) throws -> Project {
        let data = try Data(contentsOf: manifestURL(for: id))
        return try decoder.decode(Project.self, from: data)
    }

    nonisolated func loadCloud(for project: Project) throws -> [GSPoint] {
        try PointCloudFile.read(from: cloudURL(for: project.id))
    }

    nonisolated func hasCloud(for project: Project) -> Bool {
        FileManager.default.fileExists(atPath: cloudURL(for: project.id).path)
    }

    // MARK: - Deleting

    func delete(_ project: Project) {
        try? fileManager.removeItem(at: directory(for: project.id))
        projects.removeAll { $0.id == project.id }
    }

    /// Bytes on disk, for the storage row in the project detail screen.
    func diskUsage(for project: Project) -> Int64 {
        let directory = directory(for: project.id)
        guard let enumerator = fileManager.enumerator(at: directory,
                                                      includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }
}
