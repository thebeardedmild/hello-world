//
//  ScanSettings.swift
//  Capture and processing knobs. Defaults are tuned for handheld interior /
//  facade work at 1-5 m, which is where the iPhone LiDAR is actually good.
//

import Foundation

struct ScanSettings: Codable, Equatable {

    /// Hard cap on live points. 16 bytes each, so 6M points ≈ 96 MB.
    var maxPoints: Int = 6_000_000

    /// ARConfidenceLevel floor: 0 low, 1 medium, 2 high.
    var minConfidence: Int = 1

    /// Depth gate in metres. Beyond ~5 m the sensor's error grows faster than
    /// its usefulness, and below 0.25 m it is not specified at all.
    var minRange: Float = 0.25
    var maxRange: Float = 5.0

    /// 1 = every depth pixel (49k per frame), 2 = a quarter of them.
    var sampleStride: Int = 1

    /// Voxel leaf size used for compaction and export, metres.
    var voxelLeafSize: Float = 0.01

    /// Skip frames captured while the phone is being swung around.
    var motionGateEnabled: Bool = true

    /// Minimum camera movement before a frame is accumulated.
    var minTranslation: Float = 0.025
    var minRotationDegrees: Float = 2.5

    /// Voxel-filter the live cloud instead of stopping when the buffer fills.
    var autoCompact: Bool = true

    /// Also record the ARKit scene mesh — cheap, and it gives measurement a
    /// surface to snap to as well as an OBJ for context in the export.
    var captureMesh: Bool = true

    /// Sprite size at 1 m, in points.
    var pointSize: Float = 7.0

    /// Statistical outlier removal at export: drop points whose mean distance to
    /// their k nearest neighbours is more than n sigma above the cloud average.
    var outlierRemovalEnabled: Bool = true
    var outlierNeighbors: Int = 8
    var outlierStandardDeviations: Float = 2.0

    static let `default` = ScanSettings()

    /// Quick presets, because nobody wants to reason about voxel sizes in the field.
    enum Preset: String, CaseIterable, Identifiable {
        case detail = "Detail"
        case balanced = "Balanced"
        case coverage = "Coverage"

        var id: String { rawValue }

        var subtitle: String {
            switch self {
            case .detail: return "5 mm voxels, 0.25–3 m — small objects, tight interiors"
            case .balanced: return "10 mm voxels, 0.25–5 m — rooms and facades"
            case .coverage: return "25 mm voxels, 0.5–7 m — large sites, long walks"
            }
        }

        var settings: ScanSettings {
            var s = ScanSettings()
            switch self {
            case .detail:
                s.voxelLeafSize = 0.005
                s.maxRange = 3.0
                s.minConfidence = 2
                s.sampleStride = 1
                s.minTranslation = 0.015
            case .balanced:
                break
            case .coverage:
                s.voxelLeafSize = 0.025
                s.minRange = 0.5
                s.maxRange = 7.0
                s.minConfidence = 1
                s.sampleStride = 1
                s.minTranslation = 0.05
                s.maxPoints = 9_000_000
            }
            return s
        }
    }
}
