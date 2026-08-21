//
//  PhotoCorrelator.swift
//
//  The bridge between the stills and the model. Everything here follows from
//  storing the camera pose and intrinsics alongside each photo:
//
//    world -> pixel   "which of my photos show this corner, and where in them?"
//    pixel -> world   "I circled a crack in this photo; put a marker on it in 3-D"
//
//  Both are exact projective operations, not heuristics — the only approximation
//  is the occlusion test, which uses the point cloud itself as a depth buffer.
//

import Foundation
import CoreGraphics
import simd

struct PhotoProjection {
    /// Pixel coordinates in the stored image, origin top-left.
    var pixel: SIMD2<Float>
    /// Distance from the camera along its optical axis, metres.
    var depth: Float
    /// Angle between the camera's view direction and the point, radians.
    var offAxisAngle: Float
    /// False when the cloud suggests something else is in the way.
    var isOccluded: Bool

    var normalizedPixel: SIMD2<Float> = .zero
}

enum PhotoCorrelator {

    /// Project a world point into a photo. Returns nil when the point is behind
    /// the camera or falls outside the frame.
    static func project(_ world: SIMD3<Float>, into photo: PhotoNote) -> PhotoProjection? {
        let worldFromCamera = photo.cameraTransform.matrix
        let cameraFromWorld = worldFromCamera.inverse
        let local4 = cameraFromWorld * SIMD4<Float>(world, 1)
        let local = SIMD3<Float>(local4.x, local4.y, local4.z)

        // ARKit camera space is +x right, +y up, -z forward; the intrinsics use
        // the image convention (+x right, +y down, +z forward).
        let imageSpace = SIMD3<Float>(local.x, -local.y, -local.z)
        guard imageSpace.z > 0.01 else { return nil }

        let projected = photo.intrinsics.matrix * imageSpace
        let pixel = SIMD2<Float>(projected.x / projected.z, projected.y / projected.z)

        guard pixel.x >= 0, pixel.y >= 0,
              pixel.x < Float(photo.imageWidth), pixel.y < Float(photo.imageHeight) else {
            return nil
        }

        let direction = simd_normalize(world - photo.cameraPosition)
        let angle = acos(max(-1, min(1, simd_dot(direction, photo.viewDirection))))

        return PhotoProjection(pixel: pixel,
                               depth: imageSpace.z,
                               offAxisAngle: angle,
                               isOccluded: false,
                               normalizedPixel: SIMD2(pixel.x / Float(photo.imageWidth),
                                                      pixel.y / Float(photo.imageHeight)))
    }

    /// The world-space ray through a pixel of a photo.
    static func ray(throughPixel pixel: SIMD2<Float>, in photo: PhotoNote)
        -> (origin: SIMD3<Float>, direction: SIMD3<Float>) {
        let inverseIntrinsics = photo.intrinsics.matrix.inverse
        let imageSpace = inverseIntrinsics * SIMD3<Float>(pixel.x, pixel.y, 1)
        // Back to ARKit camera axes, then out into the world.
        let cameraSpace = SIMD3<Float>(imageSpace.x, -imageSpace.y, -imageSpace.z)
        let worldFromCamera = photo.cameraTransform.matrix
        let direction4 = worldFromCamera * SIMD4<Float>(cameraSpace, 0)
        let direction = simd_normalize(SIMD3<Float>(direction4.x, direction4.y, direction4.z))
        return (photo.cameraPosition, direction)
    }

    /// Tap a pixel in a still, get a point in the cloud.
    static func resolve(pixel: SIMD2<Float>, in photo: PhotoNote, cloud: PointCloud) -> PickResult? {
        let r = ray(throughPixel: pixel, in: photo)
        return PointCloudPicker.pick(cloud: cloud, origin: r.origin, direction: r.direction)
    }

    /// Photos that see a world point, best view first.
    ///
    /// "Best" is a blend of how close the point is to the centre of frame, how
    /// close the camera was, and how square-on it was looking — which is what a
    /// person means when they ask for the photo that shows a detail clearly.
    static func photos(observing world: SIMD3<Float>,
                       in photos: [PhotoNote],
                       cloud: PointCloud?,
                       occlusionTolerance: Float = 0.15,
                       limit: Int = 12) -> [(photo: PhotoNote, projection: PhotoProjection)] {
        var scored: [(PhotoNote, PhotoProjection, Float)] = []
        for photo in photos {
            guard var projection = project(world, into: photo) else { continue }
            if let cloud {
                projection.isOccluded = isOccluded(world,
                                                   from: photo.cameraPosition,
                                                   cloud: cloud,
                                                   tolerance: occlusionTolerance)
            }
            if projection.isOccluded { continue }

            let centreBias = projection.offAxisAngle                       // radians, smaller is better
            let rangeBias = min(projection.depth / 8.0, 1.0)               // prefer close-up views
            let score = centreBias + rangeBias * 0.5
            scored.append((photo, projection, score))
        }
        scored.sort { $0.2 < $1.2 }
        return scored.prefix(limit).map { ($0.0, $0.1) }
    }

    /// Cloud-as-depth-buffer occlusion test: walk the segment from the camera to
    /// the point and see whether any surface sits solidly in front of it.
    static func isOccluded(_ world: SIMD3<Float>,
                           from eye: SIMD3<Float>,
                           cloud: PointCloud,
                           tolerance: Float) -> Bool {
        let toPoint = world - eye
        let distance = simd_length(toPoint)
        guard distance > 0.2 else { return false }
        let direction = toPoint / distance

        guard let hit = PointCloudPicker.pick(cloud: cloud,
                                              origin: eye,
                                              direction: direction,
                                              maxDistance: distance + tolerance) else {
            // Nothing along the ray at all: the point is not backed by geometry,
            // but it is not blocked either.
            return false
        }
        return hit.distance < distance - tolerance
    }

    /// Photos whose frustum overlaps a measurement, so the reviewer can offer
    /// "3 photos show this" next to every dimension.
    static func photos(observing measurement: SiteMeasurement,
                       in photos: [PhotoNote],
                       cloud: PointCloud?) -> [PhotoNote] {
        var seen = Set<UUID>()
        var result: [PhotoNote] = []
        for vertex in measurement.vertices {
            for (photo, _) in PhotoCorrelator.photos(observing: vertex.world, in: photos, cloud: cloud, limit: 6) {
                if seen.insert(photo.id).inserted { result.append(photo) }
            }
        }
        return result
    }

    /// Resolve any annotation that has not yet been tied to the cloud. Called
    /// after a scan finishes, when the cloud is final.
    static func resolveAnnotations(in photos: inout [PhotoNote], cloud: PointCloud) {
        for photoIndex in photos.indices {
            for annotationIndex in photos[photoIndex].annotations.indices {
                guard photos[photoIndex].annotations[annotationIndex].world == nil else { continue }
                let pixel = photos[photoIndex].annotations[annotationIndex].pixel
                if let pick = resolve(pixel: pixel, in: photos[photoIndex], cloud: cloud) {
                    photos[photoIndex].annotations[annotationIndex].world = pick.world
                    photos[photoIndex].annotations[annotationIndex].sigma = pick.sigma
                }
            }
        }
    }
}
