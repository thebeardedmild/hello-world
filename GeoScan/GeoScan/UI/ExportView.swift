//
//  ExportView.swift
//  Choosing a coordinate frame and a set of formats, then handing over a zip.
//

import SwiftUI

struct ExportView: View {

    let project: Project
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss

    @StateObject private var job = ExportJob()
    @State private var options = ExportOptions.default
    @State private var shareURL: URL?

    init(project: Project) {
        self.project = project
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Coordinates", selection: $options.frame) {
                        ForEach(CoordinateFrame.allCases) { frame in
                            Text(frame.title).tag(frame)
                        }
                    }
                    Text(options.frame.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if options.frame.requiresGeoreference && !project.geoSolution.isUsable {
                        Label("This scan has no GPS solution, so it will be exported in the scanner's local frame.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.warn)
                    }
                } header: {
                    Text("Coordinate frame")
                }

                Section("Formats") {
                    ForEach(ExportFormat.allCases) { format in
                        Toggle(isOn: binding(for: format)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(format.title)
                                Text(format.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .disabled(isDisabled(format))
                    }
                }

                Section {
                    Toggle("Include stills", isOn: $options.includePhotos)
                    HStack {
                        Text("Point spacing")
                        Spacer()
                        Text(options.voxelLeafSize > 0
                             ? String(format: "%.0f mm", options.voxelLeafSize * 1000)
                             : "as captured")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $options.voxelLeafSize, in: 0...0.05, step: 0.001)
                    Toggle("Remove outliers", isOn: $options.removeOutliers)
                    Picker("Confidence floor", selection: $options.minConfidence) {
                        Text("Everything").tag(0)
                        Text("Medium and high").tag(1)
                        Text("High only").tag(2)
                    }
                } header: {
                    Text("Cloud processing")
                } footer: {
                    Text("Set the spacing to zero to export every captured point. Anything larger thins the cloud to a uniform grid, which is usually what other software wants.")
                }

                if job.isRunning {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(job.stage.description).font(.callout)
                            ProgressView(value: job.progress)
                        }
                    }
                }

                if case .finished(let url) = job.stage {
                    Section("Ready") {
                        ForEach(job.writtenFiles, id: \.self) { file in
                            Label(file, systemImage: "doc")
                                .font(.caption)
                        }
                        ForEach(job.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(Theme.warn)
                        }
                        Button {
                            shareURL = url
                        } label: {
                            Label("Share \(url.lastPathComponent)", systemImage: "square.and.arrow.up")
                        }
                    }
                }

                if case .failed(let message) = job.stage {
                    Section {
                        Label(message, systemImage: "xmark.octagon.fill")
                            .foregroundStyle(Theme.bad)
                    }
                }

                Section {
                    Button {
                        job.run(project: project,
                                options: options,
                                cloudURL: store.cloudURL(for: project.id),
                                meshURL: store.meshURL(for: project.id),
                                photosDirectory: store.photosDirectory(for: project.id))
                    } label: {
                        HStack {
                            Text("Build export")
                            Spacer()
                            if job.isRunning { ProgressView() }
                        }
                    }
                    .disabled(job.isRunning || options.formats.isEmpty)
                } footer: {
                    Text("Exports are also written to the app's Documents folder, so they can be pulled off with a cable if the share sheet is not convenient.")
                }
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(item: shareItem) { item in
                ShareSheet(items: [item.url])
            }
            .onAppear {
                if !project.geoSolution.isUsable { options.frame = .arWorld }
            }
        }
    }

    // MARK: - Helpers

    private struct ShareItem: Identifiable {
        let url: URL
        var id: String { url.path }
    }

    private var shareItem: Binding<ShareItem?> {
        Binding(get: { shareURL.map(ShareItem.init) },
                set: { shareURL = $0?.url })
    }

    private func binding(for format: ExportFormat) -> Binding<Bool> {
        Binding(get: { options.formats.contains(format) },
                set: { isOn in
                    if isOn { options.formats.insert(format) } else { options.formats.remove(format) }
                })
    }

    private func isDisabled(_ format: ExportFormat) -> Bool {
        switch format {
        case .obj: return !project.hasMesh
        case .las, .geojson: return !project.geoSolution.isUsable
        default: return false
        }
    }
}
