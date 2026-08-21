//
//  PhotoNote.swift
//
//  A still grabbed mid-scan, with everything needed to put it back into the 3-D
//  model: the full camera pose, the intrinsics at capture resolution, the frame
//  size, and the surface point the camera was aimed at.
//
//  With pose + intrinsics you get both directions for free:
//    * world -> pixel, so you can ask "which photos show this corner?"
//    * pixel -> ray -> cloud intersection, so tapping a crack in a photo drops a
//      marker on that crack in the point cloud.
//

import Foundation
import simd

/// A tap on the still, optionally resolved to a 3-D position.
struct PhotoAnnotation: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    /// Pixel coordinates in the stored image, origin top-left.
    var pixel: SIMD2<Float>
    var text: String = ""
    /// Set once the pixel ray has been intersected with the cloud.
    var world: SIMD3<Float>?
    /// One-sigma uncertainty of `world`, metres.
    var sigma: Float = .nan
    var createdAt: Date = Date()
}

struct PhotoNote: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    /// File name inside the project's `photos/` directory.
    var fileName: String
    var capturedAt: Date

    var note: String = ""
    var tags: [String] = []

    /// ARKit camera transform at capture: world-from-camera, +Y up, camera looks down -Z.
    var cameraTransform: Matrix4x4Codable
    /// Intrinsics for `imageWidth` x `imageHeight`.
    var intrinsics: Matrix3x3Codable
    var imageWidth: Int
    var imageHeight: Int
    /// ARKit's interface orientation at capture, so the still can be shown upright.
    var exifOrientation: Int32 = 6

    /// Where the camera was pointed — the raycast hit at frame centre. Used as
    /// the pin location in 3-D, because a pin at the camera itself floats in air.
    var aimPoint: SIMD3<Float>?
    /// Distance to `aimPoint` in metres, from the depth map.
    var aimDistance: Float?

    var location: Geodetic?
    var locationHorizontalAccuracy: Double?

    var annotations: [PhotoAnnotation] = []
    /// Measurements the operator linked to this still.
    var linkedMeasurementIDs: [UUID] = []

    var exposureDuration: Double = 0
    /// EV offset reported by ARKit at capture.
    var exposureOffset: Double = 0

    // MARK: - Derived

    var cameraPosition: SIMD3<Float> { cameraTransform.matrix.position }
    var viewDirection: SIMD3<Float> { cameraTransform.matrix.forward }

    /// Anchor used for the 3-D pin: the aimed-at surface if we have it, otherwise
    /// a point a metre in front of the lens.
    var anchorPosition: SIMD3<Float> {
        aimPoint ?? (cameraPosition + viewDirection * 1.0)
    }

    var displayTitle: String {
        if !note.isEmpty {
            let firstLine = note.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? note
            return String(firstLine.prefix(60))
        }
        return PhotoNote.timeFormatter.string(from: capturedAt)
    }

    /// Horizontal field of view in radians, from the intrinsics.
    var horizontalFieldOfView: Float {
        let fx = intrinsics.matrix.columns.0.x
        guard fx > 0 else { return 1.2 }
        return 2 * atan(Float(imageWidth) * 0.5 / fx)
    }

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()
}
