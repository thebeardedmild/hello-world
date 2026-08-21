//
//  ProjectInfoView.swift
//  What the scan actually contains, and how much to trust it.
//

import SwiftUI

struct ProjectInfoView: View {

    @State var project: Project
    let store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @State private var isResolving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Scan") {
                    TextField("Name", text: $project.name)
                    StatRow(label: "Captured",
                            value: DateFormatter.localizedString(from: project.createdAt,
                                                                 dateStyle: .medium, timeStyle: .short))
                    StatRow(label: "Duration", value: Format.duration(project.statistics.scanDuration))
                    StatRow(label: "Device", value: "\(project.deviceModel) · iOS \(project.systemVersion)")
                    StatRow(label: "On disk", value: Format.bytes(store.diskUsage(for: project)))
                }

                Section {
                    StatRow(label: "Points", value: Format.pointCount(project.statistics.pointCount))
                    StatRow(label: "Captured before filtering",
                            value: Format.pointCount(project.statistics.rawPointCount))
                    StatRow(label: "Extent", value: project.statistics.volumeDescription)
                    StatRow(label: "Point spacing",
                            value: String(format: "%.0f mm", project.settings.voxelLeafSize * 1000))
                    StatRow(label: "Frames used", value: "\(project.statistics.frameCount)")
                    if project.statistics.droppedForMotion > 0 {
                        StatRow(label: "Frames skipped for motion",
                                value: "\(project.statistics.droppedForMotion)")
                    }
                    if project.statistics.meshFaceCount > 0 {
                        StatRow(label: "Mesh faces",
                                value: Format.pointCount(project.statistics.meshFaceCount))
                    }
                } header: {
                    Text("Point cloud")
                } footer: {
                    Text("Points were captured at \(String(format: "%.2f–%.1f m", project.settings.minRange, project.settings.maxRange)) with a confidence floor of \(project.settings.minConfidence), then reduced to one point per \(String(format: "%.0f mm", project.settings.voxelLeafSize * 1000)) voxel.")
                }

                Section {
                    GeoSolutionSummary(solution: project.geoSolution)
                    if !project.geoFixes.isEmpty {
                        Button {
                            resolve()
                        } label: {
                            HStack {
                                Text("Re-solve from \(project.geoFixes.count) stored fixes")
                                Spacer()
                                if isResolving { ProgressView() }
                            }
                        }
                        .disabled(isResolving)
                    }
                } header: {
                    Text("Georeference")
                } footer: {
                    Text("Every GPS fix is kept with the scan, so the fit can be recomputed at any time — the cloud itself never needs to be touched.")
                }

                Section("Contents") {
                    StatRow(label: "Stills", value: "\(project.photos.count)")
                    StatRow(label: "Markers on stills",
                            value: "\(project.photos.reduce(0) { $0 + $1.annotations.count })")
                    StatRow(label: "Measurements", value: "\(project.measurements.count)")
                }

                Section {
                    Text("Relative accuracy inside this scan is roughly a centimetre at two metres, which is what the measurement uncertainties reflect. Absolute position is limited by consumer GPS: \(Format.accuracy(project.geoSolution.estimatedAbsoluteAccuracy)) at best.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Scan info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        try? store.update(project)
                        dismiss()
                    }
                }
            }
        }
    }

    private func resolve() {
        isResolving = true
        var updated = project
        updated.resolveGeoreference()
        project = updated
        try? store.update(updated)
        isResolving = false
    }
}
