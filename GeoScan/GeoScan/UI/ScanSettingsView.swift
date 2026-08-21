//
//  ScanSettingsView.swift
//  Capture settings, reachable mid-scan.
//

import SwiftUI

struct ScanSettingsView: View {

    @Binding var settings: ScanSettings
    @Binding var colorMode: PointColorMode
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Preset") {
                    ForEach(ScanSettings.Preset.allCases) { preset in
                        Button {
                            apply(preset)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.rawValue).foregroundStyle(.primary)
                                Text(preset.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("View") {
                    Picker("Colouring", selection: $colorMode) {
                        ForEach(PointColorMode.allCases) { mode in
                            Label(mode.title, systemImage: mode.symbolName).tag(mode)
                        }
                    }
                    Text(colorMode.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Text("Point size")
                        Slider(value: $settings.pointSize, in: 2...16, step: 1)
                        Text("\(Int(settings.pointSize))")
                            .font(.caption.monospacedDigit())
                            .frame(width: 24)
                    }
                }

                Section {
                    HStack {
                        Text("Range")
                        Spacer()
                        Text(String(format: "%.2f – %.1f m", settings.minRange, settings.maxRange))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $settings.maxRange, in: 1...8, step: 0.5) {
                        Text("Maximum range")
                    }
                    Picker("Confidence floor", selection: $settings.minConfidence) {
                        Text("Low — keep everything").tag(0)
                        Text("Medium — recommended").tag(1)
                        Text("High — cleanest").tag(2)
                    }
                    HStack {
                        Text("Voxel size")
                        Spacer()
                        Text(String(format: "%.0f mm", settings.voxelLeafSize * 1000))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $settings.voxelLeafSize, in: 0.003...0.05, step: 0.001)
                } header: {
                    Text("Capture")
                } footer: {
                    Text("The sensor's error grows with distance — roughly a centimetre per metre — so a tighter range gives a cleaner cloud. The voxel size sets the final point spacing.")
                }

                Section {
                    Toggle("Skip blurred frames", isOn: $settings.motionGateEnabled)
                    Toggle("Auto-compact when full", isOn: $settings.autoCompact)
                    Toggle("Capture scene mesh", isOn: $settings.captureMesh)
                } header: {
                    Text("Behaviour")
                } footer: {
                    Text("Blurred frames paint colour onto the wrong geometry. Auto-compact voxel-filters the cloud when the buffer fills, so a long scan loses resolution instead of stopping.")
                }

                Section {
                    Toggle("Remove outliers on export", isOn: $settings.outlierRemovalEnabled)
                    Stepper("Neighbours: \(settings.outlierNeighbors)",
                            value: $settings.outlierNeighbors, in: 4...24)
                    HStack {
                        Text("Threshold")
                        Spacer()
                        Text(String(format: "%.1fσ", settings.outlierStandardDeviations))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $settings.outlierStandardDeviations, in: 1...4, step: 0.1)
                } header: {
                    Text("Cleanup")
                } footer: {
                    Text("Drops points whose neighbours are unusually far away — the stray flyers that LiDAR throws off edges and reflective surfaces.")
                }
            }
            .navigationTitle("Scan settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func apply(_ preset: ScanSettings.Preset) {
        var next = preset.settings
        // Presets set capture geometry; they should not stamp on the operator's
        // display and cleanup preferences.
        next.pointSize = settings.pointSize
        next.outlierRemovalEnabled = settings.outlierRemovalEnabled
        next.outlierNeighbors = settings.outlierNeighbors
        next.outlierStandardDeviations = settings.outlierStandardDeviations
        next.motionGateEnabled = settings.motionGateEnabled
        next.autoCompact = settings.autoCompact
        next.captureMesh = settings.captureMesh
        settings = next
    }
}
