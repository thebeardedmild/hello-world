//
//  PhotoCapture.swift
//
//  Grabs the current AR frame as a JPEG.
//
//  The image is written in the *sensor's* orientation and tagged with an EXIF
//  orientation, deliberately: the camera intrinsics ARKit hands us describe that
//  unrotated buffer, and rotating the pixels without rotating the intrinsics is
//  how photo-to-model correlation quietly breaks. Viewers honour the EXIF tag, so
//  it still looks upright everywhere.
//

import Foundation
import ARKit
import CoreImage
import ImageIO
import CoreLocation
import UniformTypeIdentifiers
import UIKit

enum PhotoCapture {

    struct Capture {
        var jpeg: Data
        var width: Int
        var height: Int
        var exifOrientation: Int32
        var intrinsics: simd_float3x3
        var cameraTransform: simd_float4x4
        var exposureDuration: Double
        /// EV offset ARKit reports for the frame; useful when judging colour.
        var exposureOffset: Double
    }

    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    static func capture(frame: ARFrame,
                        interfaceOrientation: UIInterfaceOrientation,
                        location: CLLocation?,
                        quality: CGFloat = 0.92) -> Capture? {
        let pixelBuffer = frame.capturedImage
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }

        let exifOrientation = exifOrientationValue(for: interfaceOrientation)
        var properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyOrientation: exifOrientation
        ]
        properties[kCGImagePropertyExifDictionary] = exifDictionary(for: frame)
        properties[kCGImagePropertyTIFFDictionary] = [
            kCGImagePropertyTIFFMake: "Apple",
            kCGImagePropertyTIFFModel: UIDevice.current.model,
            kCGImagePropertyTIFFSoftware: "GeoScan"
        ]
        if let location {
            properties[kCGImagePropertyGPSDictionary] = gpsDictionary(for: location)
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }

        return Capture(jpeg: data as Data,
                       width: cgImage.width,
                       height: cgImage.height,
                       exifOrientation: exifOrientation,
                       intrinsics: frame.camera.intrinsics,
                       cameraTransform: frame.camera.transform,
                       exposureDuration: frame.camera.exposureDuration,
                       exposureOffset: Double(frame.camera.exposureOffset))
    }

    /// Distance to whatever the camera is pointed at, straight from the depth map.
    static func aimDistance(frame: ARFrame) -> Float? {
        guard let depth = frame.sceneDepth ?? frame.smoothedSceneDepth else { return nil }
        let map = depth.depthMap
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }

        let width = CVPixelBufferGetWidth(map)
        let height = CVPixelBufferGetHeight(map)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(map)

        // Median of a small patch at frame centre — a single pixel lands on a
        // depth discontinuity often enough to matter.
        var samples: [Float] = []
        for dy in -2...2 {
            for dx in -2...2 {
                let x = width / 2 + dx
                let y = height / 2 + dy
                guard x >= 0, y >= 0, x < width, y < height else { continue }
                let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: Float32.self)
                let value = row[x]
                if value.isFinite && value > 0 { samples.append(value) }
            }
        }
        guard !samples.isEmpty else { return nil }
        samples.sort()
        return samples[samples.count / 2]
    }

    // MARK: - Metadata

    static func exifOrientationValue(for orientation: UIInterfaceOrientation) -> Int32 {
        // ARKit's captured image is always landscape-right in sensor space.
        switch orientation {
        case .portrait:            return 6   // rotate 90° CW to display
        case .portraitUpsideDown:  return 8
        case .landscapeLeft:       return 3
        case .landscapeRight:      return 1
        default:                   return 6
        }
    }

    private static func exifDictionary(for frame: ARFrame) -> [CFString: Any] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let now = Date()
        return [
            kCGImagePropertyExifDateTimeOriginal: formatter.string(from: now),
            kCGImagePropertyExifDateTimeDigitized: formatter.string(from: now),
            kCGImagePropertyExifExposureTime: frame.camera.exposureDuration,
            kCGImagePropertyExifFocalLength: Double(frame.camera.intrinsics.columns.0.x),
            kCGImagePropertyExifPixelXDimension: Int(frame.camera.imageResolution.width),
            kCGImagePropertyExifPixelYDimension: Int(frame.camera.imageResolution.height)
        ]
    }

    private static func gpsDictionary(for location: CLLocation) -> [CFString: Any] {
        let coordinate = location.coordinate
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SS"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy:MM:dd"
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)

        var gps: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: abs(coordinate.latitude),
            kCGImagePropertyGPSLatitudeRef: coordinate.latitude >= 0 ? "N" : "S",
            kCGImagePropertyGPSLongitude: abs(coordinate.longitude),
            kCGImagePropertyGPSLongitudeRef: coordinate.longitude >= 0 ? "E" : "W",
            kCGImagePropertyGPSTimeStamp: formatter.string(from: location.timestamp),
            kCGImagePropertyGPSDateStamp: dateFormatter.string(from: location.timestamp),
            kCGImagePropertyGPSHPositioningError: max(location.horizontalAccuracy, 0)
        ]
        if location.verticalAccuracy >= 0 {
            gps[kCGImagePropertyGPSAltitude] = abs(location.altitude)
            gps[kCGImagePropertyGPSAltitudeRef] = location.altitude >= 0 ? 0 : 1
        }
        if location.course >= 0 {
            gps[kCGImagePropertyGPSImgDirection] = location.course
            gps[kCGImagePropertyGPSImgDirectionRef] = "T"
        }
        return gps
    }
}
